// How much the path carries, estimated the way real-time services do
// (Google congestion control): from the receiver's report of when each
// packet arrived, a queue building on the path shows as arrivals spreading
// out compared with departures, before anything is lost. That trend lowers
// the rate; its absence raises it, quickly while far from what the path has
// taken before and gently near it. Loss with delay behind it lowers it too.
// The same algorithm as the desktop's Bandwidth.cpp.

import 'dart:math';

class PacketResult {
  PacketResult({required this.sendMs, required this.arrivalMs, required this.bytes, required this.received});
  final int sendMs;
  final double arrivalMs; // the receiver's clock; only differences are used
  final int bytes;
  final bool received;
}

enum _Signal { normal, overuse, underuse }

class BandwidthEstimator {
  BandwidthEstimator({int startBps = 1500000, this.minBps = 150000, this.maxBps = 100000000}) {
    _target = startBps.clamp(minBps, maxBps);
  }

  static const double overuseThresholdMs = 12.5;
  static const int _trendWindow = 20;
  static const double _trendGain = 4.0;
  static const double _overuseHoldMs = 10;
  static const double _receiveWindowMs = 500;
  static const double _maxTargetOverReceived = 1.5;

  final int minBps, maxBps;
  int _target = 0, receiveBps = 0, sendBps = 0, _lastDecreaseBps = 0;
  double lossRate = 0, trendMs = 0, _threshold = overuseThresholdMs, _minRttMs = 0;

  /// The worst recent spell of loss, fading over a couple of seconds: a
  /// mobile uplink loses in spells, and repair is sized for those.
  double burstLossRate = 0;
  String state = 'increase';
  int _lastUpdateMs = 0, _overusingSinceMs = -1, _lastLossCutMs = -1000000;
  double _previousTrend = 0;
  double _accumulatedDelayMs = 0, _smoothedDelayMs = 0;
  final _samples = <List<double>>[]; // [arrival time, smoothed delay]
  int _deltas = 0;
  double _firstArrivalMs = 0;
  bool _haveSample = false;
  int _previousSendMs = 0;
  double _previousArrivalMs = 0;
  final _received = <List<num>>[]; // [arrival, bytes]
  double _lastArrivalMs = 0;
  final _sent = <List<int>>[]; // [send time, bytes]
  int _lastSendMs = 0;

  int get targetBps => _target;

  /// The path has pushed back at least once: the target reflects its limit,
  /// not just how far the ramp has got.
  bool get limited => _lastDecreaseBps > 0;

  /// Sending well under the target: the source needs no more, and the
  /// target says nothing about the path.
  bool get applicationLimited => sendBps < 0.7 * _target;

  /// The path has shown it carries no more than [bps] (a reliable path's
  /// queue filling): the target comes down to it.
  void limitTo(int bps) {
    final target = bps.clamp(minBps, maxBps);
    if (target >= _target) return;
    _target = target;
    _lastDecreaseBps = target;
    state = 'decrease';
  }

  _Signal _detect(double trend, double dtMs) {
    final k = trend.abs() < _threshold ? 0.039 : 0.0087;
    _threshold = (_threshold + k * (trend.abs() - _threshold) * dtMs.clamp(0, 100)).clamp(6, 600);
    return trend > _threshold ? _Signal.overuse : trend < -_threshold ? _Signal.underuse : _Signal.normal;
  }

