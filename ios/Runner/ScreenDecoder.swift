import CoreMedia
import CoreVideo
import Flutter
import Foundation
import VideoToolbox

/// Decodes the H.264 access units the screen viewer reassembles (see
/// lib/core/screen/screen_viewer.dart) with VideoToolbox and shows them in a
/// Flutter texture: the iOS counterpart of ScreenDecoder.kt, driven over the
/// same "uconnect/screen" MethodChannel:
///
///   create(bufferMs)                 -> { textureId }
///   decode(bytes, keyframe, ptsUs)   feed one Annex-B access unit
///   setBuffer(bufferMs)
///   stats()                          -> { rendered, late, bufferMs } since the last call
///   dispose()
///
/// and back to Dart: size({width, height}), error(message).
///
/// Playout is the Android decoder's: with a buffer, each picture is shown at
/// its capture time (its pts) plus the buffer, on the clock of the quickest
/// transit of the last few seconds, slewed by at most a tenth; without one, as
/// soon as it is decoded.
///
/// To Dart: size(width, height) when the picture size is known or changes,
/// and needKeyframe() when the decoder lost its place and can show nothing
/// until a keyframe comes.
///
/// The stream carries SPS/PPS inside each keyframe, so the session is made
/// from the first keyframe, and made again when they change (the sharing
/// device rotated, or changed its resolution).
final class ScreenDecoder: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "uconnect/screen", binaryMessenger: registrar.messenger())
    let instance = ScreenDecoder(channel: channel, textures: registrar.textures())
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private let channel: FlutterMethodChannel
  private let textures: FlutterTextureRegistry
  /// Everything below `work` is touched on this queue only.
  private let work = DispatchQueue(label: "dev.uconnect.screen-decoder")

  private var texture: PictureTexture?
  private var textureId: Int64 = -1
  /// Bumped by create and dispose: pictures of an earlier decoder are dropped.
  private var generation = 0

  private var session: VTDecompressionSession?
  private var format: CMVideoFormatDescription?
  private var sps = Data()
  private var pps = Data()
  private var sawKeyframe = false
  /// Dart has been told a keyframe is needed, and none has come since.
  private var askedForKeyframe = false
  private var reportedWidth = 0
  private var reportedHeight = 0

  // The playout clock; see ScreenDecoder.kt for the reasoning.
  private var bufferNs: Int64 = 0
  private var transits: [(at: Int64, transit: Int64)] = []
  private var offsetNs: Int64 = 0
  private var haveClock = false
  private var clockAtNs: Int64 = 0
  private var lastRenderNs: Int64 = 0
  private var lastPtsUs: Int64 = 0
  private var intervalNs: Int64 = 16_666_667
  private var rendered = 0
  private var late = 0
  private let lagBudgetNs: Int64 = 1_000_000_000

  private init(channel: FlutterMethodChannel, textures: FlutterTextureRegistry) {
    self.channel = channel
    self.textures = textures
  }

  private static func now() -> Int64 {
    Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
  }

  // MARK: - channel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "create":
      let bufferMs = (args["bufferMs"] as? NSNumber)?.int64Value ?? 0
      // The texture registry is used on this (the platform) thread.
      let old = work.sync { () -> Int64 in
        let id = textureId
        teardown()
        return id
      }
      if old >= 0 { textures.unregisterTexture(old) }
      let picture = PictureTexture()
      let id = textures.register(picture)
      work.sync {
        texture = picture
        textureId = id
        bufferNs = min(max(bufferMs, 0), 2000) * 1_000_000
      }
      result(["textureId": id])
    case "decode":
      if let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data {
        let keyframe = args["keyframe"] as? Bool ?? false
        let ptsUs = (args["ptsUs"] as? NSNumber)?.int64Value ?? 0
        work.async { self.feed(bytes, keyframe: keyframe, ptsUs: ptsUs) }
      }
      result(nil)
    case "setBuffer":
      // The playout buffer follows the network (the viewer's choice of
      // "automatic"): pictures already scheduled keep their times.
      let bufferMs = (args["bufferMs"] as? NSNumber)?.int64Value ?? 0
      work.async { self.bufferNs = min(max(bufferMs, 0), 2000) * 1_000_000 }
      result(nil)
    case "stats":
      let stats = work.sync { () -> [String: Any] in
        let s: [String: Any] = [
          "rendered": rendered, "late": late, "bufferMs": bufferNs / 1_000_000,
        ]
        rendered = 0
        late = 0
        return s
      }
      result(stats)
    case "dispose":
      let old = work.sync { () -> Int64 in
        let id = textureId
        teardown()
        return id
      }
      if old >= 0 { textures.unregisterTexture(old) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func tell(_ method: String, _ arguments: Any?) {
    DispatchQueue.main.async { self.channel.invokeMethod(method, arguments: arguments) }
  }

  // MARK: - decoding (on `work`)

  private func teardown() {
    generation += 1
    dropSession()
    sps = Data()
    pps = Data()
    texture = nil
    textureId = -1
    reportedWidth = 0
    reportedHeight = 0
    transits.removeAll()
    haveClock = false
    lastRenderNs = 0
    lastPtsUs = 0
    rendered = 0
    late = 0
  }

  private func dropSession() {
    if let s = session {
      VTDecompressionSessionInvalidate(s)
    }
    session = nil
    format = nil
    sawKeyframe = false
  }

  /// Nothing can be shown until the next keyframe: the session is dropped and
  /// Dart is told, once, so the viewer asks the host for one now instead of
  /// waiting out the host's keyframe interval with a frozen picture. That is
  /// the case after every return from the background, where iOS invalidates
  /// the session.
  private func needKeyframe() {
    dropSession()
    if !askedForKeyframe {
      askedForKeyframe = true
      tell("needKeyframe", nil)
    }
  }

  private func feed(_ unit: Data, keyframe: Bool, ptsUs: Int64) {
    guard texture != nil else { return }
    let nals = ScreenDecoder.nalUnits(unit)
    if keyframe {
      // A keyframe brings its parameter sets: (re)make the session for them.
      var newSps: Data?
      var newPps: Data?
      for range in nals {
        switch unit[range.lowerBound] & 0x1F {
        case 7: newSps = unit.subdata(in: range)
        case 8: newPps = unit.subdata(in: range)
        default: break
        }
      }
      if let s = newSps, let p = newPps, session == nil || s != sps || p != pps {
        guard configure(sps: s, pps: p) else { return }
      }
    }
    guard let session = session, let format = format else { return }  // waits for a keyframe
    if keyframe {
      sawKeyframe = true
      askedForKeyframe = false
    }
    if !sawKeyframe { return }

    let now = ScreenDecoder.now()
    transits.append((now, now - ptsUs * 1000))
    while transits.count > 1, now - transits[0].at > 15_000_000_000 { transits.removeFirst() }
    if lastPtsUs != 0, ptsUs > lastPtsUs {
      intervalNs = min(max((ptsUs - lastPtsUs) * 1000, 4_000_000), 200_000_000)
    }
    lastPtsUs = ptsUs
    updateClock(now)

    // Annex-B to AVCC: each NAL behind a 4-byte length; the parameter sets
    // and access-unit delimiters stay out (they are in the format description).
    var avcc = Data(capacity: unit.count + 16)
    for range in nals {
      let type = unit[range.lowerBound] & 0x1F
      if type == 7 || type == 8 || type == 9 { continue }
      var length = UInt32(range.count).bigEndian
      withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
      avcc.append(unit.subdata(in: range))
    }
    if avcc.isEmpty { return }

    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: avcc.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
      let blockBuffer = block
    else { return }
    let copied = avcc.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0,
        dataLength: avcc.count)
    }
    guard copied == kCMBlockBufferNoErr else { return }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
      decodeTimeStamp: .invalid)
    var size = avcc.count
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
      let sampleBuffer = sample
    else { return }

    let made = generation
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sampleBuffer,
      flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback], infoFlagsOut: nil
    ) { [weak self] status, _, image, _, _ in
      guard let self = self else { return }
      guard status == noErr else {
        // Not decodable, found out late: what follows builds on it.
        self.work.async { if made == self.generation { self.needKeyframe() } }
        return
      }
      guard let image = image else { return }  // dropped by the decoder itself
      self.work.async { self.decoded(image, ptsUs: ptsUs, generation: made) }
    }
    if status != noErr {
      // The session is gone (the app was in the background) or the unit was
      // not decodable: start over at the next keyframe.
      needKeyframe()
    }
  }

  private func configure(sps newSps: Data, pps newPps: Data) -> Bool {
    var description: CMVideoFormatDescription?
    let status = newSps.withUnsafeBytes { s -> OSStatus in
      newPps.withUnsafeBytes { p -> OSStatus in
        let pointers = [
          s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!,
        ]
        let sizes = [newSps.count, newPps.count]
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
          parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
      }
    }
    guard status == noErr, let newFormat = description else {
      tell("error", "The stream's parameter sets were not understood (\(status)).")
      return false
    }
    if let s = session, VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: newFormat) {
      format = newFormat
      sps = newSps
      pps = newPps
      return true
    }
    dropSession()
    // BGRA backed by an IOSurface: what a Flutter texture takes directly.
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
    ]
    var made: VTDecompressionSession?
    let created = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: newFormat, decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
      decompressionSessionOut: &made)
    guard created == noErr, let newSession = made else {
      tell("error", "The video decoder could not be started (\(created)).")
      return false
    }
    VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    session = newSession
    format = newFormat
    sps = newSps
    pps = newPps
    return true
  }

  private func updateClock(_ now: Int64) {
    if transits.isEmpty { return }
    let sorted = transits.map { $0.transit }.sorted()
    let target = sorted[min(sorted.count - 1, sorted.count / 20)]  // the 5th percentile
    if !haveClock || abs(target - offsetNs) > lagBudgetNs {
      offsetNs = target
      haveClock = true
    } else {
      let step = max(now - clockAtNs, 0) / 10
      offsetNs += min(max(target - offsetNs, -step), step)
    }
    clockAtNs = now
  }

  private func decoded(_ image: CVImageBuffer, ptsUs: Int64, generation made: Int) {
    guard made == generation, let texture = texture else { return }
    let id = textureId
    let now = ScreenDecoder.now()
    var due = ptsUs * 1000 + offsetNs + bufferNs
    if bufferNs <= 0 || !haveClock || due - now > 2_000_000_000 {
      due = now
    } else {
      let overdue = now - due
      if overdue > intervalNs { late += 1 }  // behind its time
      // Behind: shown a tenth faster than captured, never skipped, unless
      // the lag has passed the budget: then at once.
      if overdue > 0 && overdue <= lagBudgetNs {
        due = max(now, lastRenderNs + intervalNs * 9 / 10)
      } else if overdue > lagBudgetNs {
        due = now
      }
    }
    due = max(due, lastRenderNs)  // pictures stay in order
    lastRenderNs = due
    rendered += 1

    let width = CVPixelBufferGetWidth(image)
    let height = CVPixelBufferGetHeight(image)
    if width != reportedWidth || height != reportedHeight {
      reportedWidth = width
      reportedHeight = height
      tell("size", ["width": width, "height": height])
    }

    let show = { [textures] in
      texture.show(image)
      textures.textureFrameAvailable(id)
    }
    if due <= now {
      DispatchQueue.main.async(execute: show)
    } else {
      DispatchQueue.main.asyncAfter(
        deadline: DispatchTime(uptimeNanoseconds: UInt64(due)), execute: show)
    }
  }

  // MARK: - Annex-B

  /// The NAL units of an Annex-B access unit: the byte ranges between its
  /// start codes (00 00 01 or 00 00 00 01), without them.
  static func nalUnits(_ data: Data) -> [Range<Int>] {
    var starts: [(code: Int, payload: Int)] = []
    let count = data.count
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let b = raw.bindMemory(to: UInt8.self)
      var i = 0
      while i + 2 < count {
        if b[i] == 0 && b[i + 1] == 0 {
          if b[i + 2] == 1 {
            starts.append((i, i + 3))
            i += 3
            continue
          }
          if i + 3 < count && b[i + 2] == 0 && b[i + 3] == 1 {
            starts.append((i, i + 4))
            i += 4
            continue
          }
        }
        i += 1
      }
    }
    var units: [Range<Int>] = []
    for (n, start) in starts.enumerated() {
      let end = n + 1 < starts.count ? starts[n + 1].code : count
      if end > start.payload { units.append(start.payload..<end) }
    }
    return units
  }
}

/// The picture a Flutter `Texture` widget draws: the latest decoded frame.
private final class PictureTexture: NSObject, FlutterTexture {
  private let lock = NSLock()
  private var latest: CVPixelBuffer?

  func show(_ image: CVPixelBuffer) {
    lock.lock()
    latest = image
    lock.unlock()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let image = latest else { return nil }
    return Unmanaged.passRetained(image)
  }
}
