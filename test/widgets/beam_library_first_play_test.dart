import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/beam/beam_fallback.dart';
import 'package:plezy/services/beam/beam_library_service.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';

import '../test_helpers/prefs.dart';

class _Harness {
  _Harness({this.episode, this.skipLibraryLookup = false, this.unknownYear = false});
  final BeamEpisodeIdentity? episode;
  final bool skipLibraryLookup;
  final bool unknownYear;
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final navigator = GlobalKey<NavigatorState>();
  final players = <VideoPlayerScreen>[];
  final events = <String>[];
  Future<bool>? operation;
  Future<bool>? fallback;
  BeamLibraryEntry? savedEntry;
  int cancelled = 0;
  int playbackClosed = 0;
  MediaItem get request =>
      episode?.playerMetadata ??
      MediaItem(
        id: 'discover:butler',
        backend: MediaBackend.plex,
        kind: MediaKind.movie,
        title: 'The Butler',
        year: unknownYear ? null : 2013,
      );
  MediaItem get owned => request.copyWith(id: 'library:42', serverId: 'server-one', viewOffsetMs: 42000);

  Future<void> mount(WidgetTester tester) async {
    final source = ProwlarrResult.fromJson({
      'title': episode == null ? 'The.Butler.2013.720p.BluRay.OFT' : 'Pioneer.One.S01E02.720p',
      'seeders': 10,
      'guid': 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
    });
    BeamFallback.searchOverride = (_, _) async {
      events.add('indexer');
      return [source];
    };
    BeamFallback.cachedSourcesOverride = (_, _, _, _) async {
      events.add('cache');
      return [];
    };
    BeamFallback.playServiceOverride = BeamPlayService(
      realDebrid: (candidate, _, _, _) async {
        events.add('RD');
        return BeamPlayResult(
          url: 'https://fixture.invalid/movie',
          winner: BeamPlayWinner.realDebrid,
          magnet: candidate.magnetUrl!,
        );
      },
      torrent: (_, _, _, token) {
        events.add('native');
        return token.bind(Completer<BeamPlayResult>().future);
      },
    );
    BeamFallback.playerWrapper = (player) {
      players.add(player);
      return Builder(
        builder: (context) => Scaffold(
          body: Column(
            children: [
              Text(player.directVideoUrl == null ? 'Library player' : 'Race player'),
              TextButton(
                onPressed: () => fallback = BeamFallback.playByTitle(
                  context,
                  title: 'The Butler',
                  year: 2013,
                  metadata: request,
                  skipLibraryLookup: true,
                  replace: true,
                ),
                child: const Text('Simulate library failure'),
              ),
            ],
          ),
        ),
      );
    };
    addTearDown(() async {
      BeamFallback.libraryLookupOverride = null;
      BeamFallback.searchOverride = null;
      BeamFallback.cachedSourcesOverride = null;
      BeamFallback.playServiceOverride = null;
      BeamFallback.playerWrapper = null;
      await tester.runAsync(db.close);
    });
    await tester.pumpWidget(
      Provider.value(
        value: db,
        child: MaterialApp(
          navigatorKey: navigator,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => operation = BeamFallback.playByTitle(
                  context,
                  title: episode?.showTitle ?? 'The Butler',
                  year: episode?.year ?? (unknownYear ? null : 2013),
                  metadata: request,
                  beamEpisode: episode,
                  skipLibraryLookup: skipLibraryLookup,
                  savedEntry: savedEntry,
                  onCancelled: () => cancelled++,
                  onPlaybackClosed: () => playbackClosed++,
                ),
                child: const Text('Play selected item'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> close(WidgetTester tester) async {
    if (navigator.currentState!.canPop()) navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  }
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(condition(), isTrue);
}

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    SharedPreferences.setMockInitialValues({'beam_rd_token': 'fixture'});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
  });

  for (final isEpisode in [false, true]) {
    testWidgets('library ${isEpisode ? "exact episode" : "movie"} opens before any source work', (tester) async {
      final h = _Harness(
        episode: isEpisode
            ? BeamEpisodeIdentity(
                showId: 'pioneer-one',
                showTitle: 'Pioneer One',
                year: 2010,
                season: 1,
                episode: 2,
                metadata: MediaItem(
                  id: 'virtual-two',
                  backend: MediaBackend.plex,
                  kind: MediaKind.episode,
                  title: 'The Correct Story',
                  grandparentTitle: 'Pioneer One',
                  parentIndex: 1,
                  index: 2,
                  raw: {'beamCatalog': 'tvmaze'},
                ),
              )
            : null,
      );
      final owned = h.owned;
      BeamFallback.libraryLookupOverride = (title, year, metadata, episode) async {
        h.events.add('library');
        expect(title, isEpisode ? 'Pioneer One' : 'The Butler');
        expect(year, isEpisode ? 2010 : 2013);
        expect(metadata?.id, h.request.id);
        if (isEpisode) {
          expect((episode?.season, episode?.episode), (1, 2));
          expect(episode?.showId, 'pioneer-one');
        } else {
          expect(episode, isNull);
        }
        return owned;
      };
      await h.mount(tester);
      await tester.tap(find.text('Play selected item'));
      await tester.runAsync(() async => expect(await h.operation, isTrue));
      await tester.pumpAndSettle();
      expect(h.events, ['library']);
      expect(h.players.single.metadata, same(owned));
      expect(h.players.single.directVideoUrl, isNull);
      expect(h.players.single.metadata.viewOffsetMs, 42000);
      expect(h.players.single.beamEpisode, same(h.episode));
      if (isEpisode) expect(h.players.single.beamEpisode?.storyConstraint?.title, 'The Correct Story');
      expect(find.text('Library player'), findsOneWidget);
      await h.close(tester);
    });
  }

  for (final outcome in ['missing', 'error', 'timeout', 'skip']) {
    testWidgets('library $outcome falls through to both playback paths', (tester) async {
      final h = _Harness(skipLibraryLookup: outcome == 'skip');
      final pending = Completer<MediaItem?>();
      BeamFallback.libraryLookupOverride = (_, _, _, _) {
        h.events.add('library');
        if (outcome == 'error') throw StateError('server unavailable');
        return outcome == 'timeout' ? pending.future : Future.value(outcome == 'skip' ? h.owned : null);
      };
      await h.mount(tester);
      await tester.tap(find.text('Play selected item'));
      await tester.pump();
      if (outcome == 'timeout') {
        expect(h.events, ['library']);
        await tester.pump(const Duration(milliseconds: 4999));
        expect(h.events, ['library']);
        await tester.pump(const Duration(milliseconds: 1));
      }
      await _until(tester, () => h.players.isNotEmpty);
      await tester.pumpAndSettle();
      expect(await h.operation, isTrue);
      expect(h.events.where((event) => event == 'library'), hasLength(outcome == 'skip' ? 0 : 1));
      expect(h.events, containsAll(['indexer', 'cache', 'RD', 'native']));
      expect(h.players.single.directVideoUrl, isNotNull);
      if (outcome == 'timeout') {
        pending.complete(h.owned);
        await tester.pump();
        expect(h.players, hasLength(1), reason: 'A late lookup cannot replace the already selected source');
      }
      h.players.single.onDirectPlaybackStarted!();
      await h.close(tester);
    });
  }

  testWidgets('legacy saved movie keeps exact source and resume without title-only remake searches', (tester) async {
    final h = _Harness(unknownYear: true);
    const hash = '1123456789012345678901234567890123456789';
    const magnet = 'magnet:?xt=urn:btih:$hash';
    BeamFallback.libraryLookupOverride = (_, _, _, _) async {
      h.events.add('library');
      return null;
    };
    await h.mount(tester);
    final library = BeamLibraryService(h.db);
    await tester.runAsync(() async {
      await library.recordPlayed(
        infoHash: hash,
        title: 'The Butler',
        magnet: magnet,
        posterUrl: 'https://fixture.invalid/poster.jpg',
        quality: 'Saved 720p',
      );
      await library.saveProgress(infoHash: hash, positionMs: 65000, durationMs: 7200000);
      h.savedEntry = (await library.recentlyPlayed()).single;
    });
    await tester.tap(find.text('Play selected item'));
    await _until(tester, () => h.players.isNotEmpty);
    await tester.pumpAndSettle();
    expect(await h.operation, isTrue);
    expect(h.events, ['library', 'RD', 'native']);
    expect(h.players.single.beamInfoHash, hash);
    expect(h.players.single.beamResumeMs, 65000);
    await tester.runAsync(() async {
      final saved = (await library.recentlyPlayed()).single;
      expect(saved.posterUrl, 'https://fixture.invalid/poster.jpg');
      expect(saved.quality, 'Saved 720p');
      expect(saved.positionMs, 65000);
    });
    h.players.single.onDirectPlaybackStarted!();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(h.players, hasLength(1));
    expect(h.playbackClosed, 0);
    await h.close(tester);
    expect(h.playbackClosed, 1);
  });

  testWidgets('Back during library lookup prevents late player and source work', (tester) async {
    final h = _Harness();
    final pending = Completer<MediaItem?>();
    BeamFallback.libraryLookupOverride = (_, _, _, _) {
      h.events.add('library');
      return pending.future;
    };
    await h.mount(tester);
    await tester.tap(find.text('Play selected item'));
    await tester.pump();
    expect(h.events, ['library']);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(await h.operation, isFalse);
    expect(h.cancelled, 1);
    pending.complete(h.owned);
    await tester.pumpAndSettle();
    expect(h.events, ['library']);
    expect(h.players, isEmpty);
    expect(find.text('Play selected item'), findsOneWidget);
    await h.close(tester);
  });

  testWidgets('successful library handoff releases guard for failed-player source fallback', (tester) async {
    final h = _Harness();
    BeamFallback.libraryLookupOverride = (_, _, _, _) async {
      h.events.add('library');
      return h.owned;
    };
    await h.mount(tester);
    await tester.tap(find.text('Play selected item'));
    await tester.runAsync(() async => expect(await h.operation, isTrue));
    await tester.pumpAndSettle();
    expect(h.events, ['library']);
    await tester.tap(find.text('Simulate library failure'));
    await _until(tester, () => h.players.length == 2);
    await tester.pumpAndSettle();
    expect(await h.fallback, isTrue);
    expect(h.events.where((event) => event == 'library'), hasLength(1));
    expect(h.events, containsAll(['indexer', 'cache', 'RD', 'native']));
    expect(h.players.last.directVideoUrl, isNotNull);
    expect(find.text('Race player'), findsOneWidget);
    h.players.last.onDirectPlaybackStarted!();
    await h.close(tester);
  });
}
