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
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/beam/beam_fallback.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';

ProwlarrResult _source(String title, int seeds) => ProwlarrResult.fromJson({
  'title': title,
  'seeders': seeds,
  'guid': 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
  });
  for (final (tv, form) in [
    (false, 'movie'),
    (true, 'episode'),
    (true, 'season pack'),
    (true, 'series pack'),
    (true, 'range pack'),
    (true, 'catalog alias'),
    (true, 'identity alias'),
    (true, 'undeclared prefix'),
  ]) {
    for (final includeCorrect in [false, true]) {
      testWidgets(
        '$form rejects unrelated high-seed source ${includeCorrect ? "and plays exact match" : "without starting any transport"}',
        (tester) async {
          final db = AppDatabase.forTesting(NativeDatabase.memory());
          final aliasCase = form.contains('alias') || form == 'undeclared prefix';
          final showTitle = aliasCase ? 'Spidey and His Amazing Friends' : 'Pioneer One';
          final requestedSeason = aliasCase ? 4 : 1;
          final requestedEpisode = aliasCase ? 14 : 2;
          final episodeMetadata = aliasCase
              ? MediaItem(
                  id: 'catalog-episode',
                  backend: MediaBackend.plex,
                  kind: MediaKind.episode,
                  title: 'Episode 14',
                  grandparentTitle: showTitle,
                  parentIndex: 4,
                  index: 14,
                  raw: form == 'undeclared prefix'
                      ? null
                      : {
                          'beamShowAliases': [null, 12, '', "Marvel's Spidey and His Amazing Friends"],
                        },
                )
              : null;
          final shouldPlay = includeCorrect && form != 'undeclared prefix';
          final correct = _source(switch (form) {
            'season pack' => 'Pioneer.One.Complete.Season.1.720p.BluRay',
            'series pack' => 'Pioneer.One.Complete.Series.720p.BluRay',
            'range pack' => 'Pioneer.One.S01-S04.720p.BluRay',
            'episode' => 'Pioneer.One.S01E02.720p.BluRay',
            'catalog alias' ||
            'identity alias' ||
            'undeclared prefix' => 'Marvels.Spidey.And.His.Amazing.Friends.S04E14.1080p.WEB.h264-DOLORES',
            _ => 'The.Butler.2013.720p.BluRay',
          }, 5);
          final unrelated = _source(
            tv ? 'Other.Show.S01E02.720p.BluRay' : '[JoyBear] Paige Turnah (Fleur distracts the butler / 12.18.2013)',
            10000,
          );
          final attempted = <String>[];
          var players = 0;
          Future<bool>? operation;
          BeamFallback.searchOverride = (query, _) async => [
            unrelated,
            if (includeCorrect &&
                (form != 'series pack' || query.endsWith('Complete')) &&
                (form != 'range pack' || query == 'Pioneer One'))
              correct,
          ];
          Future<BeamPlayResult> resolve(
            ProwlarrResult candidate,
            int? season,
            int? episode,
            dynamic cancellation,
          ) async {
            expect(season, tv ? requestedSeason : null);
            expect(episode, tv ? requestedEpisode : null);
            attempted.add(candidate.title);
            return BeamPlayResult(
              url: 'https://fixture/correct.mp4',
              winner: BeamPlayWinner.torrent,
              magnet: candidate.magnetUrl!,
            );
          }

          BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
          BeamFallback.playServiceOverride = BeamPlayService(realDebrid: resolve, torrent: resolve);
          BeamFallback.playerWrapper = (player) {
            players++;
            return const Scaffold(body: Text('Correct player'));
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
                      onPressed: () => operation = BeamFallback.playByTitle(
                        context,
                        title: tv ? showTitle : 'The Butler',
                        year: tv ? null : 2013,
                        beamEpisode: tv
                            ? BeamEpisodeIdentity(
                                showId: 'pioneer-one',
                                showTitle: showTitle,
                                season: requestedSeason,
                                episode: requestedEpisode,
                                metadata: form == 'identity alias' ? episodeMetadata : null,
                              )
                            : null,
                        metadata: tv
                            ? (form == 'identity alias' ? null : episodeMetadata)
                            : MediaItem(
                                id: 'butler',
                                backend: MediaBackend.plex,
                                kind: MediaKind.movie,
                                title: 'The Butler',
                                year: 2013,
                              ),
                      ),
                      child: const Text('Play title'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Play title'));
          await tester.runAsync(() async => expect(await operation, shouldPlay));
          await tester.pumpAndSettle();
          expect(attempted, shouldPlay ? [correct.title] : isEmpty);
          expect(players, shouldPlay ? 1 : 0);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
