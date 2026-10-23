// The media layer (screen/camera 2.0) on a simulated path: packets, repair,
// feedback, the bandwidth estimate and pacing, with loss, delay and a
// bottleneck between a sender and a receiver run in lockstep. The same
// scenarios as the desktop's MediaTransportTest.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/core/screen/media_packet.dart';
import 'package:uconnect_mobile/core/screen/media_receiver.dart';
import 'package:uconnect_mobile/core/screen/media_sender.dart';

/// A one-way path: random loss, a fixed delay, and a bottleneck with a
/// queue of bounded depth (a full one drops what arrives).
class Link {
  Link({this.loss = 0, this.delayMs = 20, this.bottleneckBps = 0, this.queueMs = 300, this.reliable = false});
  final double loss;
  final int delayMs, bottleneckBps, queueMs;
  final bool reliable; // TCP-like: never drops, only waits (a deep queue)
  final rng = Random(42);
  double busyUntil = 0;
  final inFlight = <List<Object>>[]; // [deliverAt, packet]
  int sent = 0, dropped = 0;

  bool send(Uint8List packet, double nowMs) {
    sent++;
    var at = nowMs;
    if (bottleneckBps > 0) {
      final serve = packet.length * 8000 / bottleneckBps;
      final start = max(nowMs, busyUntil);
      if (start - nowMs > queueMs) {
        if (reliable) return false;
        dropped++;
        return true;
      }
      busyUntil = start + serve;
      at = busyUntil;
    }
    if (!reliable && rng.nextDouble() < loss) {
      dropped++;
      return true;
    }
    inFlight.add([at + delayMs, packet]);
    return true;
  }

  List<Uint8List> due(double nowMs) {
    final out = <Uint8List>[];
    inFlight.sort((a, b) => (a[0] as double).compareTo(b[0] as double));
    while (inFlight.isNotEmpty && (inFlight.first[0] as double) <= nowMs) {
      out.add(inFlight.removeAt(0)[1] as Uint8List);
    }
    return out;
  }
}

class Run {
  Run({this.fps = 30, this.seconds = 10, Link? forward, Link? back, this.startBps = 1500000, this.reliable = false})
      : forward = forward ?? Link(),
        back = back ?? Link();
  final int fps, seconds, startBps;
  final bool reliable;
  final Link forward, back;
  int framesSent = 0, framesDelivered = 0, skipped = 0, keyframes = 0;
  final lagMs = <double>[];
  final targets = <int>[];
  final perSecond = <String>[];
  late ReceiverStats stats;

  void go() {
    final sender = MediaSender(kind: 1, session: 7, startBps: startBps, reliable: reliable, fps: fps);
    final receiver = MediaReceiver(session: 7, kind: 1, fps: fps);
    final interval = 1000 / fps;
    var nextFrame = 0.0, number = 0;
    for (var now = 0; now < seconds * 1000; now++) {
      if (now >= nextFrame) {
        nextFrame += interval;
        if (!sender.shouldSkipCapture()) {
          final key = number == 0 || sender.takeKeyframeWanted(now);
          if (key) keyframes++;
          final bytes = max(200, sender.encoderBps ~/ 8 ~/ fps * (key ? 6 : 1));
          final frame = EncodedFrame(7, number, now, key, Uint8List(bytes)..fillRange(0, bytes, number & 0xFF));
          if (sender.enqueue(frame)) framesSent++;
          number++;
        } else {
          skipped++;
        }
      }
      sender.pump(now, (packet) => forward.send(packet, now.toDouble()));
      for (final packet in forward.due(now.toDouble())) {
        for (final frame in receiver.receive(packet, now)) {
          framesDelivered++;
          lagMs.add((now - frame.captureMs).toDouble());
        }
      }
      receiver.expire(now);
      if (receiver.feedbackDue(now)) back.send(receiver.takeFeedback(now, 0, 2), now.toDouble());
      for (final packet in back.due(now.toDouble())) {
        sender.onFeedback(packet, now);
      }
      if (now % 1000 == 999) {
        targets.add(sender.targetBps);
        perSecond.add('[recv ${sender.receiveBps ~/ 1000} send ${sender.sendBps ~/ 1000} loss ${(sender.lossRate * 100).round()}% '
            '${sender.estimatorState} rtt ${sender.rttMs.round()} q ${sender.queuedBytes} lag ${sender.lagMs.round()} drop ${sender.dropped}]');
      }
    }
    stats = receiver.report();
  }

  double lagPercentile(double p, [int fromSecond = 0]) {
    final v = <double>[];
    for (var i = 0; i < lagMs.length; i++) {
      if (i >= fromSecond * fps) v.add(lagMs[i]);
    }
    if (v.isEmpty) return 0;
    v.sort();
    return v[min(v.length - 1, (v.length * p).toInt())];
  }

  String get text => '${targets.map((t) => t ~/ 1000).join(' ')} kbit/s; frames $framesDelivered of $framesSent (skipped $skipped, '
      'keys $keyframes, late ${stats.late}, discarded ${stats.discarded}), given up ${stats.givenUp}, '
      'lag p50 ${lagPercentile(.5)} p95 ${lagPercentile(.95)} ms | ${perSecond.join(' ')}';
}

