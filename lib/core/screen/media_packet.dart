// The media wire format (docs/protocol.md 7.1, screen/camera 2.0): every
// datagram of a session is numbered in one sequence, media and repair alike,
// so the receiver can tell the sender exactly which arrived and when. The
// same layout as the desktop's MediaPacket.hpp.

import 'dart:typed_data';

const int maxDatagram = 1100; // the library's datagram limit
const int mediaHeader = 21;
const int fecHeader = 3; // group size, XOR of lengths
// A repair packet carries a fragment-sized XOR after its own header, so
// fragments leave room for it.
const int mediaPayload = maxDatagram - mediaHeader - fecHeader;
const int maxFrameBytes = 4 * 1024 * 1024;
const int maxFragments = (maxFrameBytes + mediaPayload - 1) ~/ mediaPayload;
const int maxFps = 165;
const int minBitrate = 150000;
const int maxBitrate = 100000000;

/// True if sequence [a] comes after [b] (32-bit wrap).
bool seqNewer(int a, int b) => ((a - b) & 0xFFFFFFFF).toSigned(32) > 0;

enum PacketType { media, fec, feedback }

class EncodedFrame {
  EncodedFrame(this.session, this.number, this.captureMs, this.keyframe, this.bytes);
  final int session, number, captureMs;
  final bool keyframe;
  final Uint8List bytes;
}

/// A media packet carries one fragment of a frame ([frag] of [count]). A
/// repair packet carries the same frame fields, [frag] being the first of a
/// group of consecutive fragments, and as payload the group's size (one
/// byte), the XOR of the fragments' lengths and the XOR of their payloads
/// (zero-padded): any one of them that is lost can be rebuilt from the others.
class MediaPacket {
  MediaPacket({
    required this.kind,
    this.type = PacketType.media,
    required this.session,
    required this.seq,
    required this.frame,
    required this.frag,
    required this.count,
    required this.captureMs,
    this.keyframe = false,
    this.retransmit = false,
    required this.payload,
  });
  final int kind;
  final PacketType type;
  final int session, frame, frag, count, captureMs;
  int seq; // given when the packet is sent, so the numbers have no gaps
  final bool keyframe;
  bool retransmit;
  final Uint8List payload;

  int get size => mediaHeader + payload.length;
}

Uint8List encodeMedia(MediaPacket p) {
  final out = Uint8List(mediaHeader + p.payload.length);
  final bd = ByteData.sublistView(out);
  out[0] = p.kind;
  out[1] = p.type.index;
  bd.setUint16(2, p.session);
  bd.setUint32(4, p.seq & 0xFFFFFFFF);
  bd.setUint32(8, p.frame & 0xFFFFFFFF);
  bd.setUint16(12, p.frag);
  bd.setUint16(14, p.count);
  bd.setUint32(16, p.captureMs & 0xFFFFFFFF);
  out[20] = (p.keyframe ? 1 : 0) | (p.retransmit ? 2 : 0);
  out.setRange(mediaHeader, out.length, p.payload);
  return out;
}

MediaPacket? decodeMedia(Uint8List b) {
  if (b.length < mediaHeader || b.length > maxDatagram) return null;
  if (b[1] != PacketType.media.index && b[1] != PacketType.fec.index) return null;
  final bd = ByteData.sublistView(b);
  final p = MediaPacket(
    kind: b[0],
    type: PacketType.values[b[1]],
    session: bd.getUint16(2),
    seq: bd.getUint32(4),
    frame: bd.getUint32(8),
    frag: bd.getUint16(12),
    count: bd.getUint16(14),
    captureMs: bd.getUint32(16),
    keyframe: b[20] & 1 != 0,
    retransmit: b[20] & 2 != 0,
    payload: Uint8List.sublistView(b, mediaHeader),
  );
  if (p.session == 0 || p.count == 0 || p.count > maxFragments || p.frag >= p.count) return null;
  if (p.type == PacketType.fec &&
      (p.payload.length < fecHeader || p.payload[0] == 0 || p.frag + p.payload[0] > p.count)) {
    return null;
  }
  return p;
}

/// Sequence numbers for one session's packets.
class SeqCounter {
  int next = 0;
  int take() {
    final n = next;
    next = (next + 1) & 0xFFFFFFFF;
    return n;
  }
}

