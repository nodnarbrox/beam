import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/beam/beam_resolve_sheet.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/episode_file_selector.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final source = ProwlarrResult(
    title: 'Pioneer One S01',
    indexer: 'test',
    size: 1000,
    seeders: 1,
    leechers: 0,
    magnetUrl: 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
    downloadUrl: null,
    infoUrl: null,
    categories: const [],
    publishDate: null,
  );

  for (final titled in [false, true]) {
    testWidgets('manual resolver ${titled ? "accepts exact story" : "rejects number-only catalog story"}', (
      tester,
    ) async {
      var played = false;
      final service = BeamPlayService(
        torrent: (source, season, episode, cancellation) async => BeamPlayResult(
          url: 'https://fixture/video.mp4',
          winner: BeamPlayWinner.torrent,
          magnet: source.magnetUrl!,
          selectedFilename: titled ? 'Pioneer.One.S01E02.To.Catch.a.Cat.720p.mp4' : 'Pioneer.One.S01E02.720p.mp4',
        ),
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute(
            builder: (_) => Scaffold(
              body: BeamResolveSheet(
                result: source,
                season: 1,
                episode: 2,
                storyConstraint: const EpisodeStoryConstraint(title: 'To Catch a Cat'),
                playService: service,
                onPlayResolved: (result) async {
                  played = true;
                  result.cancel();
                  return true;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(played, titled);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final handedOff in [false, true]) {
    testWidgets(
      'manual deferred handoff ${handedOff ? "transfers ownership until player closes" : "cancels if player cannot be opened"}',
      (tester) async {
        BeamCancellation? token;
        BeamPlayResult? handedPlayback;
        final navigator = GlobalKey<NavigatorState>();
        final service = BeamPlayService(
          torrent: (source, season, episode, cancellation) async {
            token = cancellation;
            return BeamPlayResult(
              url: 'https://fixture/video.mp4',
              winner: BeamPlayWinner.torrent,
              magnet: source.magnetUrl!,
            );
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Home')),
          ),
        );
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                body: BeamResolveSheet(
                  result: source,
                  playService: service,
                  onPlayResolved: (playback) async {
                    handedPlayback = playback;
                    return handedOff;
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(handedPlayback, isNotNull);
        expect(token?.isCancelled, !handedOff);
        if (handedOff) {
          handedPlayback!.cancel();
          handedPlayback!.commitPlayback();
          expect(token?.isCancelled, isTrue);
        }
      },
    );
  }

  for (final succeed in [false, true]) {
    testWidgets(
      succeed
          ? 'successful manual handoff retains winning stream'
          : 'manual Back cancels attempt and suppresses late ready',
      (tester) async {
        final pending = Completer<BeamPlayResult>();
        BeamCancellation? transportCancellation;
        var played = 0;
        final service = BeamPlayService(
          torrent: (source, season, episode, cancellation) {
            expect(season, 1);
            expect(episode, 2);
            transportCancellation = cancellation;
            return pending.future;
          },
        );
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Home')),
          ),
        );
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                body: BeamResolveSheet(
                  result: source,
                  season: 1,
                  episode: 2,
                  playService: service,
                  onPlay: (url, title, {infoHash, magnet}) => played++,
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 30 && transportCancellation == null; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(transportCancellation, isNotNull);
        if (!succeed) {
          navigator.currentState!.pop();
          await tester.pump();
          expect(transportCancellation!.isCancelled, isTrue);
        }
        pending.complete(
          BeamPlayResult(url: 'http://localhost/episode2', winner: BeamPlayWinner.torrent, magnet: source.magnetUrl!),
        );
        await tester.pumpAndSettle();
        expect(played, succeed ? 1 : 0);
        expect(transportCancellation!.isCancelled, !succeed);
        expect(find.text('Home'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
