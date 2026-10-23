// The receiving side of a media session: packets become frames (lost
// fragments rebuilt from repair packets where possible), frames are handed
// out in order, and every few tens of milliseconds the sender hears exactly
// which packets arrived and when, which ones to send again, and whether a
// keyframe is needed. A frame that makes no progress for a while is given up
// and the stream restarts from the next keyframe. The same algorithm as the
// desktop's MediaReceiver.cpp.

import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'media_packet.dart';

class _Repair {
  _Repair(this.size, this.payload);
  final int size;
  final Uint8List payload;
}

class _Assembly {
  _Assembly(this.frame, this.count, int nowMs, int seq)
      : parts = List<Uint8List?>.filled(count, null),
        firstMs = nowMs,
        lastMs = nowMs,
        lowSeq = seq,
        highSeq = seq;
  final EncodedFrame frame; // bytes filled in once whole
  final List<Uint8List?> parts;
  final int count;
  int got = 0;
  int firstMs, lastMs; // first and latest packet of it arriving
  int lowSeq, highSeq; // its packets' sequence range
  final repairs = SplayTreeMap<int, _Repair>();
  Uint8List? whole;
  bool get complete => got == count;

  // A repair packet rebuilds one missing fragment of its group once every
  // other fragment of the group is in.
  bool tryRepair() {
    var any = false;
    for (final start in repairs.keys.toList()) {
      final repair = repairs[start]!;
      final end = min(start + repair.size, count);
      var missing = -1, missingCount = 0;
      for (var i = start; i < end; i++) {
        if (parts[i] == null) {
          missing = i;
          missingCount++;
        }
      }
      if (missingCount == 0) {
        repairs.remove(start);
        continue;
      }
      if (missingCount > 1) continue;
      var length = ByteData.sublistView(repair.payload).getUint16(1);
      final data = Uint8List.fromList(Uint8List.sublistView(repair.payload, fecHeader));
      for (var i = start; i < end; i++) {
        if (i == missing) continue;
        final part = parts[i]!;
        length ^= part.length;
        for (var k = 0; k < part.length && k < data.length; k++) {
          data[k] ^= part[k];
        }
      }
      if (length > data.length) {
        repairs.remove(start);
        continue;
      }
      parts[missing] = Uint8List.sublistView(data, 0, length);
      got++;
      any = true;
      repairs.remove(start);
    }
    return any;
  }
}

/// This report period's counters (reset by [MediaReceiver.report]).
class ReceiverStats {
  int received = 0, lost = 0, recovered = 0, late = 0, repaired = 0, givenUp = 0, discarded = 0;
}

class MediaReceiver {
  MediaReceiver({required this.session, required this.kind, int fps = 30}) : interval = 1000 ~/ fps.clamp(1, maxFps);

  static const int feedbackIntervalMs = 50, keepAliveMs = 500;
  static const int _maxPendingFrames = 32;
  static const int _nackAfterMs = 10; // a gap this old is asked for
  static const int _missingForgetMs = 2000;

  final int session, kind, interval;
  bool waiting = true, _haveLast = false, keyWanted = false;
  int _last = 0;
  final _frames = SplayTreeMap<int, _Assembly>();
  final _arrivals = SplayTreeMap<int, int>(); // seq -> arrival, since the last feedback
  bool _haveSeq = false;
  int _highestSeq = 0, _feedbackBase = 0;
  final _missing = SplayTreeMap<int, int>(); // seq -> when first noticed
  int _nackFloor = 0;
  bool _haveFloor = false; // the last delivered frame's highest sequence
  int _lastFeedbackMs = 0, _newestArrivalMs = 0;
  var _stats = ReceiverStats();
  int? latestCaptureMs;
  int _latestFrame = 0;
  double jitterMs = 0, trendMs = 0;
  double? _previousTransit;

  bool get waitingForKeyframe => waiting;
  int get pendingFrames => _frames.length;
  ReceiverStats get stats => _stats;

  void _noteArrival(int seq, int nowMs) {
    _arrivals[seq] = nowMs;
    _newestArrivalMs = nowMs;
    if (!_haveSeq) {
      _haveSeq = true;
      _highestSeq = seq;
      _feedbackBase = seq;
      return;
    }
    if (seqNewer(seq, _highestSeq)) {
      // Everything between is missing until it shows up.
      for (var s = (_highestSeq + 1) & 0xFFFFFFFF; seqNewer(seq, s) && _missing.length < 1000; s = (s + 1) & 0xFFFFFFFF) {
        _missing[s] = nowMs;
      }
      _highestSeq = seq;
    } else {
      // A gap filled: how long that took is what a playout buffer must cover.
      final since = _missing.remove(seq);
      if (since != null && nowMs - since > repairDelayMs) repairDelayMs = (nowMs - since).toDouble();
    }
  }

