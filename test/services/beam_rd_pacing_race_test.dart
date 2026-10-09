import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/services/beam/rd_request_coordinator.dart';
import 'package:plezy/services/beam/realdebrid_client.dart';

void main() {
  for (final cancelBeforeFrame in [false, true]) {
    testWidgets(
      'native races eight RD cooldown waits; ${cancelBeforeFrame ? 'Back' : 'first frame'} cancels queued calls',
      (tester) async {
        final coordinator = RdRequestCoordinator(now: tester.binding.clock.now);
        var requests = 0;
        final clients = <RealDebridClient>[];
        RealDebridClient client({BeamCancellation? cancellation}) {
          final rd = RealDebridClient(
            coordinator: coordinator,
            cancellation: cancellation,
            tokenProvider: () async => 'fixture',
            httpClient: MockClient((_) async {
              requests++;
              return http.Response('{"error_code":34}', 429);
            }),
          );
          clients.add(rd);
          return rd;
        }

        final throttled = expectLater(client().user(), throwsA(isA<RdException>()));
        await tester.pump();
        await throttled;
        expect(requests, 1);
        final ready = List.generate(8, (_) => Completer<BeamPlayResult>());
        final nativeTokens = <BeamCancellation>[];
        final rdTokens = <BeamCancellation>[];
        final results = <BeamPlayResult>[];
        final errors = <Object>[];
        final attempts = <BeamCancellation>[];
        for (var i = 0; i < 8; i++) {
          final index = i;
          final cancellation = BeamCancellation();
          attempts.add(cancellation);
          final service = BeamPlayService(
            realDebrid: (_, _, _, token) async {
              rdTokens.add(token);
              final rd = client(cancellation: token);
              try {
                await rd.addMagnet('magnet:?xt=urn:btih:fixture');
                throw StateError('No RD request should escape the cooldown');
              } finally {
                rd.close();
              }
            },
            torrent: (_, _, _, token) {
              nativeTokens.add(token);
              return ready[index].future;
            },
          );
          final race = service.race(
            ProwlarrResult.fromJson({'title': 'Pioneer.One.S01E02', 'guid': 'magnet:?xt=urn:btih:fixture$index'}),
            rdEnabled: true,
            torrentEnabled: true,
            cancellation: cancellation,
            deferLoserCancellation: true,
          );
          unawaited(race.then(results.add, onError: errors.add));
        }
        await tester.pump();
        expect(nativeTokens, hasLength(8));
        expect(rdTokens, hasLength(8));
        expect(requests, 1);
        if (cancelBeforeFrame) {
          for (final attempt in attempts) {
            attempt.cancel();
          }
        } else {
          for (final native in ready) {
            native.complete(
              BeamPlayResult(url: 'http://127.0.0.1/fixture', winner: BeamPlayWinner.torrent, magnet: 'fixture'),
            );
          }
          await tester.pump();
          expect(results, hasLength(8));
          expect(rdTokens.every((token) => !token.isCancelled), isTrue);
          for (final result in results) {
            result.commitPlayback();
          }
        }
        await tester.pump();
        expect(errors, cancelBeforeFrame ? hasLength(8) : isEmpty);
        expect(errors, everyElement(isA<BeamCancelled>()));
        expect(rdTokens.every((token) => token.isCancelled), isTrue);
        await tester.pump(const Duration(minutes: 2));
        expect(requests, 1, reason: 'Cancelled RD posts must never be sent after cooldown');
        for (final result in results) {
          result.cancel();
        }
        for (final rd in clients) {
          rd.close();
        }
        await tester.pump();
        expect(nativeTokens.every((token) => token.isCancelled), isTrue);
      },
    );
  }
}
