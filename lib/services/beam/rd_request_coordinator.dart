import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:http/http.dart' as http;

import 'beam_cancellation.dart';

/// Process-wide RD request starts, not a credential or response cache.
/// RD documents 250 requests/minute, including refused requests. One per second
/// leaves headroom for another TV and applies equally to polling and mutations.
class RdRequestCoordinator {
  RdRequestCoordinator({
    this.minSpacing = const Duration(seconds: 1),
    this.minimumCooldown = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static final shared = RdRequestCoordinator();
  final Duration minSpacing;
  final Duration minimumCooldown;
  final DateTime Function() _now;
  final _queue = Queue<_Request>();
  DateTime? _nextStart;
  DateTime? _cooldownUntil;
  Timer? _timer;

  static bool isThrottled(http.Response response) {
    if (response.statusCode == 429) return true;
    try {
      final body = jsonDecode(response.body);
      final code = body is Map ? int.tryParse('${body['error_code']}') : null;
      return code == 5 || code == 34;
    } catch (_) {
      return false;
    }
  }

  Future<http.Response> request(
    Future<http.Response> Function() dispatch, {
    required BeamCancellation cancellation,
    void Function(String)? onWait,
  }) {
    cancellation.check();
    final request = _Request(dispatch, cancellation, onWait);
    _queue.add(request);
    unawaited(
      cancellation.whenCancelled.then((_) {
        if (request.result.isCompleted || request.started) return;
        _queue.remove(request);
        request.result.completeError(const BeamCancelled());
        _schedule();
      }),
    );
    _reportWait(request);
    _schedule();
    return request.result.future;
  }

  void _reportWait(_Request request) {
    final cooldown = _cooldownUntil?.difference(_now()) ?? Duration.zero;
    final wait = _nextStart?.difference(_now()) ?? Duration.zero;
    if (cooldown <= Duration.zero && wait <= Duration.zero && _queue.firstOrNull == request) return;
    request.onWait?.call(
      cooldown > Duration.zero
          ? 'Rate limited: waiting ${(cooldown.inMilliseconds + 999) ~/ 1000}s'
          : 'Waiting for request slot',
    );
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    while (_queue.isNotEmpty && _queue.first.cancellation.isCancelled) {
      final cancelled = _queue.removeFirst();
      if (!cancelled.result.isCompleted) cancelled.result.completeError(const BeamCancelled());
    }
    if (_queue.isEmpty) return;
    final now = _now();
    var start = _nextStart ?? now;
    if (_cooldownUntil != null && _cooldownUntil!.isAfter(start)) start = _cooldownUntil!;
    final wait = start.difference(now);
    if (wait > Duration.zero) {
      _timer = Timer(wait, _schedule);
      return;
    }
    final request = _queue.removeFirst();
    request.started = true;
    _nextStart = now.add(minSpacing);
    unawaited(
      Future<http.Response>.sync(request.dispatch).then<void>(
        (response) {
          if (isThrottled(response)) {
            var delay = minimumCooldown;
            final header = response.headers['retry-after'];
            final seconds = int.tryParse(header ?? '');
            if (seconds != null && seconds > 0) {
              final retry = Duration(seconds: seconds);
              if (retry > delay) delay = retry;
            } else if (header != null) {
              try {
                final retry = HttpDate.parse(header).difference(_now());
                if (retry > delay) delay = retry;
              } catch (_) {}
            }
            final until = _now().add(delay);
            if (_cooldownUntil == null || until.isAfter(_cooldownUntil!)) _cooldownUntil = until;
            for (final queued in _queue) {
              _reportWait(queued);
            }
            _schedule();
          }
          request.result.complete(response);
        },
        onError: (Object error, StackTrace stack) {
          request.result.completeError(error, stack);
        },
      ),
    );
    // Space starts without serializing network response latency.
    if (_queue.isNotEmpty) {
      _timer = Timer(minSpacing, _schedule);
    }
  }
}

class _Request {
  _Request(this.dispatch, this.cancellation, this.onWait);
  final Future<http.Response> Function() dispatch;
  final BeamCancellation cancellation;
  final void Function(String)? onWait;
  final result = Completer<http.Response>();
  bool started = false;
}
