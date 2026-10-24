// The sending side of a media session, the way real-time services send:
// frames are cut into numbered packets, with repair packets when the path
// loses some, and paced out at a steady rate a little above the bitrate the
// estimator allows rather than a burst per frame. The queue normally drains as fast as it
// fills; it may swell to a lag budget of a second (a burst, a spell of
// loss) before the capture is told to skip (an encoded frame is never
// dropped: the frames after it would be useless), and a viewer that falls
// behind the budget is brought back with a keyframe. The receiver's feedback
// drives the bandwidth estimate, repeats of lost packets, keyframes, and the
// lag. The same algorithm as the desktop's MediaSender.cpp.

import 'dart:math';
import 'dart:typed_data';

import 'bandwidth.dart';
import 'media_packet.dart';

class _Sent {
  _Sent(this.bytes, this.sentMs, this.lastRepeatMs, this.size);
  final Uint8List bytes;
  int sentMs, lastRepeatMs;
  final int size;
  bool acknowledged = false, lost = false;
}

class MediaSender {
  MediaSender({
    required this.kind,
    required this.session,
    int startBps = 1500000,
    this.minBps = 150000,
    this.maxBps = 100000000,
    this.pacingGain = 1.5,
    this.queueMs = lagBudgetMs,
    int fps = 30,
  })  : fps = max(1, fps),
        _bwe = BandwidthEstimator(startBps: startBps, minBps: minBps, maxBps: maxBps);

  static const int _sentHistoryMs = 2000; // packets kept for repeats
  static const int _repeatSpacingMs = 40; // one repeat of a packet per this long
  static const int _maxBurstBytes = 3 * maxDatagram;

  final int kind, session, minBps, maxBps, queueMs;
  final double pacingGain;
  int fps;
  final BandwidthEstimator _bwe;
  final _seq = SeqCounter();
  final _queue = <MediaPacket>[];
  int queuedBytes = 0;
  double _budgetBytes = 3 * maxDatagram.toDouble();
  int _lastPumpMs = 0;
  final _sent = <int, _Sent>{}; // recent packets by sequence, for repeats and feedback
  double rttMs = 0, lagMs = 0;
  bool _haveLag = false;
  int _lagSinceMs = -1, _lagCutMs = -100000; // the viewer behind by half the budget: since when, last cut
  int fecGroup = 0;
  int lastSentCaptureMs = 0;
  bool awaitKey = false; // the next frame must be a keyframe
  int _lastKeyMs = -100000, _behindAt = -100000;
  int dropped = 0, retransmitted = 0;

  int get targetBps => _bwe.targetBps;
  int get receiveBps => _bwe.receiveBps;
  int get sendBps => _bwe.sendBps;
  double get lossRate => _bwe.lossRate;
  String get estimatorState => _bwe.state;
  bool get pathLimited => _bwe.limited;
  bool get applicationLimited => _bwe.applicationLimited;

  /// The encoder's rate averaged over the last second or so: what the quality
  /// ladder goes by, so a spell of repair packets does not step it.
  int get smoothedEncoderBps => _smoothEncoderBps.toInt();
  double _smoothEncoderBps = 0;

  /// What the encoder should produce: the path's rate less the repair
  /// packets' share and the repeats.
  int get encoderBps {
    var share = fecGroup > 0 ? fecGroup / (fecGroup + 1) : 1.0;
    share *= 1 - min(_bwe.lossRate, 0.5);
    return max(minBps ~/ 2, (_bwe.targetBps * share).toInt());
  }

  /// False if the frame is dropped: the sender waits for a keyframe after
  /// dropping its queue (the next frame encoded must be one), or the frame
  /// cannot be packetized.
  bool enqueue(EncodedFrame frame) {
    if (awaitKey && !frame.keyframe) {
      dropped++;
      return false;
    }
    // Repair packets in proportion to what the path loses, sized for its
    // spells of loss rather than the mean: none when it is clean, one per
    // two fragments when it loses a lot, one per fragment (each sent twice,
    // in effect) when it loses most of a spell.
    final loss = max(_bwe.lossRate, _bwe.burstLossRate);
    fecGroup = loss < 0.02 ? 0 : loss < 0.08 ? 8 : loss < 0.20 ? 4 : loss < 0.45 ? 2 : 1;
    // A keyframe is big and everything after it depends on it: protected
    // more, so it needs fewer repeats.
    final group = frame.keyframe && fecGroup > 2 ? 2 : fecGroup;
    // Sequence numbers are given as packets leave (pump): a queue dropped
    // before it was sent must not read as loss at the receiver.
    final packets = packetize(kind, frame, SeqCounter(), group);
    if (packets.isEmpty) {
      dropped++;
      return false;
    }
    awaitKey = false;
    for (final p in packets) {
      _queue.add(p);
      queuedBytes += p.size;
    }
    lastSentCaptureMs = frame.captureMs;
    return true;
  }

  /// Capturing should pause: the queue is deep enough (the lag budget) that
  /// a new frame would only add lag.
  bool shouldSkipCapture() => queuedBytes > _bwe.targetBps * queueMs ~/ 8000;

