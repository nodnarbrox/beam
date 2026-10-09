import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/beam/beam_buffer_wait.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';

void main() {
  test('measured buffer growth yields80seconds; sparse or stale evidence gives no ETA', () {
    final estimate = BeamBufferEstimator();
    estimate.add(Duration.zero, 0);
    estimate.add(const Duration(seconds: 5), 1);
    estimate.add(const Duration(seconds: 10), 2);
    expect(estimate.remaining(const Duration(seconds: 10), 20), isNull);
    estimate.add(const Duration(seconds: 20), 4);
    expect(estimate.remaining(const Duration(seconds: 20), 20), const Duration(seconds: 80));
    expect(estimate.remaining(const Duration(seconds: 36), 20), isNull);
    estimate.add(const Duration(seconds: 37), 3); // Corrected native estimate.
    expect(estimate.remaining(const Duration(seconds: 37), 20), isNull);
  });

  test('no advancement, invalid telemetry and short bursts cannot invent an ETA', () {
    final estimate = BeamBufferEstimator();
    for (var n = 0; n < 60; n++) {
      estimate.add(Duration(seconds: n), 0);
    }
    expect(estimate.remaining(const Duration(seconds: 60), 20), isNull);
    estimate.add(const Duration(seconds: 60), double.nan);
    estimate.add(const Duration(seconds: 60), double.infinity);
    estimate.add(const Duration(seconds: 60), -1);
    expect(estimate.bufferSeconds, 0);
    for (var n = 1; n <= 4; n++) {
      estimate.add(Duration(seconds: 60, milliseconds: n), n.toDouble());
    }
    expect(estimate.remaining(const Duration(seconds: 60, milliseconds: 4), 20), isNull);
    final noise = BeamBufferEstimator();
    for (var n = 0; n <= 3; n++) {
      noise.add(Duration(seconds: n * 10), n * 1e-300);
    }
    expect(noise.remaining(const Duration(seconds: 30), 20), isNull);
  });

  test('one consent coalesces deadlines; disposed late answers never extend preparation', () async {
    final answer = Completer<bool>();
    final cancellation = BeamCancellation();
    var calls = 0;
    var continued = 0;
    late BeamBufferWaitOffer offer;
    final controller = BeamBufferWaitController(
      onWait: (value) {
        calls++;
        offer = value;
        return answer.future;
      },
      cancellation: cancellation,
      targetBufferSeconds: 20,
    )..start('Pioneer.One.S01E02.mp4');
    controller.onContinued = () => continued++;
    final first = controller.request(BeamBufferWaitReason.slow);
    expect(controller.request(BeamBufferWaitReason.initialDeadline), same(first));
    expect(calls, 1);
    answer.complete(true);
    expect(await first, isTrue);
    expect(controller.continuationCount, 1);
    expect(continued, 1);
    controller.dispose();
    await offer.done;
    expect(await controller.request(BeamBufferWaitReason.stalled), isFalse);
  });

  test('cancellation interrupts a UI future that never answers', () async {
    final cancellation = BeamCancellation();
    final answer = Completer<bool>();
    final controller = BeamBufferWaitController(
      onWait: (_) => answer.future,
      cancellation: cancellation,
      targetBufferSeconds: 20,
    )..start('fixture');
    final pending = controller.request(BeamBufferWaitReason.slow);
    cancellation.cancel();
    expect(await pending, isFalse);
    answer.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(controller.continuationCount, 0);
    controller.dispose();
  });
}
