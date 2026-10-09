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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
  });
  final movie = MediaItem(
    id: 'library-movie-42',
    backend: MediaBackend.plex,
    serverId: 'real-library-server',
    kind: MediaKind.movie,
    title: 'The Peanut Butter Falcon',
    year: 2019,
    thumbPath: '/library/metadata/42/thumb',
    artPath: '/library/metadata/42/art',
  );

  test('direct playback preserves supplied movie identity and episode identity takes precedence', () {
    final direct = VideoPlayerScreen.direct(
      url: 'https://fixture/movie.mp4',
      title: 'raw.release.name.1080p',
      metadata: movie,
      beamInfoHash: 'transport-hash',
    );
    expect(direct.metadata, same(movie));
    expect(direct.beamContentKey, 'transport-hash');
    const episode = BeamEpisodeIdentity(showId: 'pioneer-one', showTitle: 'Pioneer One', season: 1, episode: 2);
    final tv = VideoPlayerScreen.direct(
      url: 'https://fixture/episode.mp4',
      metadata: movie,
      beamEpisode: episode,
      beamInfoHash: 'pack-hash',
    );
    expect(tv.metadata.kind, MediaKind.episode);
    expect(tv.metadata.index, 2);
    expect(tv.beamContentKey, episode.contentKey);
  });

  testWidgets('movie fallback retains selected title, year, art, real identity and transport resume', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final source = ProwlarrResult.fromJson({
      'title': 'The.Peanut.Butter.Falcon.2019.720p.BluRay.x264-GROUP',
      'seeders': 10,
      'guid': 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
    });
    final library = BeamLibraryService(db);
    await tester.runAsync(
      () => library.saveProgress(infoHash: source.infoHash!, positionMs: 15000, durationMs: 100000),
    );
    String? searched;
    MediaKind? searchedKind;
    VideoPlayerScreen? opened;
    Future<bool>? playback;
    BeamFallback.searchOverride = (query, kind) async {
      searched = query;
      searchedKind = kind;
      return [source];
    };
    BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
    BeamFallback.playServiceOverride = BeamPlayService(
      torrent: (candidate, season, episode, cancel) async {
        expect(season, isNull);
        expect(episode, isNull);
        return BeamPlayResult(
          url: 'https://fixture/movie.mp4',
          winner: BeamPlayWinner.torrent,
          magnet: candidate.magnetUrl!,
        );
      },
    );
    BeamFallback.playerWrapper = (player) {
      opened = player;
      return const Scaffold(body: Text('Movie playing'));
    };
    addTearDown(() async {
      BeamFallback.searchOverride = null;
      BeamFallback.playServiceOverride = null;
      BeamFallback.cachedSourcesOverride = null;
      BeamFallback.playerWrapper = null;
      await tester.runAsync(db.close);
    });
    await tester.pumpWidget(
      Provider.value(
        value: db,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => playback = BeamFallback.playByTitle(
                  context,
                  title: movie.title!,
                  year: movie.year,
                  kind: movie.kind,
                  metadata: movie,
                ),
                child: const Text('Play'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Play'));
    await tester.runAsync(() async => expect(await playback, isTrue));
    await tester.pumpAndSettle();
    expect(searched, 'The Peanut Butter Falcon 2019');
    expect(searchedKind, MediaKind.movie);
    expect(opened!.metadata, same(movie));
    expect(opened!.metadata.year, 2019);
    expect(opened!.metadata.artPath, movie.artPath);
    expect(opened!.metadata.serverId, 'real-library-server');
    expect(opened!.beamResumeMs, 15000);
    expect(opened!.beamContentKey, source.infoHash);
    expect(opened!.directVideoUrl, 'https://fixture/movie.mp4');
    final entries = (await tester.runAsync(library.recentlyPlayed))!;
    expect(entries.single.title, 'The Peanut Butter Falcon');
    expect(entries.single.posterUrl, movie.thumbPath);
    expect(entries.single.item.sourceInfoHash, source.infoHash);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