void main() {
  test('packets round trip', () {
    final frame = EncodedFrame(7, 42, 123456, true, Uint8List(3000)..fillRange(0, 3000, 120));
    final seq = SeqCounter()..next = 100;
    final packets = packetize(1, frame, seq, 2);
    expect(packets.length, 3 + 2); // 3 fragments, a repair after each 2
    expect(seq.next, 105);
    for (final p in packets) {
      final bytes = encodeMedia(p);
      expect(bytes.length <= maxDatagram, isTrue);
      final back = decodeMedia(bytes)!;
      expect(back.seq, p.seq);
      expect(back.frame, 42);
      expect(back.captureMs, 123456);
      expect(back.type, p.type);
      expect(back.payload, p.payload);
      expect(back.keyframe, isTrue);
    }
    final f = Feedback()
      ..session = 7
      ..baseSeq = 100
      ..refTimeMs = 5000
      ..heldMs = 3
      ..latestFrame = 41
      ..latestCaptureMs = 120000
      ..haveLatest = true
      ..keyframeWanted = true
      ..arrivals = [4, Feedback.missing, 12]
      ..nacks = [90, 91];
    final decoded = Feedback.decode(f.encode(1))!;
    expect(decoded.arrivals, f.arrivals);
    expect(decoded.nacks, f.nacks);
    expect(decoded.keyframeWanted, isTrue);
    expect(decoded.latestCaptureMs, 120000);
    expect(decoded.heldMs, 3);
    expect(decodeMedia(Uint8List(5)), isNull);
    expect(Feedback.decode(Uint8List(10)), isNull);
  });

  test('repair rebuilds one lost fragment per group', () {
    final bytes = Uint8List(5000);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (i * 7) & 0xFF;
    }
    final frame = EncodedFrame(7, 1, 1000, true, bytes);
    final packets = packetize(1, frame, SeqCounter(), 2); // 5 fragments: groups of 2, 2, 1
    final receiver = MediaReceiver(session: 7, kind: 1);
    final out = <EncodedFrame>[];
    for (final p in packets) {
      if (p.type == PacketType.media && (p.frag == 0 || p.frag == 3 || p.frag == 4)) continue; // one lost per group
      out.addAll(receiver.receive(encodeMedia(p), 10));
    }
    expect(out.length, 1);
    expect(out[0].bytes, bytes);
    expect(receiver.report().recovered, 3);
  });

  test('repeats fill what was lost', () {
    final sender = MediaSender(kind: 1, session: 7, startBps: 2000000);
    final receiver = MediaReceiver(session: 7, kind: 1);
    final frame = EncodedFrame(7, 0, 100, true, Uint8List(16 * mediaPayload));
    expect(sender.enqueue(frame), isTrue);
    final out = <EncodedFrame>[];
    for (var now = 100; now < 400 && out.isEmpty; now++) {
      sender.pump(now, (bytes) {
        final p = decodeMedia(bytes);
        if (p != null && !p.retransmit && (p.frag == 3 || p.frag == 7)) return true; // lost on the way
        out.addAll(receiver.receive(bytes, now + 5));
        return true;
      });
      receiver.expire(now);
      if (receiver.feedbackDue(now)) sender.onFeedback(receiver.takeFeedback(now, 0, 1), now + 5);
    }
    expect(out.length, 1);
    expect(out[0].bytes, frame.bytes);
    expect(sender.retransmitted, 2);
    expect(receiver.report().repaired, 2);
  });

  test('a clean path delivers everything with low lag', () {
    final run = Run(seconds: 6, startBps: 4000000)..go();
    printOnFailure(run.text);
    expect(run.framesDelivered >= run.framesSent - 2, isTrue, reason: run.text);
    expect(run.lagPercentile(.95) < 80, isTrue, reason: run.text);
    expect(run.targets.last > 4000000, isTrue, reason: run.text);
  });

  test('loss is repaired and repeated', () {
    final run = Run(seconds: 10, startBps: 2000000, forward: Link(loss: 0.25))..go();
    printOnFailure(run.text);
    expect(run.framesDelivered > run.framesSent * 0.85, isTrue, reason: run.text);
    expect(run.stats.recovered > 0 || run.stats.repaired > 0, isTrue);
    expect(run.lagPercentile(.95, 2) < 250, isTrue, reason: run.text);
  });

  test('a bottleneck is found and the lag stays bounded', () {
    final run = Run(seconds: 12, startBps: 4000000, forward: Link(bottleneckBps: 1500000, queueMs: 400))..go();
    printOnFailure(run.text);
    final target = run.targets.last;
    expect(target < 1650000 && target > 700000, isTrue, reason: run.text);
    expect(run.lagPercentile(.95, 4) < 400, isTrue, reason: run.text);
    expect(run.framesDelivered > run.framesSent * 0.7, isTrue, reason: run.text);
  });

  test('a reliable path stays bounded by what is in flight', () {
    final run = Run(seconds: 12, startBps: 4000000, reliable: true, forward: Link(reliable: true, bottleneckBps: 800000, queueMs: 5000))..go();
    printOnFailure(run.text);
    expect(run.lagPercentile(.95, 4) < 700, isTrue, reason: run.text);
    expect(run.targets.last < 1000000, isTrue, reason: run.text);
  });
}
