import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/models/catalog/catalog_item.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/beam/beam_library_resolver.dart';
import 'package:plezy/utils/external_ids.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;

class _Provider implements MultiServerProvider {
  _Provider(this.clients, {List<String>? visible}) : onlineServerIds = visible ?? clients.keys.toList();
  final Map<String, MediaServerClient> clients;
  @override
  final List<String> onlineServerIds;
  @override
  MediaServerClient? getClientForServer(ServerId id) => clients[id];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements MediaServerClient {
  _Client(String id) : serverId = ServerId(id);
  @override
  final ServerId serverId;
  @override
  final backend = MediaBackend.plex;
  @override
  bool isOfflineMode = false;
  List<MediaItem> results = [];
  final children = <String, List<MediaItem>>{};
  final fetched = <String>[];
  MediaItem? externalMatch;
  ExternalIds? requestedIds;
  String? requestedPlexGuid;
  int searches = 0;
  bool unavailable = false;
  Completer<List<MediaItem>>? searchGate;
  AbortController? searchAbort;
  @override
  Future<List<MediaItem>> searchItems(String query, {int limit = 100, AbortController? abort}) async {
    searches++;
    searchAbort = abort;
    if (unavailable) throw StateError('server unavailable');
    return searchGate?.future ?? results;
  }

  @override
  Future<MediaItem?> findByExternalIds(
    ExternalIds ids, {
    required MediaKind kind,
    List<String> titles = const [],
    int? year,
    String? plexGuid,
    ExternalSeasonRef? season,
  }) async {
    requestedIds = ids;
    requestedPlexGuid = plexGuid;
    return externalMatch;
  }

  @override
  Future<List<MediaItem>> fetchChildren(String id) async {
    fetched.add(id);
    if (unavailable) throw StateError('server unavailable');
    return children[id] ?? [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaItem item(
  String id,
  MediaKind kind,
  String title, {
  String server = 'a',
  int? year,
  int? season,
  int? number,
  String? parent,
  String? show,
  Map<String, dynamic>? raw,
}) => MediaItem(
  id: id,
  backend: MediaBackend.plex,
  kind: kind,
  title: title,
  serverId: server,
  year: year,
  parentIndex: season,
  index: number,
  parentId: parent,
  grandparentId: show,
  grandparentTitle: kind == MediaKind.episode ? 'Pioneer One' : null,
  raw: raw,
);

BeamEpisodeIdentity requested({String title = 'The Man from Mars', List<MediaItem> queue = const []}) =>
    BeamEpisodeIdentity(
      showId: 'catalog-show',
      showTitle: 'Pioneer One',
      year: 2010,
      season: 1,
      episode: 2,
      episodeQueue: queue,
      metadata: MediaItem(
        id: 'tvmaze:episode:52',
        backend: MediaBackend.plex,
        kind: MediaKind.episode,
        title: title,
        year: 2010,
        parentIndex: 1,
        index: 2,
        grandparentId: 'catalog-show',
        grandparentTitle: 'Pioneer One',
        raw: const {'beamCatalog': 'tvmaze', 'tvmazeShowId': 7, 'tvmazeEpisodeId': 52},
      ),
    );

_Client _episodeClient() {
  final client = _Client('a');
  client.results = [item('show', MediaKind.show, 'Pioneer One', year: 2010)];
  client.children['show'] = [
    item('season1', MediaKind.season, 'Season 1', number: 1, parent: 'show'),
    item('season2', MediaKind.season, 'Season 2', number: 2, parent: 'show'),
  ];
  client.children['season1'] = [
    item('episode1', MediaKind.episode, 'Earthfall', season: 1, number: 1, parent: 'season1', show: 'show'),
    item('episode2', MediaKind.episode, 'The Man from Mars', season: 1, number: 2, parent: 'season1', show: 'show'),
  ];
  return client;
}

void main() {
  test('movie title/year lookup accepts punctuation but rejects remake, embedded title and wrong kind', () async {
    final client = _Client('a')
      ..results = [
        item('remake', MediaKind.movie, 'The Butler', year: 2020),
        item('embedded', MediaKind.movie, 'Fleur Distracts the Butler', year: 2013),
        item('show', MediaKind.show, 'The Butler', year: 2013),
        item('correct', MediaKind.movie, 'The Butler', year: 2013),
      ];
    final result = await BeamLibraryResolver(_Provider({'a': client})).resolve(title: 'The.Butler', year: 2013);
    expect(result, same(client.results.last));
    expect(client.fetched, isEmpty);
  });

  test('same-title remakes without a known year are ambiguous', () async {
    final client = _Client('a')
      ..results = [
        item('first', MediaKind.movie, 'The Thing', year: 1982),
        item('second', MediaKind.movie, 'The Thing', year: 2011),
      ];
    expect(await BeamLibraryResolver(_Provider({'a': client})).resolve(title: 'The Thing'), isNull);
  });

  test('catalog external IDs use existing verified lookup and retain real server metadata', () async {
    final client = _Client('a')..externalMatch = item('library', MediaKind.movie, 'Localized Title', year: 2014);
    final metadata = const CatalogItem(
      source: CatalogSourceId.trakt,
      kind: MediaKind.movie,
      title: 'Original Title',
      year: 2013,
      ids: CatalogItemIds(imdb: 'tt1234567'),
    ).toMediaItem();
    final found = await BeamLibraryResolver(
      _Provider({'a': client}),
    ).resolve(title: 'Original Title', metadata: metadata);
    expect(client.requestedIds?.imdb, 'tt1234567');
    expect(client.searches, 0);
    expect(found, same(client.externalMatch));
  });

  test('Plex catalog ID is passed as a primary GUID', () async {
    final client = _Client('a')..externalMatch = item('library', MediaKind.movie, 'Pioneer Movie', year: 2020);
    final metadata = const CatalogItem(
      source: CatalogSourceId.plex,
      kind: MediaKind.movie,
      title: 'Pioneer Movie',
      ids: CatalogItemIds(plex: 'catalog123'),
    ).toMediaItem();
    expect(
      await BeamLibraryResolver(_Provider({'a': client})).resolve(title: 'Pioneer Movie', metadata: metadata),
      isNotNull,
    );
    expect(client.requestedPlexGuid, 'plex://movie/catalog123');
    expect(client.searches, 0);
  });

  test('conflicting external IDs cannot fall through to a title-only false match', () async {
    final client = _Client('a')
      ..results = [
        item(
          'wrong',
          MediaKind.movie,
          'Pioneer Movie',
          year: 2020,
          raw: {
            'Guid': [
              {'id': 'imdb://tt9999999'},
            ],
          },
        ),
      ];
    final metadata = const CatalogItem(
      source: CatalogSourceId.trakt,
      kind: MediaKind.movie,
      title: 'Pioneer Movie',
      year: 2020,
      ids: CatalogItemIds(imdb: 'tt1234567'),
    ).toMediaItem();
    expect(
      await BeamLibraryResolver(_Provider({'a': client})).resolve(title: 'Pioneer Movie', metadata: metadata),
      isNull,
    );
  });

  test('hidden, offline and foreign-server rows cannot become library matches', () async {
    final visible = _Client('a')
      ..results = [item('foreign', MediaKind.movie, 'Pioneer Movie', year: 2020, server: 'b')];
    final hidden = _Client('b')..results = [item('hidden', MediaKind.movie, 'Pioneer Movie', year: 2020, server: 'b')];
    final offline = _Client('c')..isOfflineMode = true;
    final resolver = BeamLibraryResolver(_Provider({'a': visible, 'b': hidden, 'c': offline}, visible: ['a', 'c']));
    expect(await resolver.resolve(title: 'Pioneer Movie', year: 2020), isNull);
    expect(hidden.searches, 0);
    expect(offline.searches, 0);
  });

  test('unavailable server does not hide the exact match on another visible server', () async {
    final missing = _Client('a')..unavailable = true;
    final live = _Client('b')..results = [item('movie', MediaKind.movie, 'Pioneer Movie', year: 2020, server: 'b')];
    expect(
      await BeamLibraryResolver(_Provider({'a': missing, 'b': live})).resolve(title: 'Pioneer Movie', year: 2020),
      same(live.results.single),
    );
  });

  test('episode lookup fetches only the requested season and returns real episode identity', () async {
    final client = _episodeClient();
    final found = await BeamLibraryResolver(
      _Provider({'a': client}),
    ).resolve(title: 'Pioneer One', episode: requested());
    expect(found, same(client.children['season1']!.last));
    expect(client.fetched, ['show', 'season1']);
  });

  for (final field in ['story', 'parent', 'show', 'season', 'number', 'server']) {
    test('same-coordinate episode with wrong $field cannot satisfy the request', () async {
      final client = _episodeClient();
      final correct = client.children['season1']!.last;
      client.children['season1'] = [
        switch (field) {
          'story' => correct.copyWith(title: 'A Different Story'),
          'parent' => correct.copyWith(parentId: 'other-season'),
          'show' => correct.copyWith(grandparentId: 'other-show'),
          'season' => correct.copyWith(parentIndex: 2),
          'number' => correct.copyWith(index: 3),
          _ => correct.copyWith(serverId: 'other-server'),
        },
      ];
      expect(
        await BeamLibraryResolver(_Provider({'a': client})).resolve(title: 'Pioneer One', episode: requested()),
        isNull,
      );
    });
  }

  test('different catalog story at another season coordinate blocks unsafe numbering reuse', () async {
    final client = _episodeClient();
    final anchor = requested().metadata!.copyWith(index: 1, title: 'Split story one');
    expect(
      await BeamLibraryResolver(_Provider({'a': client})).resolve(
        title: 'Pioneer One',
        episode: requested(queue: [anchor]),
      ),
      isNull,
    );
  });

  test('generic library episode title needs verified numbering rather than guessed catalog coordinates', () async {
    final client = _episodeClient();
    client.children['season1'] = [client.children['season1']!.last.copyWith(title: 'Episode 2')];
    expect(
      await BeamLibraryResolver(_Provider({'a': client})).resolve(title: 'Pioneer One', episode: requested()),
      isNull,
    );
  });

  test('show remake year must match, but genuine episode air year is not the show year', () async {
    final client = _episodeClient();
    client.results = [client.results.single.copyWith(year: 2026)];
    final resolver = BeamLibraryResolver(_Provider({'a': client}));
    expect(await resolver.resolve(title: 'Pioneer One', episode: requested()), isNull);
    client.results = [client.results.single.copyWith(year: 2010)];
    final actual = client.children['season1']!.last.copyWith(year: 2026);
    expect(await resolver.resolve(title: 'Pioneer One', year: 2026, metadata: actual), isNotNull);
  });

  test('verified catalog copies on two servers choose an existing library copy', () async {
    final a = _Client('a')..externalMatch = item('a-movie', MediaKind.movie, 'Localized A');
    final b = _Client('b')..externalMatch = item('b-movie', MediaKind.movie, 'Localized B', server: 'b');
    final metadata = const CatalogItem(
      source: CatalogSourceId.trakt,
      kind: MediaKind.movie,
      title: 'Original',
      ids: CatalogItemIds(imdb: 'tt1234567'),
    ).toMediaItem();
    expect(
      await BeamLibraryResolver(_Provider({'a': a, 'b': b})).resolve(title: 'Original', metadata: metadata),
      same(a.externalMatch),
    );
  });

  test('exact title and known year permit duplicate editions and servers', () async {
    final a = _Client('a')
      ..results = [
        item('edition1', MediaKind.movie, 'The Butler', year: 2013),
        item('edition2', MediaKind.movie, 'The Butler', year: 2013),
      ];
    final b = _Client('b')..results = [item('b-movie', MediaKind.movie, 'The Butler', year: 2013, server: 'b')];
    final resolver = BeamLibraryResolver(_Provider({'a': a, 'b': b}));
    expect(await resolver.resolve(title: 'The Butler', year: 2013), same(a.results.first));
    expect(await resolver.resolve(title: 'The Butler', year: 2013, metadata: b.results.single), same(b.results.single));
  });

  test('unknown-year remakes across servers still fail closed', () async {
    final a = _Client('a')..results = [item('old', MediaKind.movie, 'The Thing', year: 1982)];
    final b = _Client('b')..results = [item('new', MediaKind.movie, 'The Thing', year: 2011, server: 'b')];
    expect(await BeamLibraryResolver(_Provider({'a': a, 'b': b})).resolve(title: 'The Thing'), isNull);
  });

  test('same title and year with conflicting IDs remain ambiguous', () async {
    final a = _Client('a')
      ..results = [
        item(
          'one',
          MediaKind.movie,
          'Movie',
          year: 2020,
          raw: {
            'Guid': [
              {'id': 'imdb://tt1111111'},
            ],
          },
        ),
        item(
          'two',
          MediaKind.movie,
          'Movie',
          year: 2020,
          raw: {
            'Guid': [
              {'id': 'imdb://tt2222222'},
            ],
          },
        ),
      ];
    expect(await BeamLibraryResolver(_Provider({'a': a})).resolve(title: 'Movie', year: 2020), isNull);
  });

  test('canonical parent show ID drives episode lookup without using episode IDs', () async {
    final client = _episodeClient();
    client.externalMatch = client.results.single;
    final episode = BeamEpisodeIdentity(showId: 'imdb:tt1748166', showTitle: 'Pioneer One', season: 1, episode: 2);
    expect(
      await BeamLibraryResolver(_Provider({'a': client})).resolve(title: 'Pioneer One', episode: episode),
      isNotNull,
    );
    expect(client.requestedIds?.imdb, 'tt1748166');
    expect(client.searches, 0);
    expect(client.fetched, ['show', 'season1']);
  });

  test('timed-out search cannot issue late child lookups', () async {
    final client = _episodeClient()..searchGate = Completer<List<MediaItem>>();
    final resolver = BeamLibraryResolver(_Provider({'a': client}), timeout: const Duration(milliseconds: 10));
    expect(await resolver.resolve(title: 'Pioneer One', episode: requested()), isNull);
    client.searchGate!.complete(client.results);
    await Future<void>.delayed(Duration.zero);
    expect(client.fetched, isEmpty);
  });
}
