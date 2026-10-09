import 'package:plezy/services/beam/rd_request_coordinator.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/services/beam/realdebrid_client.dart';

void main() {
  test('RD HTTP451 cannot end a pending native race; native can later play and commit', () async {
    final source = ProwlarrResult.fromJson({
      'title': 'Pioneer.One.S01E02',
      'guid': 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
      'seeders': 5,
    });
    final rdFailed = Completer<void>();
    final nativeReady = Completer<BeamPlayResult>();
    late BeamCancellation rdCancellation;
    late BeamCancellation nativeCancellation;
    var saw451 = false;
    var raceCompleted = false;
    final client = RealDebridClient(
      coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
      tokenProvider: () async => 'fixture-token',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/addMagnet')) return http.Response(jsonEncode({'id': 'fixture'}), 201);
        if (request.url.path.endsWith('/info/fixture')) {
          return http.Response(
            jsonEncode({
              'status': 'downloaded',
              'files': [
                {'id': 1, 'path': 'Pioneer.One.S01E02.mp4', 'bytes': 100, 'selected': 1},
              ],
              'links': ['fixture-link'],
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/unrestrict/link')) {
          saw451 = true;
          return http.Response(jsonEncode({'error': 'infringing_file', 'error_code': 35}), 451);
        }
        fail('Unexpected account request ${request.url}');
      }),
    );
    final service = BeamPlayService(
      realDebrid: (source, season, episode, cancellation) async {
        rdCancellation = cancellation;
        try {
          await client.resolveMagnet(source.magnetUrl!, season: season, episode: episode, cancellation: cancellation);
          fail('RD fixture must reject the stream');
        } finally {
          rdFailed.complete();
        }
      },
      torrent: (source, season, episode, cancellation) {
        nativeCancellation = cancellation;
        return nativeReady.future;
      },
    );
    final race = service.race(
      source,
      rdEnabled: true,
      torrentEnabled: true,
      season: 1,
      episode: 2,
      deferLoserCancellation: true,
    );
    unawaited(race.then((_) => raceCompleted = true));
    await rdFailed.future;
    await Future<void>.delayed(Duration.zero);
    expect(saw451, isTrue);
    expect(raceCompleted, isFalse);
    expect(nativeCancellation.isCancelled, isFalse);
    nativeReady.complete(
      BeamPlayResult(
        url: 'http://127.0.0.1/fixture-episode',
        winner: BeamPlayWinner.torrent,
        magnet: source.magnetUrl!,
        selectedFilename: 'Pioneer.One.S01E02.mp4',
      ),
    );
    final result = await race;
    expect(result.winner, BeamPlayWinner.torrent);
    expect(nativeCancellation.isCancelled, isFalse);
    expect(rdCancellation.isCancelled, isFalse);
    result.commitPlayback();
    expect(rdCancellation.isCancelled, isTrue);
    expect(nativeCancellation.isCancelled, isFalse);
    result.cancel();
    expect(nativeCancellation.isCancelled, isTrue);
  });
}