  /// Sends what the pacing budget allows; call every few milliseconds.
  /// Returns false if the transport refused a packet (try again soon).
  bool pump(int nowMs, bool Function(Uint8List) send) {
    // Pacing: a budget of bytes grows at the pacing rate and is spent on
    // packets in order; a frame's packets leave a few at a time.
    final rate = _bwe.targetBps * pacingGain / 8000; // bytes per ms
    if (_lastPumpMs != 0) _budgetBytes = min(_budgetBytes + rate * (nowMs - _lastPumpMs), _maxBurstBytes + rate * 5);
    final weight = _lastPumpMs != 0 && _smoothEncoderBps > 0 ? min(1.0, (nowMs - _lastPumpMs) / 1000) : 1.0;
    _smoothEncoderBps += (encoderBps - _smoothEncoderBps) * weight;
    _lastPumpMs = nowMs;
    _trimSent(nowMs);
    while (_queue.isNotEmpty) {
      final p = _queue.first;
      final size = p.size;
      if (_budgetBytes < size) break;
      if (!p.retransmit) p.seq = _seq.take(); // a repeat keeps the number the receiver asked for
      final bytes = encodeMedia(p);
      if (!send(bytes)) return false; // refused for now (the path is still opening, or TCP pushes back)
      _budgetBytes -= size;
      queuedBytes -= size;
      final before = _sent[p.seq];
      _sent[p.seq] = _Sent(bytes, nowMs, before?.lastRepeatMs ?? 0, size); // a repeat keeps its spacing
      _queue.removeAt(0);
    }
    return true;
  }

  void _trimSent(int nowMs) {
    _sent.removeWhere((seq, s) => nowMs - s.sentMs > _sentHistoryMs);
  }

  /// The receiver's feedback: arrivals (the bandwidth estimate), repeats,
  /// lag, keyframe requests.
  void onFeedback(Uint8List packet, int nowMs) {
    final f = Feedback.decode(packet);
    if (f == null || f.session != session) return;
    final results = <PacketResult>[];
    var newestSentMs = -1;
    for (var i = 0; i < f.arrivals.length; i++) {
      final seq = (f.baseSeq + i) & 0xFFFFFFFF;
      final s = _sent[seq];
      if (s == null || s.acknowledged) continue;
      if (f.arrivals[i] == Feedback.missing) {
        s.lost = true;
        results.add(PacketResult(sendMs: s.sentMs, arrivalMs: 0, bytes: s.size, received: false));
      } else {
        s.acknowledged = true;
        s.lost = false;
        final arrival = f.refTimeMs + f.arrivals[i] / 4;
        results.add(PacketResult(sendMs: s.sentMs, arrivalMs: arrival, bytes: s.size, received: true));
        if (s.sentMs > newestSentMs) newestSentMs = s.sentMs;
      }
    }
    // Round trip: from the newest reported packet leaving to its feedback
    // arriving, less the time the receiver held the feedback.
    if (newestSentMs >= 0) {
      final rtt = max(1.0, (nowMs - newestSentMs).toDouble() - f.heldMs);
      rttMs = rttMs > 0 ? 0.8 * rttMs + 0.2 * rtt : rtt;
    }
    results.sort((a, b) => a.sendMs.compareTo(b.sendMs));
    // The lag is known once the receiver has had a whole frame; before that
    // (a keyframe still on its way) the estimator goes by delay alone.
    if (f.haveLatest) _haveLag = true;
    if (results.isNotEmpty) _bwe.onFeedback(results, nowMs, rttMs, _haveLag ? lagMs : -1);
    // Repeats: what it still wants, once per 40 ms each, while it is recent.
    for (final seq in f.nacks) {
      final s = _sent[seq];
      if (s == null || nowMs - s.lastRepeatMs < _repeatSpacingMs) continue;
      s.lastRepeatMs = nowMs;
      s.lost = true;
      // Repeats go out ahead of new packets, paced with them.
      final again = decodeMedia(s.bytes);
      if (again != null) {
        again.retransmit = true;
        _queue.insert(0, again);
        queuedBytes += s.size;
        retransmitted++;
      }
    }
    // Lag: the newest frame it has against the newest queued, on this clock.
    // Beyond the budget, the queue is dropped and the stream starts over
    // from a keyframe; above half of it for a couple of seconds, the path is
    // not carrying the rate (a loss figure never shows that on a path that
    // queues), and the target comes down.
    if (f.haveLatest) lagMs = max(0, ((lastSentCaptureMs - f.latestCaptureMs) & 0xFFFFFFFF).toSigned(32)).toDouble();
    if (lagMs > lagBudgetMs && nowMs - _behindAt > 1500) {
      _behindAt = nowMs;
      dropQueued();
    }
    if (lagMs > lagBudgetMs / 2) {
      _lagSinceMs = _lagSinceMs < 0 ? nowMs : _lagSinceMs;
      if (nowMs - _lagSinceMs > 2000 && nowMs - _lagCutMs > 2000) {
        _lagCutMs = nowMs;
        _bwe.limitTo((0.85 * _bwe.targetBps).toInt());
      }
    } else {
      _lagSinceMs = -1;
    }
    if (f.keyframeWanted) awaitKey = true;
  }

  /// The next frame encoded should be a keyframe: the receiver asked for one
  /// (it lost a reference), or the queue was dropped. Not more often than a
  /// couple of round trips, so one request answered on its way is not
  /// answered twice; each costs several frames' worth of bytes.
  bool takeKeyframeWanted(int nowMs) {
    if (!awaitKey) return false;
    if (nowMs - _lastKeyMs < max(150, rttMs)) return false;
    _lastKeyMs = nowMs;
    return true;
  }

  /// The queue is dropped (a source change, the viewer far behind): the next
  /// frame must be a keyframe.
  void dropQueued() {
    for (final p in _queue) {
      if (!p.retransmit) dropped++;
    }
    _queue.clear();
    queuedBytes = 0;
    awaitKey = true;
  }

  bool get idle => _queue.isEmpty;
}