  /// The longest a recent gap took to fill (a repeat arriving, or the packet
  /// merely late), fading over a few seconds: with the jitter, what the
  /// playout buffer should cover to show every frame in cadence.
  double repairDelayMs = 0;
  int _lastExpireMs = 0;

  /// The playout delay that would show every frame on time, from the jitter
  /// and the time gaps take to fill; the caller smooths it.
  int suggestedPlayoutMs() => (interval + 2 * jitterMs + repairDelayMs).round().clamp(20, 500);

  /// A media or repair packet; returns the frames now complete and in order.
  List<EncodedFrame> receive(Uint8List packet, int nowMs) {
    final p = decodeMedia(packet);
    if (p == null || p.session != session || p.kind != kind) return const [];
    _noteArrival(p.seq, nowMs);
    _stats.received++;
    if (p.retransmit) _stats.repaired++;
    if (_haveLast && !seqNewer(p.frame, _last)) {
      _stats.late++;
      return const [];
    }
    var a = _frames[p.frame];
    if (a == null) {
      if (waiting && !p.keyframe) {
        _stats.discarded++; // useless until a keyframe
        return const [];
      }
      if (_frames.length >= _maxPendingFrames) {
        _give(_frames.firstKey()!);
        waiting = true;
        keyWanted = true;
      }
      a = _Assembly(EncodedFrame(session, p.frame, p.captureMs, p.keyframe, Uint8List(0)), p.count, nowMs, p.seq);
      _frames[p.frame] = a;
    }
    if (a.count != p.count) return const []; // not the same frame
    a.lastMs = nowMs;
    if (seqNewer(a.lowSeq, p.seq)) a.lowSeq = p.seq;
    if (seqNewer(p.seq, a.highSeq)) a.highSeq = p.seq;
    if (p.type == PacketType.fec) {
      a.repairs[p.frag] = _Repair(p.payload[0], Uint8List.fromList(p.payload));
    } else if (a.parts[p.frag] == null) {
      a.parts[p.frag] = Uint8List.fromList(p.payload);
      a.got++;
    }
    if (!a.complete && a.repairs.isNotEmpty && a.tryRepair()) _stats.recovered++;
    if (a.complete && a.whole == null) {
      final b = BytesBuilder(copy: false);
      for (final part in a.parts) {
        b.add(part!);
      }
      a.whole = b.takeBytes();
      // Whole: whatever of it is still missing (rebuilt from repair
      // packets) need not be sent again.
      _forgetMissing(a.lowSeq, a.highSeq);
      // Transit (arrival minus capture, clocks mixed): its variation is the
      // jitter, its drift a queue building on the path.
      final transit = ((nowMs - a.frame.captureMs) & 0xFFFFFFFF).toSigned(32).toDouble();
      final previous = _previousTransit;
      if (previous != null) {
        final delta = transit - previous;
        jitterMs += (delta.abs() - jitterMs) / 16;
        trendMs += (delta - trendMs) / 8;
      }
      _previousTransit = transit;
    }
    return _deliver();
  }

  void _forgetMissing(int low, int high) {
    _missing.removeWhere((seq, _) => !seqNewer(low, seq) && !seqNewer(seq, high));
  }

  List<EncodedFrame> _deliver() {
    final out = <EncodedFrame>[];
    // A complete keyframe may skip whatever is incomplete before it.
    for (final entry in _frames.entries) {
      if (entry.value.complete && entry.value.frame.keyframe && (!_haveLast || seqNewer(entry.key, _last))) {
        _last = (entry.key - 1) & 0xFFFFFFFF;
        _haveLast = true;
        waiting = false;
        keyWanted = false;
        break;
      }
    }
    if (waiting || !_haveLast) return out;
    while (true) {
      final next = (_last + 1) & 0xFFFFFFFF;
      final a = _frames[next];
      if (a == null || !a.complete) break;
      _last = next;
      latestCaptureMs = a.frame.captureMs;
      _latestFrame = next;
      if (!_haveFloor || seqNewer(a.highSeq, _nackFloor)) {
        _nackFloor = a.highSeq;
        _haveFloor = true;
      }
      out.add(EncodedFrame(session, next, a.frame.captureMs, a.frame.keyframe, a.whole!));
      _frames.remove(next);
    }
    _frames.removeWhere((number, _) => !seqNewer(number, _last));
    return out;
  }

  void _give(int number) {
    final a = _frames.remove(number);
    if (a == null) return;
    _stats.givenUp++;
    _forgetMissing(a.lowSeq, a.highSeq);
  }

