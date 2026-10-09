import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/beam/beam_fallback.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/prefs.dart';

const _first = BeamEpisodeIdentity(showId: 'pioneer', showTitle: 'Pioneer One', year: 2010, season: 1, episode: 1);
const _second = BeamEpisodeIdentity(showId: 'pioneer', showTitle: 'Pioneer One', year: 2010, season: 1, episode: 2);

class _Player implements Player {
  @override
  PlayerState get state => const PlayerState(duration: Duration(minutes: 20), seekable: true);
  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {}
  @override
  Future<void> pause() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 80 && !condition(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(condition(), isTrue);
}

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SharedPreferences.setMockInitialValues({'beam_rd_token': 'fixture'});
    SettingsService.resetForTesting();
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.autoPlayNextEpisode, true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
  });
  tearDown(() {
    BeamFallback.libraryLookupOverride = null;
    BeamFallback.searchOverride = null;
    BeamFallback.cachedSourcesOverride = null;
    BeamFallback.playServiceOverride = null;
    BeamFallback.playerWrapper = null;
  });

  for (final direct in [false, true]) {
    testWidgets(
      '${direct ? "direct single file" : "owned paired file"} preserves the correct mixed-queue next episode',
      (tester) async {
        final nativeInitialize = Completer<bool>();
        final key = GlobalKey<VideoPlayerScreenState>();
        MediaItem item(BeamEpisodeIdentity identity, String part) => identity.playerMetadata.copyWith(
          serverId: 'library',
          mediaVersions: [
            MediaVersion(
              id: part,
              parts: [MediaPart(id: part, file: '/tv/E1-E2.mkv')],
            ),
          ],
        );
        final current = item(_first, 'one');
        final sibling = item(_second, 'two');
        final virtual = _second.playerMetadata.copyWith(id: 'virtual-three', index: 3);
        final beam = BeamEpisodeIdentity(
          showId: _first.showId,
          showTitle: _first.showTitle,
          season: 1,
          episode: 1,
          metadata: current,
          episodeQueue: [current, sibling, virtual],
        );
        await withMockPlayerChannels(
          methodChannelName: 'com.plezy/mpv_player',
          eventChannelName: 'com.plezy/mpv_player/events',
          methodHandler: (call) => call.method == 'initialize' ? nativeInitialize.future : Future<Object?>.value(null),
          testBody: () async {
            await tester.pumpWidget(
              ChangeNotifierProvider(
                create: (_) => PlaybackStateProvider(),
                child: MaterialApp(
                  home: VideoPlayerScreen(
                    key: key,
                    metadata: current,
                    beamEpisode: beam,
                    directVideoUrl: direct ? 'https://fixture/E1-only' : null,
                  ),
                ),
              ),
            );
            final adjacent = await key.currentState!.loadEpisodeQueueForTesting();
            expect(adjacent.next, same(direct ? sibling : virtual));
            await tester.pumpWidget(const SizedBox());
            nativeInitialize.complete(true);
            await tester.pump();
          },
        );
      },
    );
  }

  testWidgets('owned player failure preserves original strict catalog story through the shared race', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final nativeInitialize = Completer<bool>();
    final key = GlobalKey<VideoPlayerScreenState>();
    final catalog = _second.playerMetadata.copyWith(title: 'The Correct Story', raw: {'beamCatalog': 'tvmaze'});
    final owned = catalog.copyWith(id: 'owned-two', serverId: 'library', raw: {});
    final beam = BeamEpisodeIdentity(
      showId: _second.showId,
      showTitle: _second.showTitle,
      season: 1,
      episode: 2,
      metadata: catalog,
      episodeQueue: [catalog, _second.playerMetadata.copyWith(index: 3)],
    );
    final pendingNative = Completer<BeamPlayResult>();
    var rdCalls = 0;
    var nativeCalls = 0;
    var libraryLookups = 0;
    VideoPlayerScreen? launched;
    BeamFallback.libraryLookupOverride = (_, _, _, _) async {
      libraryLookups++;
      return owned;
    };
    BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
    final source = ProwlarrResult.fromJson({
      'title': 'Pioneer.One.S01E02.720p',
      'seeders': 10,
      'guid': 'magnet:?xt=urn:btih:${'1'.padLeft(40, '0')}',
    });
    BeamFallback.searchOverride = (_, _) async => [source];
    BeamFallback.playServiceOverride = BeamPlayService(
      realDebrid: (candidate, _, _, _) async {
        rdCalls++;
        return BeamPlayResult(
          url: 'https://fixture/wrong-story',
          winner: BeamPlayWinner.realDebrid,
          magnet: candidate.magnetUrl!,
          selectedFilename: 'Pioneer.One.S01E02.mp4',
        );
      },
      torrent: (_, _, _, cancellation) {
        nativeCalls++;
        return cancellation.bind(pendingNative.future);
      },
    );
    BeamFallback.playerWrapper = (player) {
      launched = player;
      return const Scaffold(body: Text('Strict story player'));
    };
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) => call.method == 'initialize' ? nativeInitialize.future : Future<Object?>.value(null),
      testBody: () async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              Provider<AppDatabase>.value(value: db),
              ChangeNotifierProvider(create: (_) => PlaybackStateProvider()),
            ],
            child: MaterialApp(
              home: VideoPlayerScreen(key: key, metadata: owned, beamEpisode: beam),
            ),
          ),
        );
        final operation = key.currentState!.recoverFailedPlaybackForTesting();
        await _until(tester, () => rdCalls == 1 && nativeCalls == 1);
        await tester.pump();
        expect(
          launched,
          isNull,
          reason: 'A generic numbered file must still fail the original catalog story constraint.',
        );
        expect(libraryLookups, 0);
        pendingNative.complete(
          BeamPlayResult(
            url: 'https://fixture/correct-story',
            winner: BeamPlayWinner.torrent,
            magnet: source.magnetUrl!,
            selectedFilename: 'Pioneer.One.S01E02.The.Correct.Story.mp4',
          ),
        );
        await tester.runAsync(() => operation);
        await tester.pump(const Duration(milliseconds: 400));
        expect(launched?.beamEpisode?.storyConstraint?.title, 'The Correct Story');
        expect(launched?.beamEpisode?.episodeQueue.length, 2);
        expect(launched?.directVideoUrl, 'https://fixture/correct-story');
        await tester.pumpWidget(const SizedBox());
        nativeInitialize.complete(true);
        await tester.pump();
      },
    );
    await tester.runAsync(db.close);
  });

  for (final owned in [false, true]) {
    testWidgets(
      '${owned ? "failed owned next" : "direct next"} EOF countdown uses shared race and first-frame ownership',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final nativeInitialize = Completer<bool>();
        final key = GlobalKey<VideoPlayerScreenState>();
        final navigator = GlobalKey<NavigatorState>();
        final next = owned
            ? _second.playerMetadata.copyWith(serverId: 'server', id: 'owned-2')
            : _second.playerMetadata;
        final current = owned
            ? _first.playerMetadata.copyWith(serverId: 'server', id: 'owned-1')
            : _first.playerMetadata;
        final beam = BeamEpisodeIdentity(
          showId: _first.showId,
          showTitle: _first.showTitle,
          year: 2010,
          season: 1,
          episode: 1,
          metadata: current,
          episodeQueue: [current, next],
        );
        var libraryLookups = 0;
        final launched = <VideoPlayerScreen>[];
        final owners = <BeamCancellation>[];
        final pending = <Completer<BeamPlayResult>>[];
        BeamFallback.libraryLookupOverride = (_, _, metadata, episode) async {
          libraryLookups++;
          expectSync(episode?.episode, 2);
          return null;
        };
        BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
        BeamFallback.searchOverride = (_, _) async => [
          for (var i = 1; i <= 2; i++)
            ProwlarrResult.fromJson({
              'title': 'Pioneer.One.S01E02.720p',
              'seeders': 10,
              'guid': 'magnet:?xt=urn:btih:${i.toString().padLeft(40, '0')}',
            }),
        ];
        Future<BeamPlayResult> leg(ProwlarrResult candidate, int? season, int? episode, BeamCancellation cancellation) {
          expectSync((season, episode), (1, 2));
          owners.add(cancellation);
          final result = Completer<BeamPlayResult>();
          pending.add(result);
          return cancellation.bind(result.future);
        }

        BeamFallback.playServiceOverride = BeamPlayService(realDebrid: leg, torrent: leg);
        BeamFallback.playerWrapper = (player) {
          launched.add(player);
          return const Scaffold(body: Text('Autoplay race player'));
        };
        await withMockPlayerChannels(
          methodChannelName: 'com.plezy/mpv_player',
          eventChannelName: 'com.plezy/mpv_player/events',
          methodHandler: (call) => call.method == 'initialize' ? nativeInitialize.future : Future<Object?>.value(null),
          testBody: () async {
            await tester.pumpWidget(
              MultiProvider(
                providers: [
                  Provider<AppDatabase>.value(value: db),
                  ChangeNotifierProvider(create: (_) => PlaybackStateProvider()),
                ],
                child: MaterialApp(
                  navigatorKey: navigator,
                  home: owned
                      ? VideoPlayerScreen(key: key, metadata: current)
                      : VideoPlayerScreen(
                          key: key,
                          metadata: current,
                          directVideoUrl: 'https://fixture/first',
                          beamEpisode: beam,
                        ),
                ),
              ),
            );
            await tester.pump();
            key.currentState!.player = _Player();
            key.currentState!.completeEpisodeForTesting(next);
            await tester.pump();
            await tester.pump(const Duration(seconds: 4));
            expect(owners, isEmpty, reason: 'Autoplay must respect its normal five-second countdown.');
            await tester.pump(const Duration(seconds: 1));
            await _until(tester, () => owners.length == 4);
            expect(
              libraryLookups,
              owned ? 0 : 1,
              reason: 'A failed next library reload must not reopen that library item.',
            );
            expect(launched, isEmpty);
            expect(owners.every((owner) => !owner.isCancelled), isTrue);
            pending.first.complete(
              BeamPlayResult(
                url: 'https://fixture/second',
                winner: BeamPlayWinner.realDebrid,
                magnet: 'magnet:?xt=urn:btih:${1.toString().padLeft(40, '0')}',
                selectedFilename: 'Pioneer.One.S01E02.mp4',
              ),
            );
            await _until(tester, () => launched.isNotEmpty);
            await tester.pump(const Duration(milliseconds: 400));
            expect(launched.single.metadata.index, 2);
            expect(launched.single.metadata.parentIndex, 1);
            expect(
              owners.every((owner) => !owner.isCancelled),
              isTrue,
              reason: 'Resolving a URL and replacing the old route must retain racing losers until first frame.',
            );
            launched.single.onDirectPlaybackStarted!();
            await tester.pump();
            expect(owners.first.isCancelled, isFalse);
            expect(owners.skip(1).every((owner) => owner.isCancelled), isTrue);
            await tester.pumpWidget(const SizedBox());
            nativeInitialize.complete(true);
            await tester.pump();
          },
        );
        await tester.runAsync(db.close);
      },
    );
  }
}
