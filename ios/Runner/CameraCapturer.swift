import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import Foundation
import VideoToolbox

/// Opens a camera, encodes it to H.264 with VideoToolbox and streams the
/// access units: the iOS counterpart of CameraCapturer.kt, on the same
/// channels (see lib/core/screen/camera_capture.dart):
///
///   "uconnect/camera"
///     cameras()                             -> [ { id, facing } ]
///     requestPermission()                   -> { granted }
///     start(width, height, fps, bitrate, cameraId?) -> { width, height }
///     requestKeyframe() / setBitrate(bitrate) / stop()
///   "uconnect/camera/au"   { bytes, keyframe, ptsUs } per access unit
///
/// The stream is shaped as the Android one: Annex-B, no B-frames, SPS and PPS
/// in front of every keyframe, and a keyframe only when one is asked for (each
/// costs several frames' worth of bytes on a thin path).
///
/// The simulator has no camera, so there one named "simulated" is offered that
/// draws a moving test picture. It goes through the same encoder and channels,
/// which is how this file is tested; opening a real camera is not.
final class CameraCapturer: NSObject, FlutterPlugin, FlutterStreamHandler,
  AVCaptureVideoDataOutputSampleBufferDelegate
{
  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = CameraCapturer()
    let channel = FlutterMethodChannel(
      name: "uconnect/camera", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    FlutterEventChannel(name: "uconnect/camera/au", binaryMessenger: registrar.messenger())
      .setStreamHandler(instance)
  }

  private static let simulatedId = "simulated"

  /// Capture and encoding happen here; `sink` is used on the main queue.
  private let queue = DispatchQueue(label: "dev.uconnect.camera")
  private var sink: FlutterEventSink?

  private var session: AVCaptureSession?
  private var pattern: DispatchSourceTimer?
  private var patternFrame = 0
  private var encoder: VTCompressionSession?
  private var wantKeyframe = true
  private var width = 0
  private var height = 0
  /// Bumped by start and stop: frames of an earlier run are dropped.
  private var run = 0

  // MARK: - channel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "cameras":
      result(cameras())
    case "requestPermission":
      requestPermission { granted in result(["granted": granted]) }
    case "start":
      let width = (args["width"] as? NSNumber)?.intValue ?? 1280
      let height = (args["height"] as? NSNumber)?.intValue ?? 720
      let fps = (args["fps"] as? NSNumber)?.intValue ?? 30
      let bitrate = (args["bitrate"] as? NSNumber)?.intValue ?? 2_000_000
      let cameraId = args["cameraId"] as? String
      queue.async {
        let size = self.start(
          bound: max(width, height), fps: min(max(fps, 5), 60), bitrate: bitrate, cameraId: cameraId)
        DispatchQueue.main.async { result(["width": size.0, "height": size.1]) }
      }
    case "requestKeyframe":
      queue.async { self.wantKeyframe = true }
      result(nil)
    case "setBitrate":
      let bitrate = (args["bitrate"] as? NSNumber)?.intValue ?? 0
      queue.async { self.apply(bitrate: bitrate) }
      result(nil)
    case "stop":
      queue.async { self.stop() }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  // MARK: - cameras

  private func devices() -> [AVCaptureDevice] {
    var types: [AVCaptureDevice.DeviceType] = [
      .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
    ]
    if #available(iOS 17.0, *) { types.append(.external) }
    return AVCaptureDevice.DiscoverySession(
      deviceTypes: types, mediaType: .video, position: .unspecified
    ).devices
  }

  private func cameras() -> [[String: String]] {
    var list = devices().map { device -> [String: String] in
      let facing: String
      switch device.position {
      case .front: facing = "front"
      case .back: facing = "back"
      default: facing = "external"
      }
      return ["id": device.uniqueID, "facing": facing]
    }
    #if targetEnvironment(simulator)
      if list.isEmpty { list.append(["id": CameraCapturer.simulatedId, "facing": "external"]) }
    #endif
    return list
  }

  private func requestPermission(_ done: @escaping (Bool) -> Void) {
    #if targetEnvironment(simulator)
      if devices().isEmpty { return done(true) }  // the simulated camera needs none
    #endif
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      done(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async { done(granted) }
      }
    default:
      done(false)
    }
  }

  // MARK: - capture (on `queue`)

  /// Starts the camera and the encoder; the encoded size, or (0, 0).
  private func start(bound: Int, fps: Int, bitrate: Int, cameraId: String?) -> (Int, Int) {
    stop()
    run += 1
    let all = devices()
    #if targetEnvironment(simulator)
      if all.isEmpty || cameraId == CameraCapturer.simulatedId {
        return startPattern(bound: bound, fps: fps, bitrate: bitrate)
      }
    #endif
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return (0, 0) }
    // The camera asked for, else the first on the back, else the first.
    guard
      let device = all.first(where: { $0.uniqueID == cameraId })
        ?? all.first(where: { $0.position == .back }) ?? all.first,
      let input = try? AVCaptureDeviceInput(device: device)
    else { return (0, 0) }

    // The largest format within the bound that can run at the rate asked for.
    func dimensions(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
      CMVideoFormatDescriptionGetDimensions(f.formatDescription)
    }
    func reaches(_ f: AVCaptureDevice.Format, _ rate: Int) -> Bool {
      f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(rate) - 0.5 }
    }
    let fitting = device.formats.filter {
      let d = dimensions($0)
      return Int(max(d.width, d.height)) <= max(bound, 320)
    }
    let pool = fitting.isEmpty ? device.formats : fitting
    let atRate = pool.filter { reaches($0, fps) }
    guard
      let format = (atRate.isEmpty ? pool : atRate).max(by: {
        let a = dimensions($0)
        let b = dimensions($1)
        return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
      })
    else { return (0, 0) }

    let capture = AVCaptureSession()
    capture.beginConfiguration()
    capture.sessionPreset = .inputPriority
    guard capture.canAddInput(input) else { return (0, 0) }
    capture.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ]
    // Late frames are dropped, not queued: this is a live picture.
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: queue)
    guard capture.canAddOutput(output) else { return (0, 0) }
    capture.addOutput(output)
    do {
      try device.lockForConfiguration()
      device.activeFormat = format
      let top = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30
      let rate = min(Double(fps), top)
      let frame = CMTime(value: 1000, timescale: CMTimeScale((rate * 1000).rounded()))
      device.activeVideoMinFrameDuration = frame
      device.activeVideoMaxFrameDuration = frame
      device.unlockForConfiguration()
    } catch {
      return (0, 0)
    }
    capture.commitConfiguration()

    let size = dimensions(format)
    guard makeEncoder(width: Int(size.width), height: Int(size.height), fps: fps, bitrate: bitrate)
    else { return (0, 0) }
    session = capture
    capture.startRunning()
    return (Int(size.width), Int(size.height))
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    encode(image, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
  }

  private func stop() {
    run += 1
    session?.stopRunning()
    session = nil
    pattern?.cancel()
    pattern = nil
    if let e = encoder {
      VTCompressionSessionInvalidate(e)
    }
    encoder = nil
    width = 0
    height = 0
  }

  // MARK: - the simulated camera

  #if targetEnvironment(simulator)
    private func startPattern(bound: Int, fps: Int, bitrate: Int) -> (Int, Int) {
      let size = bound >= 1280 ? (1280, 720) : (640, 360)
      guard makeEncoder(width: size.0, height: size.1, fps: fps, bitrate: bitrate) else {
        return (0, 0)
      }
      patternFrame = 0
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
      timer.setEventHandler { [weak self] in self?.drawPattern(fps: fps) }
      pattern = timer
      timer.resume()
      return size
    }

    /// Colour bars drifting sideways with a square swinging across them.
    private func drawPattern(fps: Int) {
      guard width > 0 else { return }
      var made: CVPixelBuffer?
      let attributes: [CFString: Any] = [
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
      ]
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        attributes as CFDictionary, &made)
      guard let pixels = made else { return }
      CVPixelBufferLockBaseAddress(pixels, [])
      if let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
      {
        let bars: [(CGFloat, CGFloat, CGFloat)] = [
          (0.9, 0.9, 0.9), (0.9, 0.9, 0.1), (0.1, 0.9, 0.9), (0.1, 0.8, 0.1),
          (0.9, 0.1, 0.9), (0.9, 0.1, 0.1), (0.1, 0.1, 0.9), (0.1, 0.1, 0.1),
        ]
        let w = CGFloat(width)
        let h = CGFloat(height)
        let bar = w / CGFloat(bars.count)
        let t = CGFloat(patternFrame) / CGFloat(fps)
        let shift = (t * w / 4).truncatingRemainder(dividingBy: w)
        for i in -bars.count..<bars.count {
          let c = bars[(i + bars.count) % bars.count]
          context.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
          context.fill(CGRect(x: CGFloat(i) * bar + shift, y: 0, width: bar + 1, height: h))
        }
        let side = h / 4
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(
          CGRect(
            x: (w - side) * (0.5 + 0.5 * sin(t * 2)), y: (h - side) / 2, width: side, height: side))
      }
      CVPixelBufferUnlockBaseAddress(pixels, [])
      patternFrame += 1
      encode(pixels, at: CMClockGetTime(CMClockGetHostTimeClock()))
    }
  #endif

  // MARK: - encoding (on `queue`)

  private func makeEncoder(width w: Int, height h: Int, fps: Int, bitrate: Int) -> Bool {
    var made: VTCompressionSession?
    guard
      VTCompressionSessionCreate(
        allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264,
        encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &made) == noErr,
      let e = made
    else { return false }
    VTSessionSetProperty(e, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(e, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(
      e, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
    VTSessionSetProperty(e, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
    // No keyframe on a schedule: one is sent when the viewer asks.
    VTSessionSetProperty(
      e, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Int32.max as CFNumber)
    VTSessionSetProperty(
      e, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 0 as CFNumber)
    encoder = e
    width = w
    height = h
    wantKeyframe = true
    apply(bitrate: bitrate)
    VTCompressionSessionPrepareToEncodeFrames(e)
    return true
  }

  private func apply(bitrate: Int) {
    guard let e = encoder, bitrate > 0 else { return }
    VTSessionSetProperty(e, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
    // A ceiling over one second as well, at half as much again: the average
    // alone is overrun freely on a hard picture.
    VTSessionSetProperty(
      e, key: kVTCompressionPropertyKey_DataRateLimits,
      value: [bitrate * 3 / 2 / 8, 1] as CFArray)
  }

  private func encode(_ image: CVImageBuffer, at time: CMTime) {
    guard let e = encoder else { return }
    let made = run
    var properties: CFDictionary?
    if wantKeyframe {
      wantKeyframe = false
      properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
    }
    VTCompressionSessionEncodeFrame(
      e, imageBuffer: image, presentationTimeStamp: time, duration: .invalid,
      frameProperties: properties, infoFlagsOut: nil
    ) { [weak self] status, _, sample in
      guard let self = self, status == noErr, let sample = sample,
        let unit = CameraCapturer.annexB(sample)
      else { return }
      let ptsUs = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1_000_000)
      DispatchQueue.main.async {
        // `run` is read here without the queue: a stale frame at worst.
        guard made == self.run else { return }
        self.sink?([
          "bytes": FlutterStandardTypedData(bytes: unit.bytes), "keyframe": unit.keyframe,
          "ptsUs": ptsUs,
        ])
      }
    }
  }

  /// One encoded sample as an Annex-B access unit, with the parameter sets in
  /// front when it is a keyframe.
  static func annexB(_ sample: CMSampleBuffer) -> (bytes: Data, keyframe: Bool)? {
    guard let block = CMSampleBufferGetDataBuffer(sample),
      let format = CMSampleBufferGetFormatDescription(sample)
    else { return nil }
    var notSync = false
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
      as? [[CFString: Any]], let first = attachments.first
    {
      notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    }
    let keyframe = !notSync
    let startCode: [UInt8] = [0, 0, 0, 1]
    var unit = Data()
    if keyframe {
      var count = 0
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
        parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
      for index in 0..<count {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
          format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
          parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        if let pointer = pointer {
          unit.append(contentsOf: startCode)
          unit.append(pointer, count: size)
        }
      }
    }
    // AVCC (4-byte lengths) to Annex-B.
    let total = CMBlockBufferGetDataLength(block)
    var avcc = Data(count: total)
    let copied = avcc.withUnsafeMutableBytes {
      CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!)
    }
    guard copied == kCMBlockBufferNoErr else { return nil }
    var offset = 0
    while offset + 4 <= total {
      let length = avcc.subdata(in: offset..<offset + 4).reduce(0) { ($0 << 8) | Int($1) }
      offset += 4
      guard length > 0, offset + length <= total else { break }
      unit.append(contentsOf: startCode)
      unit.append(avcc.subdata(in: offset..<offset + length))
      offset += length
    }
    return unit.isEmpty ? nil : (unit, keyframe)
  }
}