  /// Gives up on frames too old to complete; call often (each tick).
  void expire(int nowMs) {
    // A frame that has made no progress for a while (repeats had their
    // chance: several round trips) is given up with those behind it that
    // depend on it; the stream restarts at the next keyframe. A big frame
    // still arriving is not stuck, however long it takes.
    final giveUpMs = max(400, 8 * interval);
    for (final number in _frames.keys.toList()) {
      final a = _frames[number]!;
      if (a.complete || nowMs - a.lastMs < giveUpMs) continue;
      _give(number);
      waiting = true;
      keyWanted = true;
    }
    _missing.removeWhere((seq, since) => nowMs - since > _missingForgetMs);
    if (_lastExpireMs != 0) repairDelayMs *= pow(0.5, (nowMs - _lastExpireMs) / 3000);
    _lastExpireMs = nowMs;
  }

  bool feedbackDue(int nowMs) {
    // With nothing arriving yet (or a still screen sending nothing), a word
    // every half second keeps the session alive. Sooner when a keyframe is
    // wanted, but not every packet: the sender reads its send rate from each
    // feedback's window.
    if (!_haveSeq) return nowMs - _lastFeedbackMs >= keepAliveMs;
    return nowMs - _lastFeedbackMs >= feedbackIntervalMs ||
        ((_highestSeq - _feedbackBase) & 0xFFFFFFFF).toSigned(32) >= Feedback.maxArrivals - 20 ||
        (keyWanted && nowMs - _lastFeedbackMs >= feedbackIntervalMs ~/ 2);
  }

  /// The feedback to send now: [playoutMs] the playout delay in use,
  /// [decodeMs] the decode time, for the sender's view.
  Uint8List takeFeedback(int nowMs, int playoutMs, double decodeMs) {
    final f = Feedback()
      ..session = session
      ..baseSeq = _feedbackBase;
    // Arrival times are quarter milliseconds after a reference 16 s ago, so
    // anything from the last 16 s fits in 16 bits.
    final ref = nowMs - 16000;
    f.refTimeMs = ref & 0xFFFFFFFF;
    f.heldMs = (nowMs - _newestArrivalMs).clamp(0, 65535);
    f.latestFrame = _latestFrame;
    f.latestCaptureMs = latestCaptureMs ?? 0;
    f.haveLatest = latestCaptureMs != null;
    f.playoutMs = playoutMs.clamp(0, 65535);
    f.decodeMs10 = (decodeMs * 10).toInt().clamp(0, 65535);
    // A keyframe is wanted unless one is already arriving (a packet of it in
    // the last 100 ms): asking again would only bring a second one.
    var keyArriving = false;
    for (final a in _frames.values) {
      if (a.frame.keyframe && !a.complete && nowMs - a.lastMs < 100) keyArriving = true;
    }
    f.keyframeWanted = keyWanted && !keyArriving;
    // Every sequence from the base to the highest seen: when it arrived, or
    // that it has not (the sender counts those lost, and sends again the
    // ones asked for below).
    final span = _haveSeq ? min(((_highestSeq - _feedbackBase) & 0xFFFFFFFF).toSigned(32) + 1, Feedback.maxArrivals) : 0;
    for (var i = 0; i < span; i++) {
      final seq = (_feedbackBase + i) & 0xFFFFFFFF;
      final at = _arrivals[seq];
      if (at == null) _stats.lost++;
      f.arrivals.add(at == null ? Feedback.missing : ((at - ref) * 4).clamp(0, 65534));
    }
    _feedbackBase = (_feedbackBase + span) & 0xFFFFFFFF;
    _arrivals.removeWhere((seq, _) => !seqNewer(seq, (_feedbackBase - 1) & 0xFFFFFFFF));
    // Still missing, old enough to be a loss rather than reordering, and
    // after the last frame delivered (packets of delivered frames are not
    // wanted, and would crowd out the ones that are): asked for again.
    for (final seq in _missing.keys.toList()) {
      if (_haveFloor && !seqNewer(seq, _nackFloor)) {
        _missing.remove(seq);
        continue;
      }
      if (nowMs - _missing[seq]! >= _nackAfterMs && f.nacks.length < Feedback.maxNacks) f.nacks.add(seq);
    }
    _lastFeedbackMs = nowMs;
    return f.encode(kind);
  }

  void requestKeyframe() => keyWanted = true;

  /// Drops everything being assembled and waits for a keyframe (the decoder
  /// lost its way, or fell far behind).
  void restartFromKeyframe() {
    _frames.clear();
    waiting = true;
    keyWanted = true;
  }

  ReceiverStats report() {
    final out = _stats;
    _stats = ReceiverStats();
    return out;
  }
}
