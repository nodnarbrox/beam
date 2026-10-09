import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_fallback.dart';
import 'package:plezy/services/beam/beam_library_service.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/episode_file_selector.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';

void main() {
  const e1 = BeamEpisodeIdentity(showId: 'pioneer-one', showTitle: 'Pioneer One', season: 1, episode: 1);
  const e2 = BeamEpisodeIdentity(showId: 'pioneer-one', showTitle: 'Pioneer One', season: 1, episode: 2);
  final source = ProwlarrResult.fromJson({
    'title': 'Pioneer.One.S01.Complete',
    'seeders': 10,
    'guid': 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
  });
  const pack = [
    EpisodeFile(id: 1, path: 'Pioneer.One.S01E01.mp4', size: 2913186),
    EpisodeFile(id: 2, path: 'Pioneer.One.S01E02.mp4', size: 1028067),
  ];
  late AppDatabase db;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    BeamFallback.searchOverride = (query, _) async {
      if (query.contains('E0')) throw StateError('individual episode indexer unavailable');
      return [source];
    };
  });
  tearDown(() async {
    BeamFallback.searchOverride = null;
    BeamFallback.playServiceOverride = null;
    BeamFallback.cachedSourcesOverride = null;
    BeamFallback.playerWrapper = null;
    await db.close();
  });

  for (final titled in [false, true]) {
    testWidgets('automatic virtual episode ${titled ? "accepts matching story" : "rejects number-only file"}', (
      tester,
    ) async {
      final metadata = e2.playerMetadata.copyWith(title: 'To Catch a Cat', raw: {'beamCatalog': 'tvmaze'});
      final identity = BeamEpisodeIdentity(
        showId: e2.showId,
        showTitle: e2.showTitle,
        season: 1,
        episode: 2,
        metadata: metadata,
      );
      VideoPlayerScreen? opened;
      Future<bool>? playback;
      BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
      BeamFallback.playServiceOverride = BeamPlayService(
        torrent: (source, season, episode, cancellation) async => BeamPlayResult(
          url: 'https://fixture/video.mp4',
          winner: BeamPlayWinner.torrent,
          magnet: source.magnetUrl!,
          selectedFilename: titled ? 'Pioneer.One.S01E02.To.Catch.a.Cat.720p.mp4' : 'Pioneer.One.S01E02.720p.mp4',
        ),
      );
      BeamFallback.playerWrapper = (player) {
        opened = player;
        return const Scaffold(body: Text('Correct story player'));
      };
      await tester.pumpWidget(
        Provider.value(
          value: db,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      playback = BeamFallback.playByTitle(context, title: identity.showTitle, beamEpisode: identity),
                  child: const Text('Play catalog story'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Play catalog story'));
      await tester.runAsync(() async => expect(await playback, titled));
      await tester.pumpAndSettle();
      expect(opened != null, titled);
      if (titled) expect(opened!.metadata.title, 'To Catch a Cat');
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final filename in ['Pioneer.One.S01E01-E02.mp4', 'Pioneer.One.S01E02.mp4']) {
    testWidgets(
      'selected file $filename supplies appropriate combined-file notice without changing requested episode',
      (tester) async {
        VideoPlayerScreen? opened;
        Future<bool>? playback;
        final paired = filename.contains('E01-E02');
        final queuedEpisode = BeamEpisodeIdentity(
          showId: e2.showId,
          showTitle: e2.showTitle,
          season: 1,
          episode: 2,
          episodeQueue: [
            e1.playerMetadata,
            e2.playerMetadata,
            const BeamEpisodeIdentity(
              showId: 'pioneer-one',
              showTitle: 'Pioneer One',
              season: 1,
              episode: 3,
            ).playerMetadata,
          ],
        );
        BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
        BeamFallback.playServiceOverride = BeamPlayService(
          torrent: (source, season, episode, cancellation) async => BeamPlayResult(
            url: 'https://fixture/video.mp4',
            winner: BeamPlayWinner.torrent,
            magnet: source.magnetUrl!,
            selectedFilename: filename,
          ),
        );
        BeamFallback.playerWrapper = (player) {
          opened = player;
          return Builder(
            builder: (context) => Scaffold(
              body: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close notice fixture')),
            ),
          );
        };
        await tester.pumpWidget(
          Provider.value(
            value: db,
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () =>
                        playback = BeamFallback.playByTitle(context, title: e2.showTitle, beamEpisode: queuedEpisode),
                    child: const Text('Start notice fixture'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Start notice fixture'));
        await tester.runAsync(() async => expect(await playback, isTrue));
        await tester.pumpAndSettle();
        expect(opened!.metadata.index, 2);
        expect(opened!.beamEpisode!.contentKey, e2.contentKey);
        expect(opened!.beamEpisode!.episodeQueue.map((item) => item.index), paired ? [2, 3] : [1, 2, 3]);
        expect(queuedEpisode.episodeQueue.map((item) => item.index), [1, 2, 3]);
        if (paired) {
          expect(opened!.directPlaybackNotice, contains('E1'));
          expect(opened!.directPlaybackNotice, contains('E2'));
          expect(opened!.directPlaybackNotice!.toLowerCase(), contains('file'));
        } else {
          expect(opened!.directPlaybackNotice, isNull);
        }
        await tester.tap(find.text('Close notice fixture'));
        await tester.pumpAndSettle();
        expect(find.text('Start notice fixture'), findsOneWidget);
      },
    );
  }

  testWidgets('owned next episode replaces Beam with a server player and releases the old race', (tester) async {
    final owned = e2.playerMetadata.copyWith(id: 'owned-episode-2', serverId: 'real-server', viewOffsetMs: 42000);
    final queued = BeamEpisodeIdentity(
      showId: e1.showId,
      showTitle: e1.showTitle,
      season: 1,
      episode: 1,
      episodeQueue: [
        e1.playerMetadata,
        owned,
        e2.playerMetadata.copyWith(id: 'virtual-three', index: 3),
      ],
    );
    BeamCancellation? token;
    final opened = <VideoPlayerScreen>[];
    Future<bool>? playback;
    var searches = 0;
    BeamFallback.searchOverride = (_, _) async {
      searches++;
      return [source];
    };
    BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
    BeamFallback.playServiceOverride = BeamPlayService(
      torrent: (source, season, episode, cancellation) async {
        token = cancellation;
        return BeamPlayResult(
          url: 'https://fixture/first.mp4',
          winner: BeamPlayWinner.torrent,
          magnet: source.magnetUrl!,
        );
      },
    );
    BeamFallback.playerWrapper = (player) {
      opened.add(player);
      return Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: player.directVideoUrl == null
                ? () => Navigator.pop(context)
                : () => playback = BeamFallback.playEpisode(context, current: player.beamEpisode!, target: owned),
            child: Text(player.directVideoUrl == null ? 'Close owned' : 'Next owned'),
          ),
        ),
      );
    };
    await tester.pumpWidget(
      Provider.value(
        value: db,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => playback = BeamFallback.playByTitle(context, title: e1.showTitle, beamEpisode: queued),
                child: const Text('Start owned queue'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start owned queue'));
    await tester.runAsync(() async => expect(await playback, isTrue));
    await tester.pumpAndSettle();
    expect(token?.isCancelled, isFalse);
    final searchesBefore = searches;
    await tester.tap(find.text('Next owned'));
    await tester.runAsync(() async => expect(await playback, isTrue));
    await tester.pumpAndSettle();
    expect(searches, searchesBefore, reason: 'Owned playback must not search indexers.');
    expect(opened.length, 2);
    expect(opened.last.metadata, same(owned));
    expect(opened.last.metadata.viewOffsetMs, 42000);
    expect(opened.last.directVideoUrl, isNull);
    expect(opened.last.beamEpisode?.episode, 2);
    expect(opened.last.beamEpisode?.showId, e1.showId);
    expect(opened.last.beamEpisode?.episodeQueue.map((item) => item.index), [1, 2, 3]);
    expect(opened.last.beamEpisode?.episodeQueue.last.id, 'virtual-three');
    expect(token?.isCancelled, isTrue, reason: 'Replacing the old route releases its deferred candidate race.');
    await tester.tap(find.text('Close owned'));
    await tester.pumpAndSettle();
    expect(find.text('Start owned queue'), findsOneWidget);
    expect(find.text('Next owned'), findsNothing);
  });

  testWidgets('owned handoff cannot replace a newer route while saved preferences resolve', (tester) async {
    final owned = e2.playerMetadata.copyWith(id: 'owned-episode-2', serverId: 'real-server');
    Future<bool>? playback;
    var cancelled = 0;
    var opened = 0;
    BeamFallback.searchOverride = (_, _) async => throw StateError('Owned episodes must not search');
    BeamFallback.playerWrapper = (_) {
      opened++;
      return const SizedBox();
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                playback = BeamFallback.playEpisode(
                  context,
                  current: e1,
                  target: owned,
                  onCancelled: () => cancelled++,
                );
                Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Newer route'))));
              },
              child: const Text('Start then leave'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start then leave'));
    await tester.runAsync(() async => expect(await playback, isFalse));
    await tester.pumpAndSettle();
    expect(find.text('Newer route'), findsOneWidget);
    expect(opened, 0);
    expect(cancelled, 1);
  });

  for (final failBeforeFrame in [false, true]) {
    testWidgets(
      'auto player ${failBeforeFrame ? "startup failure" : "close before first frame"} releases its deferred race',
      (tester) async {
        BeamCancellation? token;
        VideoPlayerScreen? opened;
        Future<bool>? playback;
        BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
        BeamFallback.playServiceOverride = BeamPlayService(
          torrent: (source, season, episode, cancellation) async {
            token = cancellation;
            return BeamPlayResult(
              url: 'https://fixture/video.mp4',
              winner: BeamPlayWinner.torrent,
              magnet: source.magnetUrl!,
            );
          },
        );
        BeamFallback.playerWrapper = (player) {
          opened = player;
          return Builder(
            builder: (context) => Scaffold(
              body: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close deferred')),
            ),
          );
        };
        await tester.pumpWidget(
          Provider.value(
            value: db,
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () =>
                        playback = BeamFallback.playByTitle(context, title: 'Pioneer One', beamEpisode: e1),
                    child: const Text('Start deferred'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Start deferred'));
        await tester.runAsync(() async {
          expect(await playback, isTrue);
        });
        await tester.pumpAndSettle();
        expect(token?.isCancelled, isFalse);
        expect(opened?.onDirectPlaybackStarted, isNotNull);
        expect(opened?.onDirectPlaybackFailed, isNotNull);
        if (failBeforeFrame) {
          opened!.onDirectPlaybackFailed!();
          opened!.onDirectPlaybackStarted!();
          expect(token?.isCancelled, isTrue);
        }
        await tester.tap(find.text('Close deferred'));
        await tester.pumpAndSettle();
        expect(token?.isCancelled, isTrue);
      },
    );
  }

  testWidgets('actual fallback constructs TV player, preserves separate resume and replaces next route', (
    tester,
  ) async {
    final lib = BeamLibraryService(db);
    await lib.saveProgress(infoHash: e1.contentKey, positionMs: 11000, durationMs: 100000);
    await lib.saveProgress(infoHash: e2.contentKey, positionMs: 22000, durationMs: 100000);
    final opened = <VideoPlayerScreen>[];
    Future<bool>? playback;
    BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
    BeamFallback.playServiceOverride = BeamPlayService(
      torrent: (source, season, episode, cancel) async {
        final selected = EpisodeFileSelector.select(pack, season: season, episode: episode);
        return BeamPlayResult(
          url: 'https://fixture/e${selected.id}.mp4',
          winner: BeamPlayWinner.torrent,
          magnet: source.magnetUrl!,
        );
      },
    );
    BeamFallback.playerWrapper = (player) {
      opened.add(player);
      return Builder(
        builder: (context) => Scaffold(
          body: Column(
            children: [
              Text('Playing ${player.metadata.index}'),
              TextButton(
                onPressed: () => playback = BeamFallback.playEpisode(
                  context,
                  current: player.beamEpisode!,
                  target: e2.playerMetadata,
                ),
                child: const Text('Next'),
              ),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            ],
          ),
        ),
      );
    };
    await tester.pumpWidget(
      Provider.value(
        value: db,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => playback = BeamFallback.playByTitle(context, title: 'Pioneer One', beamEpisode: e1),
                child: const Text('Start'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await tester.runAsync(() async {
      expect(await playback, isTrue);
    });
    await tester.pumpAndSettle();
    expect(opened.last.metadata.kind, MediaKind.episode);
    expect(opened.last.beamResumeMs, 11000);
    expect(opened.last.beamContentKey, e1.contentKey);
    await tester.tap(find.text('Next'));
    await tester.runAsync(() async {
      expect(await playback, isTrue);
    });
    await tester.pumpAndSettle();
    expect(opened.last.directVideoUrl, 'https://fixture/e2.mp4');
    expect(opened.last.metadata.index, 2);
    expect(opened.last.beamResumeMs, 22000);
    expect(opened.last.beamContentKey, e2.contentKey);
    final entries = await lib.recentlyPlayed();
    expect(entries.length, 2);
    expect(entries.map((e) => e.item.sourceInfoHash).toSet(), {source.infoHash});
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Start'), findsOneWidget);
  });

  testWidgets('BACK cancellation reports cancel, late old resolve cannot replace new episode', (tester) async {
    final old = Completer<BeamPlayResult>();
    var cancelled = false;
    var cleaned = false;
    Future<bool>? playback;
    final opened = <int?>[];
    BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
    BeamFallback.playServiceOverride = BeamPlayService(
      torrent: (source, season, episode, cancel) {
        if (episode == 1) {
          unawaited(
            cancel.whenCancelled.then((_) {
              cleaned = true;
            }),
          );
          return old.future;
        }
        return Future.value(
          BeamPlayResult(url: 'https://fixture/e2.mp4', winner: BeamPlayWinner.torrent, magnet: source.magnetUrl!),
        );
      },
    );
    BeamFallback.playerWrapper = (player) {
      opened.add(player.metadata.index);
      return const Scaffold(body: Text('Episode two'));
    };
    await tester.pumpWidget(
      Provider.value(
        value: db,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () => playback = BeamFallback.playByTitle(
                      context,
                      title: 'Pioneer One',
                      beamEpisode: e1,
                      onCancelled: () {
                        cancelled = true;
                      },
                    ),
                    child: const Text('Start one'),
                  ),
                  TextButton(
                    onPressed: () =>
                        playback = BeamFallback.playByTitle(context, title: 'Pioneer One', beamEpisode: e2),
                    child: const Text('Start two'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start one'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(await playback, isFalse);
    expect(cancelled, isTrue);
    expect(cleaned, isTrue);
    expect(find.textContaining("Couldn't find"), findsNothing);
    await tester.tap(find.text('Start two'));
    await tester.runAsync(() async {
      expect(await playback, isTrue);
    });
    await tester.pumpAndSettle();
    old.complete(
      BeamPlayResult(url: 'https://fixture/wrong-e1.mp4', winner: BeamPlayWinner.torrent, magnet: source.magnetUrl!),
    );
    await tester.pumpAndSettle();
    expect(opened, [2]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('incomplete TV identity refuses source search instead of movie fallback', (tester) async {
    var searched = false;
    BeamFallback.searchOverride = (_, _) async {
      searched = true;
      return [source];
    };
    Future<bool>? playback;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => playback = BeamFallback.playByTitle(
                context,
                title: 'Pioneer One',
                kind: MediaKind.episode,
                season: 1,
              ),
              child: const Text('Start'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(await playback, isFalse);
    expect(searched, isFalse);
    expect(find.textContaining('Choose an episode'), findsOneWidget);
  });
  testWidgets('missing show title cannot become a search for the episode title', (tester) async {
    var searched = false;
    BeamFallback.searchOverride = (_, _) async {
      searched = true;
      return [source];
    };
    Future<bool>? playback;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => playback = BeamFallback.playByTitle(
                context,
                title: 'Earthfall',
                metadata: e1.playerMetadata.copyWith(grandparentTitle: null),
                kind: MediaKind.episode,
                season: 1,
                episode: 1,
              ),
              child: const Text('Start'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(await playback, isFalse);
    expect(searched, isFalse);
    expect(find.textContaining('Choose an episode'), findsOneWidget);
  });
}
