import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/rd_request_coordinator.dart';
import 'package:plezy/services/beam/realdebrid_client.dart';

final _epoch = DateTime.utc(2026, 9, 26);
http.Response _json(Object data, [int status = 200, Map<String, String>? headers]) =>
    http.Response(jsonEncode(data), status, headers: headers ?? {});
void _observe<T>(Future<T> operation, void Function(Object) error) {
  unawaited(operation.then<void>((_) {}, onError: (Object value) => error(value)));
}

void main() {
  test('independent clients share one start per second across all seven endpoints', () {
    fakeAsync((clock) {
      final coordinator = RdRequestCoordinator(now: () => _epoch.add(clock.elapsed));
      final starts = <Duration>[];
      final methods = <String>[];
      RealDebridClient client() => RealDebridClient(
        coordinator: coordinator,
        tokenProvider: () async => 'fixture',
        httpClient: MockClient((request) async {
          starts.add(clock.elapsed);
          methods.add(request.method);
          if (request.url.path.endsWith('/torrents')) return _json([]);
          return _json({'id': 'new', 'filename': 'movie.mp4', 'download': 'https://fixture/video'});
        }),
      );
      final a = client(), b = client();
      final operations = [
        a.user(),
        b.listTorrents(),
        a.info('old'),
        b.addMagnet('magnet:fixture'),
        a.selectFiles('new'),
        b.unrestrict('fixture-link'),
        a.deleteTorrent('new'),
      ];
      for (final operation in operations) {
        _observe(operation, (error) => fail('$error'));
      }
      clock.flushMicrotasks();
      expect(starts, [Duration.zero]);
      clock.elapse(const Duration(seconds: 6));
      expect(starts, [for (var second = 0; second < 7; second++) Duration(seconds: second)]);
      expect(methods, ['GET', 'GET', 'GET', 'POST', 'POST', 'POST', 'DELETE']);
      a.close();
      b.close();
      clock.flushMicrotasks();
    });
  });

  for (final example in [
    (429, <String, Object>{}, <String, String>{}, 60),
    (429, <String, Object>{}, {'retry-after': '10'}, 60),
    (429, <String, Object>{}, {'retry-after': '120'}, 120),
    (429, <String, Object>{}, {'retry-after': HttpDate.format(_epoch.add(const Duration(seconds: 90)))}, 90),
    (429, <String, Object>{}, {'retry-after': 'invalid'}, 60),
    (400, <String, Object>{'error_code': 5}, <String, String>{}, 60),
    (403, <String, Object>{'error_code': 34}, <String, String>{}, 60),
  ]) {
    test('throttle ${example.$1}/${example.$2} honors ${example.$4}s cooldown and never replays POST', () {
      fakeAsync((clock) {
        final coordinator = RdRequestCoordinator(now: () => _epoch.add(clock.elapsed));
        final paths = <String>[];
        final waits = <String>[];
        Object? error;
        RealDebridClient client() => RealDebridClient(
          coordinator: coordinator,
          tokenProvider: () async => 'fixture',
          onRequestWait: waits.add,
          httpClient: MockClient((request) async {
            paths.add(request.url.path);
            return request.method == 'POST' ? _json(example.$2, example.$1, example.$3) : _json([]);
          }),
        );
        final first = client(), other = client();
        _observe(first.addMagnet('magnet:fixture'), (value) => error = value);
        _observe(other.listTorrents(), (value) => fail('$value'));
        clock.flushMicrotasks();
        expect(error, isA<RdException>().having((e) => e.code, 'normalized throttle', 429));
        expect(waits.any((note) => note.startsWith('Rate limited: waiting')), isTrue);
        clock.elapse(Duration(seconds: example.$4 - 1));
        expect(paths, hasLength(1));
        clock.elapse(const Duration(seconds: 1));
        expect(paths, hasLength(2));
        expect(paths.where((path) => path.endsWith('/addMagnet')), hasLength(1));
        first.close();
        other.close();
        clock.flushMicrotasks();
      });
    });
  }

  for (final mode in ['constructor', 'resolution', 'close']) {
    test('$mode cancellation prevents queued mutation and allows next live owner through', () {
      fakeAsync((clock) {
        final coordinator = RdRequestCoordinator(now: () => _epoch.add(clock.elapsed));
        final token = BeamCancellation();
        final paths = <String>[];
        Object? error;
        RealDebridClient client({BeamCancellation? cancellation}) => RealDebridClient(
          coordinator: coordinator,
          cancellation: cancellation,
          tokenProvider: () async => 'fixture',
          httpClient: MockClient((request) async {
            paths.add(request.url.path);
            return _json({});
          }),
        );
        final warm = client();
        _observe(warm.user(), (value) => fail('$value'));
        clock.flushMicrotasks();
        final cancelled = client(cancellation: mode == 'constructor' ? token : null);
        _observe(
          cancelled.resolveMagnet('magnet:fixture', cancellation: mode == 'resolution' ? token : null),
          (value) => error = value,
        );
        _observe(warm.user(), (value) => fail('$value'));
        clock.flushMicrotasks();
        if (mode == 'close') {
          cancelled.close();
        } else {
          token.cancel();
        }
        clock.flushMicrotasks();
        expect(error, isA<BeamCancelled>());
        clock.elapse(const Duration(seconds: 70));
        expect(paths, ['/rest/1.0/user', '/rest/1.0/user']);
        warm.close();
        cancelled.close();
        clock.flushMicrotasks();
      });
    });
  }

  test('HTTP timeout starts at dispatch, not while waiting for a pacing slot', () {
    fakeAsync((clock) {
      final coordinator = RdRequestCoordinator(
        minSpacing: const Duration(seconds: 20),
        now: () => _epoch.add(clock.elapsed),
      );
      final held = Completer<http.Response>();
      final starts = <Duration>[];
      Object? error;
      final client = RealDebridClient(
        coordinator: coordinator,
        tokenProvider: () async => 'fixture',
        httpClient: MockClient((request) {
          starts.add(clock.elapsed);
          return starts.length == 1 ? Future.value(_json({})) : held.future;
        }),
      );
      _observe(client.user(), (value) => fail('$value'));
      _observe(client.info('waiting'), (value) => error = value);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 30));
      expect(starts, [Duration.zero, const Duration(seconds: 20)]);
      expect(error, isNull);
      clock.elapse(const Duration(seconds: 5));
      expect(error, isA<TimeoutException>());
      held.complete(_json({}));
      client.close();
      clock.flushMicrotasks();
    });
  });

  test('poll budget expiry removes queued info even while standalone client stays open', () {
    fakeAsync((clock) {
      final coordinator = RdRequestCoordinator(
        minSpacing: const Duration(seconds: 20),
        now: () => _epoch.add(clock.elapsed),
      );
      final paths = <String>[];
      Object? error;
      final client = RealDebridClient(
        coordinator: coordinator,
        tokenProvider: () async => 'fixture',
        now: () => _epoch.add(clock.elapsed),
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          return _json({'id': 'fresh'});
        }),
      );
      _observe(client.resolveMagnet('magnet:fixture', timeout: const Duration(seconds: 5)), (value) => error = value);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 60));
      expect(error, isA<RdException>());
      expect(paths, ['/rest/1.0/torrents/addMagnet']);
      client.close();
      clock.flushMicrotasks();
    });
  });

  test('slow token lookup cannot bunch network starts and cancellation prevents late dispatch', () {
    fakeAsync((clock) {
      final coordinator = RdRequestCoordinator(now: () => _epoch.add(clock.elapsed));
      final token = Completer<String>();
      final starts = <Duration>[];
      final transport = MockClient((_) async {
        starts.add(clock.elapsed);
        return _json({});
      });
      final slow = RealDebridClient(coordinator: coordinator, tokenProvider: () => token.future, httpClient: transport);
      final fast = RealDebridClient(
        coordinator: coordinator,
        tokenProvider: () async => 'fixture',
        httpClient: transport,
      );
      _observe(slow.user(), (value) => fail('$value'));
      _observe(fast.user(), (value) => fail('$value'));
      clock.flushMicrotasks();
      expect(starts, [Duration.zero]);
      token.complete('fixture');
      clock.flushMicrotasks();
      expect(starts, [Duration.zero]);
      clock.elapse(const Duration(seconds: 1));
      expect(starts, [Duration.zero, const Duration(seconds: 1)]);
      final lateToken = Completer<String>();
      Object? cancelled;
      final closed = RealDebridClient(
        coordinator: coordinator,
        tokenProvider: () => lateToken.future,
        httpClient: transport,
      );
      _observe(closed.user(), (value) => cancelled = value);
      closed.close();
      clock.flushMicrotasks();
      lateToken.complete('fixture');
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 5));
      expect(cancelled, isA<BeamCancelled>());
      expect(starts, hasLength(2));
      slow.close();
      fast.close();
      clock.flushMicrotasks();
    });
  });

  test('a later throttle extends an existing cooldown instead of shortening it', () {
    fakeAsync((clock) {
      final coordinator = RdRequestCoordinator(now: () => _epoch.add(clock.elapsed));
      final first = Completer<http.Response>(), second = Completer<http.Response>();
      final starts = <Duration>[];
      final token = BeamCancellation();
      for (final response in [first.future, second.future, Future.value(_json({}))]) {
        _observe(
          coordinator.request(() {
            starts.add(clock.elapsed);
            return response;
          }, cancellation: token),
          (_) {},
        );
      }
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 1));
      first.complete(_json({}, 429, {'retry-after': '120'}));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 10));
      second.complete(_json({}, 429));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 109));
      expect(starts, hasLength(2));
      clock.elapse(const Duration(seconds: 1));
      expect(starts.last, const Duration(seconds: 121));
      token.cancel();
      clock.flushMicrotasks();
    });
  });
}
