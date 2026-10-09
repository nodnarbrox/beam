import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/beam/plex_episode_artwork.dart';
import 'package:plezy/services/beam/show_episode_catalog.dart';
import 'package:plezy/services/plex_discover_client.dart';

const _image = 'https://image.tmdb.org/t/p/original/episode.jpg';
const _episode = ShowCatalogEpisode(
  id: 901,
  seasonNumber: 9,
  episodeNumber: 1,
  name: 'Lordy Lordy Look Who’s Forty',
  airdate: '2026-05-07',
  sourceUrl: 'https://tvmaze.com/episodes/901',
);
ShowEpisodeCatalogResult _catalog({
  List<ShowCatalogEpisode> episodes = const [_episode],
  String? imdbId = 'tt7686456',
  String? premiered = '2018-04-05',
}) => ShowEpisodeCatalogResult(
  tvmazeId: 123,
  name: 'Jersey Shore Family Vacation',
  premiered: premiered,
  imdbId: imdbId,
  sourceUrl: 'https://tvmaze.com/shows/123',
  episodes: episodes,
);

class _Fixture {
  final paths = <String>[];
  final show = <String, dynamic>{
    'ratingKey': 'show',
    'type': 'show',
    'title': 'Jersey Shore Family Vacation',
    'year': 2018,
  };
  List<Map<String, dynamic>> seasons = [
    {'ratingKey': 's8', 'type': 'season', 'index': 8, 'parentRatingKey': 'show'},
    {'ratingKey': 's9', 'type': 'season', 'index': 9, 'parentRatingKey': 'show'},
  ];
  final rows = <String, List<Map<String, dynamic>>>{};
  int status = 200;
  String? failPath;
  bool matchMissing = false;
  List<Map<String, dynamic>> searchRows = [];
  Completer<http.Response>? gate;
  late final client = PlexDiscoverClient(
    const PlexDiscoverSession(accessToken: 'private', clientIdentifier: 'test'),
    httpClient: MockClient((request) async {
      expect(request.url.host, 'discover.provider.plex.tv');
      expect(request.headers['X-Plex-Token'], 'private');
      expect(request.url.queryParameters.containsKey('X-Plex-Token'), isFalse);
      paths.add(request.url.path);
      if (gate != null) return gate!.future;
      if (status != 200 || request.url.path == failPath) return http.Response('', status != 200 ? status : 500);
      if (request.url.path == '/library/search') {
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'SearchResults': [
                {
                  'SearchResult': [
                    for (final row in searchRows) {'Metadata': row},
                  ],
                },
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (matchMissing && request.url.path == '/library/metadata/matches') {
        return http.Response('{"MediaContainer":{"Metadata":[]}}', 200);
      }
      final key = request.url.path.split('/').reversed.skip(1).first;
      final items = request.url.path.endsWith('/children') ? (key == 'show' ? seasons : rows[key] ?? []) : [show];
      return http.Response(
        jsonEncode({
          'MediaContainer': {'Metadata': items, 'totalSize': items.length},
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );

  Map<String, dynamic> episode({
    String id = 'e',
    int season = 9,
    int number = 1,
    String title = 'Lordy Lordy Look Who’s Forty',
    String? date = '2026-05-07',
    String image = _image,
  }) => {
    'ratingKey': id,
    'type': 'episode',
    'parentRatingKey': 's$season',
    'grandparentRatingKey': 'show',
    'parentIndex': season,
    'index': number,
    'title': title,
    'originallyAvailableAt': ?date,
    'thumb': image,
  };
  Future<Map<int, String>> load({ShowEpisodeCatalogResult? catalog, String? showId = 'show', Duration? timeout}) =>
      PlexEpisodeArtwork(
        client,
        timeout: timeout ?? const Duration(seconds: 2),
      ).load(catalog: catalog ?? _catalog(), plexShowId: showId, seasonNumber: 9);
}

void main() {
  test('same coordinates require real story and preserve catalog identity', () async {
    final f = _Fixture();
    f.rows['s9'] = [f.episode()];
    final catalog = _catalog();
    expect(await f.load(catalog: catalog), {901: _image});
    expect(catalog.episodes.single, same(_episode));
    expect(catalog.episodes.single.seasonNumber, 9);
    expect(catalog.numberingEvidence, isEmpty);
    expect(f.paths, ['/library/metadata/show', '/library/metadata/show/children', '/library/metadata/s9/children']);
  });

  test('observed Plex season8 episode19 maps to catalog9 episode1 by exact story and date only', () async {
    final f = _Fixture();
    f.seasons.removeWhere((row) => row['index'] == 9);
    f.rows['s8'] = [f.episode(season: 8, number: 19)];
    expect(await f.load(), {901: _image});
    expect(f.paths.last, '/library/metadata/s8/children');
  });

  for (final bad in ['wrong show', 'wrong year', 'wrong ID']) {
    test('$bad cannot donate episode artwork', () async {
      final f = _Fixture();
      f.rows['s9'] = [f.episode()];
      if (bad == 'wrong show') f.show['title'] = 'Another Show';
      if (bad == 'wrong year') f.show['year'] = 2009;
      if (bad == 'wrong ID') {
        f.show['Guid'] = [
          {'id': 'imdb://tt9999999'},
        ];
      }
      expect(await f.load(), isEmpty);
      expect(f.paths.length, 1);
    });
  }

  for (final bad in ['wrong story', 'date conflict', 'invalid date', 'generic', 'foreign parent']) {
    test('$bad cannot use coincident season and episode numbers', () async {
      final f = _Fixture();
      final row = f.episode();
      switch (bad) {
        case 'wrong story':
          row['title'] = 'Lordy Lordy Look Who’s Forty and Another Story';
        case 'date conflict':
          row['originallyAvailableAt'] = '2026-05-08';
        case 'invalid date':
          row['originallyAvailableAt'] = '2026-02-31';
        case 'generic':
          row['title'] = 'Episode 1';
        case 'foreign parent':
          row['grandparentRatingKey'] = 'unrelated';
      }
      f.rows['s9'] = [row];
      expect(await f.load(), isEmpty);
    });
  }

  test('cross-number mapping needs airdate, both-side uniqueness, and one row per story', () async {
    final f = _Fixture();
    f.rows['s8'] = [f.episode(season: 8, number: 19, date: null)];
    expect(await f.load(), isEmpty);
    f.rows['s8'] = [f.episode(season: 8, number: 19), f.episode(id: 'duplicate', season: 8, number: 20)];
    expect(await f.load(), isEmpty);
    f.rows['s8'] = [f.episode(season: 8, number: 19)];
    const other = ShowCatalogEpisode(
      id: 902,
      seasonNumber: 9,
      episodeNumber: 2,
      name: 'Lordy Lordy Look Who’s Forty',
      airdate: '2026-05-07',
      sourceUrl: 'unused',
    );
    expect(await f.load(catalog: _catalog(episodes: [_episode, other])), isEmpty);
  });

  for (final fail in [true, false]) {
    test('cross-number result is withheld when next neighbor ${fail ? 'fails' : 'duplicates the story'}', () async {
      final f = _Fixture();
      f.seasons.add({'ratingKey': 's10', 'type': 'season', 'index': 10, 'parentRatingKey': 'show'});
      f.rows['s8'] = [f.episode(season: 8, number: 19)];
      if (fail) {
        f.failPath = '/library/metadata/s10/children';
      } else {
        f.rows['s10'] = [f.episode(id: 'later', season: 10, number: 1)];
      }
      expect(await f.load(), isEmpty);
      expect(f.paths.last, '/library/metadata/s10/children');
    });
  }

  for (final variant in [
    'correct',
    'wrong part',
    'wrong date',
    'missing date',
    'missing catalog date',
    'generic',
    'embedded',
  ]) {
    test('trailing part artwork alias $variant preserves exact story part and date', () async {
      final f = _Fixture();
      final requestedTitle = variant == 'generic' ? 'Part 1' : 'Reunion Part 1';
      final episode = ShowCatalogEpisode(
        id: 917,
        seasonNumber: 9,
        episodeNumber: 17,
        name: requestedTitle,
        airdate: variant == 'missing catalog date' ? null : '2026-05-07',
        sourceUrl: 'unused',
      );
      final title = switch (variant) {
        'wrong part' => 'Reunion (2)',
        'generic' => 'Episode 1',
        'embedded' => 'A Different Reunion (1)',
        _ => 'Reunion (1)',
      };
      f.rows['s9'] = [
        f.episode(
          number: 17,
          title: title,
          date: variant == 'missing date'
              ? null
              : variant == 'wrong date'
              ? '2026-05-08'
              : '2026-05-07',
        ),
      ];
      expect(await f.load(catalog: _catalog(episodes: [episode])), variant == 'correct' ? {917: _image} : isEmpty);
      expect(episode.name, requestedTitle);
      expect(episode.episodeNumber, 17);
    });
  }

  for (final duplicate in [false, true]) {
    test(
      'cross-number part alias ${duplicate ? 'rejects duplicate catalog identity' : 'requires unique full story and date'}',
      () async {
        final f = _Fixture();
        const episode = ShowCatalogEpisode(
          id: 917,
          seasonNumber: 9,
          episodeNumber: 17,
          name: 'Reunion Part 1',
          airdate: '2026-05-07',
          sourceUrl: 'unused',
        );
        const second = ShowCatalogEpisode(
          id: 918,
          seasonNumber: 9,
          episodeNumber: 18,
          name: 'Reunion (1)',
          airdate: '2026-05-07',
          sourceUrl: 'unused',
        );
        f.rows['s8'] = [f.episode(season: 8, number: 35, title: 'Reunion (1)')];
        expect(
          await f.load(catalog: _catalog(episodes: [episode, if (duplicate) second])),
          duplicate ? isEmpty : {917: _image},
        );
      },
    );
  }

  for (final hasIds in [true, false]) {
    test('absent Plex ID resolves unique exact title/year search after missing match (external IDs $hasIds)', () async {
      final f = _Fixture()..matchMissing = true;
      f.searchRows = [Map.of(f.show)];
      f.rows['s9'] = [f.episode()];
      expect(await f.load(showId: null, catalog: _catalog(imdbId: hasIds ? 'tt7686456' : null)), {901: _image});
      expect(f.paths, contains('/library/search'));
      expect(f.paths.indexOf('/library/metadata/show'), lessThan(f.paths.indexOf('/library/metadata/show/children')));
    });
  }

  for (final bad in ['ambiguous', 'wrong year', 'wrong type', 'unknown year', 'changed metadata', 'conflicting IDs']) {
    test('title search fallback rejects $bad before episode traversal', () async {
      final f = _Fixture()..matchMissing = true;
      f.searchRows = [Map.of(f.show)];
      if (bad == 'ambiguous') f.searchRows.add({...f.show, 'ratingKey': 'duplicate'});
      if (bad == 'wrong year') f.searchRows.single['year'] = 2020;
      if (bad == 'wrong type') f.searchRows.single['type'] = 'movie';
      if (bad == 'changed metadata') f.show['title'] = 'Another series';
      if (bad == 'conflicting IDs') {
        f.show['Guid'] = [
          {'id': 'imdb://tt9999999'},
        ];
      }
      f.rows['s9'] = [f.episode()];
      expect(
        await f.load(showId: null, catalog: _catalog(premiered: bad == 'unknown year' ? null : '2018-04-05')),
        isEmpty,
      );
      expect(f.paths.where((path) => path.endsWith('/children')), isEmpty);
    });
  }

  test('external ID match verifies parent before reading children', () async {
    final f = _Fixture();
    f.show['title'] = 'Localized name';
    f.rows['s9'] = [f.episode()];
    expect(await f.load(showId: null), {901: _image});
    expect(f.paths.first, '/library/metadata/matches');
  });

  for (final image in [
    '/library/metadata/1/thumb',
    'http://image.tmdb.org/a',
    'https://localhost/a',
    'https://image.tmdb.org.evil.example/a',
    'https://metadata-static.plex.tv/a?X-Plex-Token=secret',
    'https://secret@image.tmdb.org/a',
  ]) {
    test('unsafe image is not exported: $image', () async {
      final f = _Fixture();
      f.rows['s9'] = [f.episode(image: image)];
      expect(await f.load(), isEmpty);
    });
  }

  for (final status in [401, 404, 500]) {
    test('HTTP $status remains best effort', () async {
      final f = _Fixture()..status = status;
      expect(await f.load(), isEmpty);
    });
  }

  test('total deadline prevents late traversal after stalled parent lookup', () async {
    final f = _Fixture()..gate = Completer<http.Response>();
    expect(await f.load(timeout: const Duration(milliseconds: 5)), isEmpty);
    f.gate!.complete(
      http.Response(
        jsonEncode({
          'MediaContainer': {
            'Metadata': [f.show],
          },
        }),
        200,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(f.paths.length, 1);
  });

  test('children preserve authentication and bound pagination', () async {
    final requests = <http.Request>[];
    final client = PlexDiscoverClient(
      const PlexDiscoverSession(accessToken: 'private', clientIdentifier: 'test'),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'MediaContainer': {
              'Metadata': [
                {'ratingKey': '1'},
              ],
              'totalSize': 501,
            },
          }),
          200,
        );
      }),
    );
    final page = await client.getChildren('show', page: 2, limit: 9999);
    expect(requests.single.url.queryParameters['X-Plex-Container-Start'], '500');
    expect(requests.single.url.queryParameters['X-Plex-Container-Size'], '500');
    expect(requests.single.headers['X-Plex-Token'], 'private');
    expect(page.hasMore, isFalse);
    expect(page.totalResults, 501);
  });
}
