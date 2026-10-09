import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/services/beam/beam_fallback.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';

ProwlarrResult source(String title, String hash) => ProwlarrResult.fromJson({
  'title': title,
  'seeders': title.contains('YIFY') ? 0 : 10,
  'guid': 'magnet:?xt=urn:btih:$hash',
});
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'beam_rd_token': 'fixture'});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
  });
  tearDown(() {
    BeamFallback.searchOverride = null;
    BeamFallback.cachedSourcesOverride = null;
    BeamFallback.playServiceOverride = null;
    BeamFallback.playerWrapper = null;
  });
  final cached = source('The.Butler.2013.1080p.BluRay.YIFY', '0123456789012345678901234567890123456789');
  final indexed = source('The.Butler.2013.720p.BluRay.OFT', '1123456789012345678901234567890123456789');

  for (final cacheAvailable in [true, false]) {
    testWidgets(
      cacheAvailable
          ? 'completed account copy plays before a pending indexer missing that release'
          : 'failed account lookup falls through to indexed candidates',
      (tester) async {
        final pendingIndexer = Completer<List<ProwlarrResult>>();
        final attempted = <String>[];
        var torrentStarted = false;
        BeamCancellation? rdToken;
        BeamCancellation? torrentToken;
        VideoPlayerScreen? opened;
        Future<bool>? operation;
        BeamFallback.searchOverride = (_, _) => cacheAvailable ? pendingIndexer.future : Future.value([indexed]);
        BeamFallback.cachedSourcesOverride = (_, _, _, _) async {
          if (!cacheAvailable) throw StateError('account list unavailable');
          return [cached];
        };
        BeamFallback.playServiceOverride = BeamPlayService(
          realDebrid: (candidate, _, _, cancellation) async {
            rdToken = cancellation;
            attempted.add(candidate.title);
            return BeamPlayResult(
              url: 'https://fixture/butler.mp4',
              winner: BeamPlayWinner.realDebrid,
              magnet: candidate.magnetUrl!,
            );
          },
          torrent: (_, _, _, token) {
            torrentStarted = true;
            torrentToken = token;
            return token.bind(Completer<BeamPlayResult>().future);
          },
        );
        BeamFallback.playerWrapper = (player) {
          opened = player;
          return Builder(
            builder: (context) => Scaffold(
              body: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close cached playback')),
            ),
          );
        };
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => operation = BeamFallback.playByTitle(context, title: 'The Butler', year: 2013),
                  child: const Text('Play'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Play'));
        await tester.runAsync(() async => expect(await operation, isTrue));
        await tester.pumpAndSettle();
        expect(attempted, [cacheAvailable ? cached.title : indexed.title]);
        expect(torrentStarted, isTrue);
        expect(rdToken?.isCancelled, isFalse);
        expect(torrentToken?.isCancelled, isFalse);
        opened!.onDirectPlaybackStarted!();
        expect(rdToken?.isCancelled, isFalse);
        expect(torrentToken?.isCancelled, isTrue);
        if (cacheAvailable) {
          pendingIndexer.completeError(StateError('late indexer failure'));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.text('Close cached playback'));
        await tester.pumpAndSettle();
        expect(rdToken?.isCancelled, isTrue);
        expect(torrentToken?.isCancelled, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('Back during account lookup prevents late cached copy from starting transport', (tester) async {
    final pending = Completer<List<ProwlarrResult>>();
    Future<bool>? operation;
    var attempted = 0;
    BeamFallback.searchOverride = (_, _) async => [];
    BeamFallback.cachedSourcesOverride = (_, _, _, _) => pending.future;
    BeamFallback.playServiceOverride = BeamPlayService(
      realDebrid: (_, _, _, _) async {
        attempted++;
        throw StateError('must not start');
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => operation = BeamFallback.playByTitle(context, title: 'The Butler', year: 2013),
              child: const Text('Play'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Play'));
    await tester.pump();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(await operation, isFalse);
    pending.complete([cached]);
    await tester.pumpAndSettle();
    expect(attempted, 0);
  });
}
