import 'dart:async';

import 'beam_cancellation.dart';

enum BeamBufferWaitReason { slow, stalled, initialDeadline }

typedef BeamBufferWait = Future<bool> Function(BeamBufferWaitOffer offer);

class BeamBufferWaitOffer {
  const BeamBufferWaitOffer({
    required this.bufferSeconds,
    required this.targetBufferSeconds,
    required this.elapsed,
    required this.reason,
    required this.done,
    this.estimatedWait,
    this.selectedFilename,
  });

  /// Estimated time to the initial buffer target, not uninterrupted playback.
  final Duration? estimatedWait;
  final double bufferSeconds;
  final double targetBufferSeconds;
  final Duration elapsed;
  final BeamBufferWaitReason reason;
  final String? selectedFilename;

  /// This source became ready, failed, or was cancelled; its offer is obsolete.
  final Future<void> done;
}

/// Estimates readiness from recent contiguous-buffer growth. Advertised swarm
/// counts, download rates, and noncontiguous bytes cannot establish an ETA.
class BeamBufferEstimator {
  final _samples = <(Duration, double)>[];
  double _latest = 0;
  double get bufferSeconds => _latest;

  void add(Duration elapsed, double bufferSeconds) {
    if (!bufferSeconds.isFinite || bufferSeconds < 0) return;
    if (_samples.isNotEmpty && elapsed < _samples.last.$1) return;
    _latest = bufferSeconds;
    // A changed native estimate must establish a fresh slope.
    if (_samples.isNotEmpty && bufferSeconds < _samples.last.$2) _samples.clear();
    _samples.removeWhere((sample) => elapsed - sample.$1 > const Duration(seconds: 60));
    if (_samples.isEmpty || bufferSeconds > _samples.last.$2) _samples.add((elapsed, bufferSeconds));
  }

  Duration? remaining(Duration now, double targetSeconds) {
    if (_samples.length < 4 || !targetSeconds.isFinite || _latest >= targetSeconds) return null;
    final first = _samples.first;
    final last = _samples.last;
    final span = last.$1 - first.$1;
    if (span < const Duration(seconds: 10) || now < last.$1 || now - last.$1 > const Duration(seconds: 15)) {
      return null;
    }
    final growth = last.$2 - first.$2;
    if (growth <= 0) return null;
    final milliseconds = (targetSeconds - _latest) * span.inMilliseconds / growth;
    // Tiny/noisy slopes cannot establish a useful bounded prediction.
    if (!milliseconds.isFinite || milliseconds > const Duration(days: 1).inMilliseconds) return null;
    return milliseconds > 0 ? Duration(milliseconds: milliseconds.ceil()) : null;
  }
}

/// One source's consent and deadlines. Polling/readiness never awaits a dialog.
class BeamBufferWaitController {
  BeamBufferWaitController({
    required this.onWait,
    required this.cancellation,
    required this.targetBufferSeconds,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final BeamBufferWait onWait;
  final BeamCancellation cancellation;
  final double targetBufferSeconds;
  final DateTime Function() _now;
  final estimator = BeamBufferEstimator();
  final _done = Completer<void>();
  DateTime? _started;
  DateTime? _consentUntil;
  Future<bool>? _pending;
  String? selectedFilename;
  int continuationCount = 0;
  void Function()? onContinued;
  bool declined = false;
  bool get isPending => _pending != null;
  bool get isDisposed => _done.isCompleted;
  Duration get elapsed => _started == null ? Duration.zero : _now().difference(_started!);
  Duration get remainingConsent {
    final remaining = _consentUntil?.difference(_now()) ?? Duration.zero;
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  void start(String filename) {
    if (isDisposed || _started != null) return;
    selectedFilename = filename;
    _started = _now();
    estimator.add(Duration.zero, 0);
  }

  void observe(double bufferSeconds) {
    if (!isDisposed && _started != null) estimator.add(elapsed, bufferSeconds);
  }

  Future<bool> request(BeamBufferWaitReason reason) {
    if (isDisposed || cancellation.isCancelled || declined) return Future.value(false);
    if (_pending != null) return _pending!;
    final result = Completer<bool>();
    _pending = result.future;
    final offer = BeamBufferWaitOffer(
      bufferSeconds: estimator.bufferSeconds,
      targetBufferSeconds: targetBufferSeconds,
      elapsed: elapsed,
      reason: reason,
      estimatedWait: estimator.remaining(elapsed, targetBufferSeconds),
      selectedFilename: selectedFilename,
      done: _done.future,
    );
    unawaited(() async {
      var accepted = false;
      try {
        accepted = await Future.any([
          Future<bool>.sync(() => onWait(offer)),
          cancellation.whenCancelled.then((_) => false),
          _done.future.then((_) => false),
        ]);
      } catch (_) {
        accepted = false;
      }
      if (!isDisposed && !cancellation.isCancelled) {
        if (accepted) {
          const minimum = Duration(minutes: 2);
          final estimate = offer.estimatedWait;
          final measured = estimate == null ? minimum : estimate + const Duration(seconds: 30);
          _consentUntil = _now().add(measured > minimum ? measured : minimum);
          continuationCount++;
          onContinued?.call();
        } else {
          declined = true;
        }
      }
      _pending = null;
      result.complete(accepted);
    }());
    return result.future;
  }

  void dispose() {
    if (!isDisposed) _done.complete();
  }
}
