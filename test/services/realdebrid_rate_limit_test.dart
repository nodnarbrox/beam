import 'package:plezy/services/beam/rd_request_coordinator.dart';
import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/beam/realdebrid_client.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';

http.Response _json(Object data, [int status = 200]) => http.Response(jsonEncode(data), status);
const _hash = '0123456789012345678901234567890123456789';
const _magnet = 'magnet:?xt=urn:btih:$_hash';
final _throttled = isA<RdException>().having((error) => error.code, 'HTTP code', 429);
final _ready = {
  'status': 'downloaded',
  'files': [
    {'id': 1, 'path': 'Pioneer.One.S01E02.mp4', 'bytes': 100, 'selected': 1},
  ],
  'links': ['fixture-link'],
};

void main() {
  test('eight concurrent throttled lookups never fall through to an add or delete', () async {
    final requests = <http.Request>[];
    final clients = List.generate(
      8,
      (_) => RealDebridClient(
        coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
        tokenProvider: () async => 'fixture',
        httpClient: MockClient((request) async {
          requests.add(request);
          return _json({'error': 'too_many_requests'}, 429);
        }),
      ),
    );
    await Future.wait(
      clients.map((client) => expectLater(client.resolveMagnetSmart(_magnet, infoHash: _hash), throwsA(_throttled))),
    );
    expect(requests, hasLength(8));
    expect(requests.every((request) => request.method == 'GET' && request.url.path.endsWith('/torrents')), isTrue);
  });

  for (final throttledPath in ['/info/existing', '/unrestrict/link']) {
    test('cached job HTTP429 at $throttledPath preserves job and does not add again', () async {
      final requests = <http.Request>[];
      final client = RealDebridClient(
        coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
        tokenProvider: () async => 'fixture',
        httpClient: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (path.endsWith('/torrents')) {
            return _json([
              {'id': 'existing', 'hash': _hash, 'status': 'downloaded'},
            ]);
          }
          if (path.endsWith(throttledPath)) return _json({'error': 'too_many_requests'}, 429);
          if (path.endsWith('/info/existing')) return _json(_ready);
          fail('Unexpected request after throttling: ${request.method} ${request.url.path}');
        }),
      );
      await expectLater(
        client.resolveMagnetSmart(_magnet, infoHash: _hash, season: 1, episode: 2),
        throwsA(_throttled),
      );
      expect(requests.where((request) => request.url.path.endsWith(throttledPath)), hasLength(1));
      expect(requests.any((request) => request.url.path.contains('addMagnet') || request.method == 'DELETE'), isFalse);
    });
  }

  test('a throttled RD lookup leaves native pending and able to win', () async {
    final failed = Completer<void>();
    final nativeReady = Completer<BeamPlayResult>();
    late BeamCancellation nativeCancel;
    var resolved = false;
    final client = RealDebridClient(
      coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
      tokenProvider: () async => 'fixture',
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        return _json({'error': 'too_many_requests'}, 429);
      }),
    );
    final service = BeamPlayService(
      realDebrid: (_, season, episode, cancellation) async {
        try {
          await client.resolveMagnetSmart(_magnet, infoHash: _hash, cancellation: cancellation);
          throw StateError('Fixture should be throttled');
        } finally {
          failed.complete();
        }
      },
      torrent: (_, season, episode, cancellation) {
        nativeCancel = cancellation;
        return nativeReady.future;
      },
    );
    final pending = service.race(
      ProwlarrResult.fromJson({'title': 'fixture', 'guid': _magnet, 'seeders': 5}),
      rdEnabled: true,
      torrentEnabled: true,
      deferLoserCancellation: true,
    );
    unawaited(pending.then((_) => resolved = true));
    await failed.future;
    await Future<void>.delayed(Duration.zero);
    expect(resolved, isFalse);
    expect(nativeCancel.isCancelled, isFalse);
    nativeReady.complete(
      BeamPlayResult(url: 'http://127.0.0.1/video', winner: BeamPlayWinner.torrent, magnet: _magnet),
    );
    final playback = await pending;
    expect(playback.winner, BeamPlayWinner.torrent);
    playback.commitPlayback();
    expect(nativeCancel.isCancelled, isFalse);
    playback.cancel();
    expect(nativeCancel.isCancelled, isTrue);
  });

  test('ordinary lookup outage still permits fresh resolution', () async {
    final requests = <String>[];
    final client = RealDebridClient(
      coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
      tokenProvider: () async => 'fixture',
      httpClient: MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path.endsWith('/torrents')) return _json({'error': 'temporarily_unavailable'}, 503);
        if (request.url.path.endsWith('/addMagnet')) return _json({'id': 'fresh'}, 201);
        if (request.url.path.endsWith('/info/fresh')) return _json(_ready);
        if (request.url.path.endsWith('/unrestrict/link')) {
          return _json({'filename': 'Pioneer.One.S01E02.mp4', 'download': 'https://fixture/video'});
        }
        fail('Unexpected fixture request');
      }),
    );
    final result = await client.resolveMagnetSmart(_magnet, infoHash: _hash, season: 1, episode: 2);
    expect(result.torrentId, 'fresh');
    expect(requests.where((path) => path.endsWith('/addMagnet')), hasLength(1));
  });
}
