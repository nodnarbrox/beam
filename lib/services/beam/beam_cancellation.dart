import 'dart:async';

class BeamCancelled implements Exception {
  const BeamCancelled();
  @override
  String toString() => 'Beam playback cancelled';
}

/// Owned by one attempt; a late completion cannot cancel a newer attempt.
class BeamCancellation {
  final _signal = Completer<void>();
  Future<void> get whenCancelled => _signal.future;
  bool get isCancelled => _signal.isCompleted;
  void cancel() {
    if (!isCancelled) _signal.complete();
  }

  void check() {
    if (isCancelled) throw const BeamCancelled();
  }

  Future<T> bind<T>(Future<T> operation) =>
      Future.any([operation, _signal.future.then<T>((_) => throw const BeamCancelled())]);
}
