// The streaming feedback loop: the sender's bitrate control and the
// viewer's delay measure (lib/core/screen/stream_control.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/core/screen/stream_control.dart';

void main() {
  test('clean reports raise the bitrate to its cap', () {
    final rate = BitrateControl(bitrate: 8000000, cap: 16000000);
    for (var i = 0; i < 20; i++) {
      rate.report(received: 60, lost: 0);
    }
    expect(rate.bitrate, 16000000);
    expect(rate.report(received: 60, lost: 0), isNull); // at the cap: no change
  });

  test('loss or rising delay eases it off, once per bad patch', () {
    final rate = BitrateControl(bitrate: 10000000, cap: 16000000);
    expect(rate.report(received: 90, lost: 10), 8000000);
    expect(rate.report(received: 90, lost: 10), isNull); // same patch: no second cut
    for (var i = 0; i < 3; i++) {
      rate.report(received: 90, lost: 10);
    }
    expect(rate.bitrate, 6400000); // a later patch cuts again
    final delayed = BitrateControl(bitrate: 10000000, cap: 16000000);
    expect(delayed.report(received: 60, lost: 0, trendMs: 25), 8000000);
  });

  test('never below the floor, and a report of nothing changes nothing', () {
    final rate = BitrateControl(bitrate: 320000, cap: 16000000);
    expect(rate.report(received: 10, lost: 10), BitrateControl.minBitrate);
    expect(rate.report(received: 0, lost: 0), isNull);
  });

  test('delay meter: steady transit has no jitter or trend, a growing queue a trend', () {
    final steady = DelayMeter();
    for (var i = 0; i < 50; i++) {
      steady.frame(1000 + i * 16, 5000 + i * 16); // transit 4000, constant
    }
    expect(steady.jitterMs, 0);
    expect(steady.trendMs, 0);

    final queueing = DelayMeter();
    for (var i = 0; i < 50; i++) {
      queueing.frame(1000 + i * 16, 5000 + i * 20); // 4 ms more each frame
    }
    expect(queueing.trendMs, closeTo(4, 0.1));
    expect(queueing.jitterMs, closeTo(4, 0.2));
  });

  test('delay meter copes with the 32-bit capture clock wrapping', () {
    final meter = DelayMeter();
    meter.frame(0xFFFFFFF0, 100);
    meter.frame(0x00000000, 116); // wrapped; transit unchanged
    expect(meter.trendMs, 0);
  });
}
