import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/beam/beam_fallback.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';

/// Hold the production library service at the asynchronous resume lookup.
class _DelayedResumeDatabase extends AppDatabase {
  _DelayedResumeDatabase() : super.forTesting(NativeDatabase.memory());

  final resumeRequested = Completer<void>();
  final resumeResult = Completer<BeamProgressData?>();

  @override
  Future<BeamProgressData?> getBeamProgress(String infoHash) {
    resumeRequested.complete();
    return resumeResult.future;
  }
}

void main() {
  late _DelayedResumeDatabase db;
  setUp(() {
    // Mock configuration enables both injected transports; no network is used.
    SharedPreferences.setMockInitialValues({'beam_rd_token': 'test-only-fixture'});
    db = _DelayedResumeDatabase();
  });

  testWidgets('Back during resume lookup cancels both owners before the departing origin is disposed', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    const episode = BeamEpisodeIdentity(showId: 'pioneer-one', showTitle: 'Pioneer One', season: 1, episode: 2);
    final source = ProwlarrResult.fromJson({
      'title': 'Pioneer.One.S01.Complete',
      'seeders': 10,
      'guid': 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
    });
    BuildContext? originContext;
    ModalRoute<dynamic>? originRoute;
    BeamCancellation? rdOwner;
    BeamCancellation? torrentOwner;
    var playerOpened = false;
    final pendingTorrent = Completer<BeamPlayResult>();
    Future<bool>? playback;

    BeamFallback.searchOverride = (_, _) async => [source];
    BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
    BeamFallback.playServiceOverride = BeamPlayService(
      realDebrid: (candidate, season, number, cancellation) async {
        rdOwner = cancellation;
        return BeamPlayResult(
          url: 'https://fixture/episode2.mp4',
          winner: BeamPlayWinner.realDebrid,
          magnet: candidate.magnetUrl!,
        );
      },
      torrent: (_, _, _, cancellation) {
        torrentOwner = cancellation;
        return cancellation.bind(pendingTorrent.future);
      },
    );
    BeamFallback.playerWrapper = (_) {
      playerOpened = true;
      return const Scaffold(body: Text('Unexpected player'));
    };
    addTearDown(() async {
      BeamFallback.searchOverride = null;
      BeamFallback.playServiceOverride = null;
      BeamFallback.cachedSourcesOverride = null;
      BeamFallback.playerWrapper = null;
      await tester.runAsync(db.close);
    });

    await tester.pumpWidget(
      Provider<AppDatabase>.value(
        value: db,
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    unawaited(
      navigator.currentState!.push<void>(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 200),
          reverseTransitionDuration: const Duration(seconds: 2),
          pageBuilder: (context, _, _) {
            originContext = context;
            originRoute = ModalRoute.of(context);
            return const Scaffold(body: Text('Origin detail'));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      playback = BeamFallback.playByTitle(originContext!, title: episode.showTitle, beamEpisode: episode);
      await db.resumeRequested.future.timeout(const Duration(seconds: 10));
    });
    await tester.pump();
    expect(rdOwner?.isCancelled, isFalse);
    expect(torrentOwner?.isCancelled, isFalse);
    expect(playerOpened, isFalse);
    expect(originRoute!.isCurrent, isTrue);

    // Android/system Back starts the reverse transition without disposing yet.
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 10));
    expect(originContext!.mounted, isTrue);
    expect(originRoute!.isCurrent, isFalse);

    await tester.runAsync(() async {
      db.resumeResult.complete(null);
      expect(await playback!.timeout(const Duration(seconds: 10)), isFalse);
    });
    await tester.pump();
    expect(originContext!.mounted, isTrue, reason: 'The guard must work before disposal ends the Back transition.');
    expect(rdOwner!.isCancelled, isTrue);
    expect(torrentOwner!.isCancelled, isTrue);
    expect(playerOpened, isFalse);
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Unexpected player'), findsNothing);
  });
}
