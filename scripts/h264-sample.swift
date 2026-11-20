// Writes a short H.264 test stream for integration_test/decoder_e2e_test.dart:
// a synthetic moving picture encoded with this Mac's VideoToolbox, shaped like
// the stream a uConnect host sends (Annex-B access units, no B-frames, SPS and
// PPS inside every keyframe).
//
//   swift scripts/h264-sample.swift <out file> [width height frames fps]
//
// File format, repeated per access unit: a 4-byte big-endian length, one byte
// that is 1 for a keyframe, then that many bytes of Annex-B.
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

let args = CommandLine.arguments
guard args.count >= 2 else {
  FileHandle.standardError.write("usage: h264-sample.swift <out> [width height frames fps]\n".data(using: .utf8)!)
  exit(2)
}
let outPath = args[1]
let width = args.count > 2 ? Int(args[2])! : 640
let height = args.count > 3 ? Int(args[3])! : 360
let frames = args.count > 4 ? Int(args[4])! : 90
let fps = args.count > 5 ? Int(args[5])! : 30

var output = Data()
var units = 0
var keyframes = 0
let startCode: [UInt8] = [0, 0, 0, 1]

func append(_ sample: CMSampleBuffer) {
  guard let block = CMSampleBufferGetDataBuffer(sample),
    let format = CMSampleBufferGetFormatDescription(sample)
  else { return }
  var notSync = false
  if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
    as? [[CFString: Any]], let first = attachments.first
  {
    notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
  }
  let keyframe = !notSync
  var unit = Data()
  if keyframe {
    for index in 0..<2 {
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
  avcc.withUnsafeMutableBytes {
    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!)
  }
  var offset = 0
  while offset + 4 <= total {
    let length = avcc.subdata(in: offset..<offset + 4).reduce(0) { ($0 << 8) | Int($1) }
    offset += 4
    guard length > 0, offset + length <= total else { break }
    unit.append(contentsOf: startCode)
    unit.append(avcc.subdata(in: offset..<offset + length))
    offset += length
  }
  var length = UInt32(unit.count).bigEndian
  withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
  output.append(keyframe ? 1 : 0)
  output.append(unit)
  units += 1
  if keyframe { keyframes += 1 }
}

var made: VTCompressionSession?
guard
  VTCompressionSessionCreate(
    allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
    encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
    outputCallback: nil, refcon: nil, compressionSessionOut: &made) == noErr,
  let session = made
else {
  FileHandle.standardError.write("could not create the encoder\n".data(using: .utf8)!)
  exit(1)
}
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
VTSessionSetProperty(
  session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
VTSessionSetProperty(
  session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFNumber)
VTSessionSetProperty(
  session, key: kVTCompressionPropertyKey_AverageBitRate, value: 1_500_000 as CFNumber)
VTCompressionSessionPrepareToEncodeFrames(session)

let attributes: [CFString: Any] = [
  kCVPixelBufferCGImageCompatibilityKey: true,
  kCVPixelBufferCGBitmapContextCompatibilityKey: true,
  kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
]
let colors = CGColorSpaceCreateDeviceRGB()
for frame in 0..<frames {
  var buffer: CVPixelBuffer?
  CVPixelBufferCreate(
    kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary,
    &buffer)
  guard let pixels = buffer else { exit(1) }
  CVPixelBufferLockBaseAddress(pixels, [])
  let context = CGContext(
    data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: colors,
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
  // Eight colour bars, a white square crossing them, and a progress strip:
  // the last picture has the square at the right edge and the strip full.
  let bars: [(CGFloat, CGFloat, CGFloat)] = [
    (0.9, 0.9, 0.9), (0.9, 0.9, 0.1), (0.1, 0.9, 0.9), (0.1, 0.8, 0.1),
    (0.9, 0.1, 0.9), (0.9, 0.1, 0.1), (0.1, 0.1, 0.9), (0.1, 0.1, 0.1),
  ]
  let barWidth = CGFloat(width) / CGFloat(bars.count)
  for (i, c) in bars.enumerated() {
    context.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    context.fill(CGRect(x: CGFloat(i) * barWidth, y: 0, width: barWidth + 1, height: CGFloat(height)))
  }
  let progress = CGFloat(frame) / CGFloat(max(frames - 1, 1))
  let side = CGFloat(height) / 4
  context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
  context.fill(
    CGRect(x: progress * (CGFloat(width) - side), y: (CGFloat(height) - side) / 2, width: side, height: side))
  context.setFillColor(red: 1, green: 0.4, blue: 0, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: progress * CGFloat(width), height: CGFloat(height) / 12))
  CVPixelBufferUnlockBaseAddress(pixels, [])

  let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
  VTCompressionSessionEncodeFrame(
    session, imageBuffer: pixels, presentationTimeStamp: pts, duration: .invalid,
    frameProperties: nil, infoFlagsOut: nil
  ) { status, _, sample in
    if status == noErr, let sample = sample { append(sample) }
  }
}
VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
VTCompressionSessionInvalidate(session)

guard units == frames else {
  FileHandle.standardError.write("encoded \(units) of \(frames) frames\n".data(using: .utf8)!)
  exit(1)
}
try! output.write(to: URL(fileURLWithPath: outPath))
print("\(outPath): \(units) access units, \(keyframes) keyframes, \(width)x\(height) at \(fps) fps, \(output.count) bytes")
