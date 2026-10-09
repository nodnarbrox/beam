import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/beam/beam_fallback.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/indexer_search.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import '../test_helpers/prefs.dart';

class _Client extends MockClient {
  _Client(super.fn);
  int closes = 0;
  @override
  void close() {
    closes++;
    super.close();
  }
}

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
  });
  for (final winner in ['IMDb', 'title']) {
    testWidgets('$winner search can play while the other TV provider is stalled', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      const name = 'Pioneer.One.S01E02.The.Man.from.Mars.720p.WEB.mkv';
      const hash = '0123456789012345678901234567890123456789';
      final text = Completer<List<ProwlarrResult>>();
      final imdbResponse = Completer<http.Response>();
      final queries = <String>[];
      var imdbCalls = 0;
      final imdbQueries = <String?>[];
      var transportCalls = 0;
      BeamEpisodeIdentity? opened;
      Future<bool>? operation;
      final metadata = MediaItem(
        id: 'tvmaze:episode:902',
        backend: MediaBackend.plex,
        kind: MediaKind.episode,
        title: 'The Man from Mars',
        grandparentTitle: 'Pioneer One',
        parentIndex: 1,
        index: 2,
        year: 2010,
        raw: const {
          'beamCatalog': 'tvmaze',
          'tvmazeShowId': 900,
          'tvmazeEpisodeId': 902,
          'beamShowImdbId': 'tt1234567',
        },
      );
      final result = ProwlarrResult.fromJson({
        'title': name,
        'seeders': 5,
        'categories': [
          {'id': 5000},
        ],
        'guid': 'magnet:?xt=urn:btih:$hash',
      });
      final client = _Client((request) {
        imdbCalls++;
        imdbQueries.add(request.url.queryParameters['imdb_id']);
        return winner == 'title'
            ? imdbResponse.future
            : Future.value(
                http.Response(
                  jsonEncode({
                    'torrents_count': 2,
                    'torrents': [
                      {
                        'title': 'Wrong.Show.S01E02.720p',
                        'hash': '9999999999999999999999999999999999999999',
                        'seeds': 100,
                      },
                      {'title': name, 'hash': hash, 'seeds': 5},
                    ],
                  }),
                  200,
                ),
              );
      });
      BeamFallback.episodeIndexerOverride = EztvSource(clientFactory: () async => client);
      BeamFallback.libraryLookupOverride = (_, _, _, _) async => null;
      BeamFallback.searchOverride = (query, _) {
        queries.add(query);
        return winner == 'IMDb' ? text.future : Future.value([result]);
      };
      BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
      BeamFallback.playServiceOverride = BeamPlayService(
        torrent: (candidate, season, episode, token) async {
          transportCalls++;
          expect(candidate.title, name);
          expect((season, episode), (1, 2));
          return BeamPlayResult(
            url: 'http://127.0.0.1/fixture',
            winner: BeamPlayWinner.torrent,
            magnet: candidate.magnetUrl!,
            selectedFilename: name,
          );
        },
      );
      BeamFallback.playerWrapper = (player) {
        opened = player.beamEpisode;
        return const Scaffold(body: Text('Verified episode player'));
      };
      addTearDown(() async {
        BeamFallback.episodeIndexerOverride = null;
        BeamFallback.libraryLookupOverride = null;
        BeamFallback.searchOverride = null;
        BeamFallback.cachedSourcesOverride = null;
        BeamFallback.playServiceOverride = null;
        BeamFallback.playerWrapper = null;
        if (!text.isCompleted) text.complete([]);
        if (!imdbResponse.isCompleted) imdbResponse.complete(http.Response('{"torrents_count":0}', 200));
        await tester.runAsync(db.close);
      });
      await tester.pumpWidget(
        Provider.value(
          value: db,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      operation = BeamFallback.playByTitle(context, title: 'Pioneer One', metadata: metadata),
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
      expect(find.text('Verified episode player'), findsOneWidget);
      expect(queries.length, greaterThanOrEqualTo(5));
      expect(queries.any((query) => query.startsWith('tt')), isFalse);
      expect(imdbCalls, 1, reason: 'Only one IMDb request alongside all text/pack variants');
      expect(imdbQueries, ['1234567']);
      expect(transportCalls, 1);
      expect(opened?.verifiedShowImdbId, 'tt1234567');
      expect(opened?.storyConstraint, isNotNull);
      expect((opened?.season, opened?.episode), (1, 2));
      expect(client.closes, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
    });
  }
}
