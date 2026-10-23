// The streaming feedback loop's arithmetic (docs/protocol.md 7.2), kept apart
// from the sessions so it can be tested: the sender's bitrate control, and the
// viewer's measure of how delay varies.

import 'dart:math';

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