  /// [results] in send order; [rttMs] the current round trip, if known.
  void onFeedback(List<PacketResult> results, int nowMs, double rttMs) {
    var lost = 0, got = 0;
    for (final r in results) {
      _sent.add([r.sendMs, r.bytes]);
      if (r.sendMs > _lastSendMs) _lastSendMs = r.sendMs;
      if (!r.received) {
        lost++;
        continue;
      }
      got++;
      _received.add([r.arrivalMs, r.bytes]);
      if (r.arrivalMs > _lastArrivalMs) _lastArrivalMs = r.arrivalMs;
      if (!_haveSample) {
        _haveSample = true;
        _firstArrivalMs = r.arrivalMs;
        _previousSendMs = r.sendMs;
        _previousArrivalMs = r.arrivalMs;
        continue;
      }
      // Arrivals spreading out more than departures: delay is building.
      final delta = (r.arrivalMs - _previousArrivalMs) - (r.sendMs - _previousSendMs);
      _previousSendMs = r.sendMs;
      _previousArrivalMs = r.arrivalMs;
      _accumulatedDelayMs += delta;
      _smoothedDelayMs = 0.9 * _smoothedDelayMs + 0.1 * _accumulatedDelayMs;
      _samples.add([r.arrivalMs - _firstArrivalMs, _smoothedDelayMs]);
      while (_samples.length > _trendWindow) {
        _samples.removeAt(0);
      }
      _deltas = min(_deltas + 1, 60);
    }
    if (got + lost > 0) lossRate = 0.8 * lossRate + 0.2 * lost / (got + lost);
    // The receive rate over the last half second of arrivals.
    while (_received.isNotEmpty && _received.first[0] < _lastArrivalMs - _receiveWindowMs) {
      _received.removeAt(0);
    }
    if (_received.length >= 2) {
      var total = 0;
      for (final r in _received) {
        total += r[1] as int;
      }
      final span = max(50.0, _lastArrivalMs - (_received.first[0] as double));
      receiveBps = (total * 8000 / span).toInt();
    }
    // Trend line through the recent samples: its slope is the signal.
    var slope = 0.0;
    if (_samples.length >= 2) {
      var sumX = 0.0, sumY = 0.0;
      for (final s in _samples) {
        sumX += s[0];
        sumY += s[1];
      }
      final meanX = sumX / _samples.length, meanY = sumY / _samples.length;
      var num = 0.0, den = 0.0;
      for (final s in _samples) {
        num += (s[0] - meanX) * (s[1] - meanY);
        den += (s[0] - meanX) * (s[0] - meanX);
      }
      if (den > 0) slope = num / den;
    }
    // Weighted by how much has been seen (up to 60 deltas): a few samples say little.
    trendMs = _deltas * slope * _trendGain;
    final dt = _lastUpdateMs != 0 ? (nowMs - _lastUpdateMs).toDouble() : 100.0;
    _lastUpdateMs = nowMs;
    // The worst recent spell, halving every half second; a handful of
    // packets is too few to call a spell.
    burstLossRate *= pow(0.5, dt / 500);
    if (got + lost >= 10) burstLossRate = max(burstLossRate, lost / (got + lost));
    var signal = _detect(trendMs, dt);
    if (signal == _Signal.overuse) {
      if (_overusingSinceMs < 0) _overusingSinceMs = nowMs;
      if (nowMs - _overusingSinceMs < _overuseHoldMs || trendMs < _previousTrend) signal = _Signal.normal; // not yet: a blip
    } else {
      _overusingSinceMs = -1;
    }
    _previousTrend = trendMs;

    final seconds = dt.clamp(1, 1000) / 1000;
    // Sending well under the target (a still screen): the path is not being
    // tested, so neither the receive rate nor the lack of trouble says
    // anything about it; the target holds.
    while (_sent.isNotEmpty && _sent.first[0] < _lastSendMs - _receiveWindowMs) {
      _sent.removeAt(0);
    }
    if (_sent.length >= 2) {
      var total = 0;
      for (final s in _sent) {
        total += s[1];
      }
      sendBps = (total * 8000 / max(50, _lastSendMs - _sent.first[0])).toInt();
    }
    final limitedByApp = sendBps < 0.7 * _target;
    var target = _target;
    if (signal == _Signal.overuse) {
      state = 'decrease';
      target = (0.85 * max(receiveBps, minBps)).toInt();
      if (target < _target) _lastDecreaseBps = target;
      target = min(target, _target);
    } else if (signal == _Signal.underuse || limitedByApp) {
      state = 'hold';
    } else {
      state = 'increase';
      // Once the path has shown where it gives way, growth is gentle around
      // there (a packet per round trip); far from it, or before any cut, it
      // is quick.
      final nearLastCut = _lastDecreaseBps > 0 && receiveBps < 2 * _lastDecreaseBps && receiveBps > _lastDecreaseBps / 2;
      if (nearLastCut) {
        final rtt = (rttMs > 0 ? rttMs : 100).clamp(10, 1000);
        target += (1200 * 8 * 1000 / rtt * seconds).toInt();
      } else {
        target = (target * pow(1.08, seconds * 10)).toInt(); // 8% per 100 ms while probing upwards
      }
    }
    // Loss: more than a tenth lost while the path is being used, with delay
    // building or the round trip up (a queue filling and spilling), cuts the
    // rate, at most once per few round trips. Loss with no delay behind it is
    // the path losing at random (a mobile uplink): no rate helps that, repair
    // packets and repeats carry the stream across it.
    if (rttMs > 0) _minRttMs = _minRttMs > 0 ? min(_minRttMs, rttMs) : rttMs;
    // A cellular link's round trip wanders by tens of milliseconds and its
    // delay trend is seldom exactly flat: only a clear rise counts.
    final queueing = trendMs > _threshold / 2 || (_minRttMs > 0 && rttMs > 1.5 * _minRttMs + 30);
    if (lossRate > 0.10 && !limitedByApp && queueing && receiveBps > 0 && nowMs - _lastLossCutMs >= max(300, 3 * rttMs)) {
      target = min(target, (_target * (1 - 0.5 * min(lossRate, 0.5))).toInt());
      _lastLossCutMs = nowMs;
      state = 'decrease';
      _lastDecreaseBps = target;
    }
    // Never far beyond what the path has been seen to carry, once it was asked to.
    if (receiveBps > 0 && !limitedByApp) target = min(target, (_maxTargetOverReceived * receiveBps).toInt() + minBps);
    _target = target.clamp(minBps, maxBps);
  }
}
