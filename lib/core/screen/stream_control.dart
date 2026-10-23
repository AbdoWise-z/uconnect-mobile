// The streaming feedback loop's arithmetic (docs/protocol.md 7.2), kept apart
// from the sessions so it can be tested: the sender's bitrate control, and the
// viewer's measure of how delay varies.

import 'dart:math';
import 'dart:typed_data';

/// The sender's bitrate: eased down a fifth on loss or rising delay (at most
/// once per few reports, so one bad patch is not punished repeatedly) and
/// raised about 8% per clean report, within [minBitrate, cap].
class BitrateControl {
  BitrateControl({required this.bitrate, required this.cap});

  static const minBitrate = 300000;

  int bitrate;
  int cap;
  int _cooldown = 0;

  /// Applies one viewer report; returns the new bitrate when it changed.
  int? report({required int received, required int lost, double trendMs = 0}) {
    if (_cooldown > 0) _cooldown--;
    final total = received + lost;
    if (total == 0) return null;
    final congested = lost / total > 0.05 || trendMs > 15;
    int next;
    if (congested) {
      if (_cooldown > 0) return null;
      _cooldown = 3;
      next = max(minBitrate, (bitrate * 0.8).round());
    } else {
      next = min(cap, max(bitrate + 100000, (bitrate * 1.08).round()));
    }
    if (next == bitrate) return null;
    bitrate = next;
    return next;
  }
}

/// Decides when a UDP path loses too much to stream over, from the viewer's
/// reports: some networks (mobile uplinks policing UDP) drop a large share of
/// datagrams at any rate, and the stream gets through only over TCP. True
/// once most of the last [window] reports lost more than [threshold] of what
/// was sent.
class LossyPath {
  LossyPath({this.window = 10, this.needed = 6, this.threshold = 0.15});

  final int window, needed;
  final double threshold;
  final _recent = <bool>[];

  bool report({required int received, required int lost}) {
    final total = received + lost;
    if (total == 0) return false;
    _recent.add(lost / total > threshold);
    if (_recent.length > window) _recent.removeAt(0);
    return _recent.length >= needed && _recent.where((bad) => bad).length >= needed;
  }

  void reset() => _recent.clear();
}

/// How the transit time of complete frames varies (arrival minus capture
/// time; the two clocks' offset cancels in the differences): the jitter, and
/// the trend, which rises while a queue builds on the path.
class DelayMeter {
  int? _previous;
  double jitterMs = 0, trendMs = 0;

  /// A frame captured at [captureMs] (the sender's clock, 32 bits) completed
  /// at [nowMs] (this device's).
  void frame(int captureMs, int nowMs) {
    final transit = ((nowMs - captureMs) & 0xFFFFFFFF).toSigned(32);
    final previous = _previous;
    if (previous != null) {
      final delta = (transit - previous).toDouble();
      jitterMs += (delta.abs() - jitterMs) / 16;
      trendMs += (delta - trendMs) / 8;
    }
    _previous = transit;
  }

  void reset() {
    _previous = null;
    jitterMs = trendMs = 0;
  }
}

/// Sends each frame's datagrams spread over part of a frame interval instead
/// of in one burst (docs/protocol.md 7.2, as the desktop's PacedSender): a
/// keyframe sent all at once overflows socket buffers and the path, and every
/// datagram lost there costs the whole frame. A datagram the transport refuses
/// is retried on the next pump. Frames too old to be worth showing are dropped
/// with every frame behind them (they depend on it); the caller then asks the
/// encoder for a keyframe.
class PacedSender {
  PacedSender({this.maxQueuedFrames = 3});

  /// Frames that may wait; more are dropped. Enough to hold the frames
  /// produced while a keyframe is still being spread out.
  final int maxQueuedFrames;

  final _queue = <_PacedFrame>[];
  int dropped = 0;
  /// How long a frame may be held up by the transport refusing it before it
  /// is dropped (at least four frame intervals). Longer over TCP, which only
  /// pushes back for a while and loses nothing.
  int stuckMs = 150;
  int _intervalMs = 33;

  bool get idle => _queue.isEmpty;

  /// Queues one frame's datagrams. False if the queue is full: the frame is
  /// dropped, and the caller should ask for a keyframe.
  bool add(List<Uint8List> packets, int nowMs,
      {required int intervalMs, int paceBps = 0, int maxSpreadMs = 60}) {
    if (_queue.length >= maxQueuedFrames) {
      dropped++;
      return false;
    }
    if (packets.isEmpty) return true;
    _intervalMs = intervalMs.clamp(4, 1000);
    final start = _queue.isEmpty ? nowMs : max(nowMs, _queue.last.due);
    var duration = max(4, _intervalMs ~/ 2);
    // A big frame (a keyframe) no faster than paceBps, within maxSpreadMs.
    if (paceBps > 0) {
      final bytes = packets.fold<int>(0, (n, p) => n + p.length);
      duration = max(duration, min(maxSpreadMs, bytes * 8000 ~/ paceBps));
    }
    _queue.add(_PacedFrame(packets, nowMs, start, start + duration));
    return true;
  }

  /// Sends what is due by [nowMs]. False if stale frames were dropped (the
  /// caller should ask for a keyframe).
  bool pump(int nowMs, bool Function(Uint8List) send) {
    if (_queue.isEmpty) return true;
    // Stuck, not just waiting its turn: frames behind a keyframe that is
    // still being spread out are not stale; one that could have gone out
    // for a while (the transport refusing it) is.
    final budget = max(stuckMs, _intervalMs * 4);
    final first = _queue.first;
    if (nowMs - first.start > budget + (first.due - first.start)) {
      dropped += _queue.length;
      _queue.clear();
      return false;
    }
    while (_queue.isNotEmpty) {
      final f = _queue.first;
      if (nowMs < f.start) break;
      final size = f.packets.length;
      final span = max(1, f.due - f.start);
      // How many should be out by now; the first few go at once.
      final target = min(size, max(min(4, size), (size * (nowMs - f.start) + span - 1) ~/ span));
      while (f.next < target) {
        if (!send(f.packets[f.next])) return true; // refused for now: retry next pump
        f.next++;
      }
      if (f.next < size) break;
      _queue.removeAt(0);
    }
    return true;
  }

  void clear() => _queue.clear();
}

class _PacedFrame {
  _PacedFrame(this.packets, this.enqueued, this.start, this.due);
  final List<Uint8List> packets;
  final int enqueued, start, due;
  int next = 0;
}
