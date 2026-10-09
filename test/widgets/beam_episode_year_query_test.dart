import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/beam/beam_fallback.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/episode_source_probe.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
  });

  test('known year adds two qualified queries and at most one article variant; unknown year keeps original five', () {
    final original = EpisodeSourceProbe.queries("The 'Burbs", 1, 2);
    expect(original, [
      "The 'Burbs S01E02",
      "The 'Burbs S01",
      "The 'Burbs Season 1",
      "The 'Burbs Complete",
      "The 'Burbs",
    ]);
    for (final title in ["The 'Burbs", 'The \u2019Burbs', 'The \u2018Burbs']) {
      final queries = EpisodeSourceProbe.queries(title, 1, 2, year: 2026);
      expect(queries, hasLength(8));
      expect(queries.skip(5), ['The Burbs 2026 S01E02', 'The Burbs 2026 S01', 'Burbs']);
    }
    expect(EpisodeSourceProbe.queries("The 'Burbs", 1, 2, year: 0), original);
    expect(EpisodeSourceProbe.queries('Theater Stars', 1, 2, year: 2026), hasLength(7));
    expect(EpisodeSourceProbe.queries('The A Team', 1, 2, year: 2026).last, 'A Team');
  });

  for (final yearFrom in ['argument', 'metadata', 'identity', 'bare fallback']) {
    testWidgets('automatic episode Play uses known year from $yearFrom and rejects unrelated results', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      const title = "The 'Burbs";
      const correct = 'The.Burbs.2026.S01E02.Mind.Your.Own.Business.1080p.WEB.h264.mkv';
      final queries = <String>[];
      final attempted = <String>[];
      MediaItem? opened;
      Future<bool>? operation;
      final metadata = MediaItem(
        id: 'tvmaze:episode:2',
        backend: MediaBackend.plex,
        kind: MediaKind.episode,
        title: 'Mind Your Own Business',
        grandparentTitle: title,
        parentIndex: 1,
        index: 2,
        year: yearFrom == 'metadata' ? 2026 : null,
        raw: const {'beamCatalog': 'tvmaze'},
      );
      ProwlarrResult source(String name, int category, int seeds) => ProwlarrResult.fromJson({
        'title': name,
        'seeders': seeds,
        'categories': [
          {'id': category},
        ],
        'guid': 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
      });
      BeamFallback.searchOverride = (query, kind) async {
        queries.add(query);
        expect(kind, MediaKind.episode);
        return [
          source('Run.The.Burbs.S01.Complete.1080p', 5000, 1000),
          source('The.Burbs.1989.1080p.BluRay', 2000, 1000),
          source('Another.Burbs.2026.S01E02.1080p', 5000, 1000),
          source('The.Burbs.2026.S01E03.1080p', 5000, 1000),
          if (query == (yearFrom == 'bare fallback' ? 'Burbs' : 'The Burbs 2026 S01E02')) source(correct, 5000, 7),
        ];
      };
      BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
      BeamFallback.playServiceOverride = BeamPlayService(
        torrent: (candidate, season, episode, cancellation) async {
          attempted.add(candidate.title);
          expect((season, episode), (1, 2));
          return BeamPlayResult(
            url: 'https://fixture.invalid/episode',
            winner: BeamPlayWinner.torrent,
            magnet: candidate.magnetUrl!,
            selectedFilename: correct,
          );
        },
      );
      BeamFallback.playerWrapper = (player) {
        opened = player.metadata;
        return const Scaffold(body: Text('Selected episode player'));
      };
      addTearDown(() async {
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
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => operation = BeamFallback.playByTitle(
                    context,
                    title: title,
                    year: yearFrom == 'argument' || yearFrom == 'bare fallback' ? 2026 : null,
                    metadata: metadata,
                    beamEpisode: yearFrom == 'identity'
                        ? BeamEpisodeIdentity(
                            showId: 'burbs-2026',
                            showTitle: title,
                            season: 1,
                            episode: 2,
                            year: 2026,
                            metadata: metadata,
                          )
                        : null,
                  ),
                  child: const Text('Play'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Play'));
      await tester.runAsync(() async => expect(await operation, isTrue));
      await tester.pumpAndSettle();
      expect(queries.toSet(), EpisodeSourceProbe.queries(title, 1, 2, year: 2026).toSet());
      expect(queries, hasLength(8));
      expect(attempted, [correct]);
      expect(opened?.title, 'Mind Your Own Business');
      expect(opened?.grandparentTitle, title);
      expect((opened?.parentIndex, opened?.index), (1, 2));
      expect(opened?.serverId, isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