/// Splits a frame into media packets, each numbered in turn, with a repair
/// packet after every [fecGroup] fragments (0: none). Empty if the frame is
/// too large.
List<MediaPacket> packetize(int kind, EncodedFrame frame, SeqCounter seq, int fecGroup) {
  final out = <MediaPacket>[];
  if (frame.session == 0 || frame.bytes.isEmpty || frame.bytes.length > maxFrameBytes) return out;
  final count = (frame.bytes.length + mediaPayload - 1) ~/ mediaPayload;
  Uint8List? repair;
  var xorLength = 0, inGroup = 0, groupStart = 0, longest = 0;
  for (var index = 0; index < count; index++) {
    final start = index * mediaPayload;
    final end = start + mediaPayload > frame.bytes.length ? frame.bytes.length : start + mediaPayload;
    final payload = Uint8List.sublistView(frame.bytes, start, end);
    out.add(MediaPacket(
      kind: kind, session: frame.session, seq: seq.take(), frame: frame.number, frag: index, count: count,
      captureMs: frame.captureMs, keyframe: frame.keyframe, payload: payload,
    ));
    if (fecGroup <= 0) continue;
    if (inGroup == 0) {
      groupStart = index;
      repair = Uint8List(mediaPayload);
      xorLength = 0;
      longest = 0;
    }
    for (var i = 0; i < payload.length; i++) {
      repair![i] ^= payload[i];
    }
    xorLength ^= payload.length;
    if (payload.length > longest) longest = payload.length;
    inGroup++;
    if (inGroup == fecGroup || index + 1 == count) {
      // Only as long as the longest fragment it covers.
      final fec = Uint8List(fecHeader + longest);
      fec[0] = inGroup;
      ByteData.sublistView(fec).setUint16(1, xorLength);
      fec.setRange(fecHeader, fec.length, repair!, 0);
      out.add(MediaPacket(
        kind: kind, type: PacketType.fec, session: frame.session, seq: seq.take(), frame: frame.number,
        frag: groupStart, count: count, captureMs: frame.captureMs, keyframe: frame.keyframe, payload: fec,
      ));
      inGroup = 0;
    }
  }
  return out;
}

/// The receiver's word back to the sender, every few tens of milliseconds:
/// for each sequence from [baseSeq], when it arrived (quarter milliseconds
/// after [refTimeMs], on the receiver's clock) or that it did not; which
/// older ones it still wants again; the newest complete frame; and whether
/// it needs a keyframe. Clocks are never compared across devices: only the
/// differences between arrivals matter.
class Feedback {
  static const int maxArrivals = 200, maxNacks = 32;
  static const int missing = 0xFFFF;
  int session = 0;
  int baseSeq = 0;
  int refTimeMs = 0;
  int heldMs = 0; // from the newest arrival to this feedback being sent
  int latestFrame = 0, latestCaptureMs = 0;
  int playoutMs = 0; // the receiver's playout delay
  int decodeMs10 = 0; // decode time, tenths of a millisecond
  bool keyframeWanted = false, haveLatest = false;
  List<int> arrivals = []; // quarter ms after refTimeMs, or missing
  List<int> nacks = [];

  Uint8List encode(int kind) {
    final n = arrivals.length > maxArrivals ? maxArrivals : arrivals.length;
    final m = nacks.length > maxNacks ? maxNacks : nacks.length;
    final out = Uint8List(29 + 2 * n + 1 + 4 * m);
    final bd = ByteData.sublistView(out);
    out[0] = kind;
    out[1] = PacketType.feedback.index;
    bd.setUint16(2, session);
    bd.setUint32(4, baseSeq & 0xFFFFFFFF);
    bd.setUint16(8, n);
    bd.setUint32(10, refTimeMs & 0xFFFFFFFF);
    bd.setUint16(14, heldMs);
    bd.setUint32(16, latestFrame & 0xFFFFFFFF);
    bd.setUint32(20, latestCaptureMs & 0xFFFFFFFF);
    bd.setUint16(24, playoutMs);
    bd.setUint16(26, decodeMs10);
    out[28] = (keyframeWanted ? 1 : 0) | (haveLatest ? 2 : 0);
    var at = 29;
    for (var i = 0; i < n; i++, at += 2) {
      bd.setUint16(at, arrivals[i]);
    }
    out[at++] = m;
    for (var i = 0; i < m; i++, at += 4) {
      bd.setUint32(at, nacks[i] & 0xFFFFFFFF);
    }
    return out;
  }

  static Feedback? decode(Uint8List b) {
    if (b.length < 29 || b[1] != PacketType.feedback.index) return null;
    final bd = ByteData.sublistView(b);
    final f = Feedback()
      ..session = bd.getUint16(2)
      ..baseSeq = bd.getUint32(4)
      ..refTimeMs = bd.getUint32(10)
      ..heldMs = bd.getUint16(14)
      ..latestFrame = bd.getUint32(16)
      ..latestCaptureMs = bd.getUint32(20)
      ..playoutMs = bd.getUint16(24)
      ..decodeMs10 = bd.getUint16(26)
      ..keyframeWanted = b[28] & 1 != 0
      ..haveLatest = b[28] & 2 != 0;
    final count = bd.getUint16(8);
    var at = 29;
    if (count > maxArrivals || b.length < at + 2 * count + 1) return null;
    for (var i = 0; i < count; i++, at += 2) {
      f.arrivals.add(bd.getUint16(at));
    }
    final nacks = b[at++];
    if (nacks > maxNacks || b.length < at + 4 * nacks) return null;
    for (var i = 0; i < nacks; i++, at += 4) {
      f.nacks.add(bd.getUint32(at));
    }
    if (f.session == 0) return null;
    return f;
  }
}

/// Which packet type a datagram of a media kind carries, without decoding it.
PacketType? packetType(Uint8List b) {
  if (b.length < 2 || b[1] > 2) return null;
  return PacketType.values[b[1]];
}
