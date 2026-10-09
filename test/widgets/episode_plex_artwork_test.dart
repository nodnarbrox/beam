import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/providers/catalog_sources_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/media_detail_screen.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/beam/show_episode_catalog.dart';
import 'package:plezy/services/catalog/catalog_source.dart';
import 'package:plezy/services/catalog/plex_catalog_source.dart';
import 'package:plezy/services/plex_discover_client.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/network_artwork_provider.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/optimized_media_image.dart';
import 'package:plezy/widgets/tv_browse_rail.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/paged_fakes.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_navigation.dart';

const _generic = 'https://fixture.invalid/generic-series-poster.jpg';
const _firstStill = 'https://fixture.invalid/season9-episode1-still.jpg';
const _secondStill = 'https://fixture.invalid/season9-episode2-still.jpg';
const _ownedStill = '/library/episode3/thumb';
const _catalogData = ShowEpisodeCatalogResult(
  tvmazeId: 900,
  name: 'Fixture Show',
  premiered: '2020-01-01',
  sourceUrl: 'https://www.tvmaze.com/shows/900',
  imageUrl: _generic,
  numberingChecked: true,
  seasons: [ShowCatalogSeason(number: 9)],
  episodes: [
    ShowCatalogEpisode(
      id: 901,
      seasonNumber: 9,
      episodeNumber: 1,
      name: 'First Story',
      sourceUrl: 'https://www.tvmaze.com/episodes/901',
      airdate: '2025-01-01',
      imageUrl: _generic,
    ),
    ShowCatalogEpisode(
      id: 902,
      seasonNumber: 9,
      episodeNumber: 2,
      name: 'Second Story',
      sourceUrl: 'https://www.tvmaze.com/episodes/902',
      airdate: '2025-01-02',
      imageUrl: _generic,
    ),
    ShowCatalogEpisode(
      id: 903,
      seasonNumber: 9,
      episodeNumber: 3,
      name: 'Library Story',
      sourceUrl: 'https://www.tvmaze.com/episodes/903',
      airdate: '2025-01-03',
      imageUrl: _generic,
    ),
  ],
);

class _Catalog extends ShowEpisodeCatalog {
  _Catalog({this.includePriorSeason = false});
  final bool includePriorSeason;
  @override
  Future<ShowEpisodeCatalogResult?> load({required String title, int? year, String? imdbId, int? tvdbId}) async =>
      !includePriorSeason
      ? _catalogData
      : ShowEpisodeCatalogResult(
          tvmazeId: _catalogData.tvmazeId,
          name: _catalogData.name,
          sourceUrl: _catalogData.sourceUrl,
          premiered: _catalogData.premiered,
          imageUrl: _generic,
          numberingChecked: true,
          seasons: const [ShowCatalogSeason(number: 8), ShowCatalogSeason(number: 9)],
          episodes: [
            const ShowCatalogEpisode(
              id: 801,
              seasonNumber: 8,
              episodeNumber: 1,
              name: 'Earlier Story',
              sourceUrl: 'https://www.tvmaze.com/episodes/801',
              airdate: '2024-01-01',
            ),
            ..._catalogData.episodes,
          ],
        );
}

class _Plex extends PlexCatalogSource {
  _Plex() : super(PlexDiscoverClient(const PlexDiscoverSession(accessToken: 'fixture', clientIdentifier: 'fixture')));
  final response = Completer<Map<int, String>>();
  final responsesBySeason = <int, Future<Map<int, String>>>{};
  final calls = <(int, int)>[];
  @override
  bool get supportsWatchlist => false;
  @override
  Future<Map<int, String>> episodeArtwork({
    required ShowEpisodeCatalogResult catalog,
    String? plexShowId,
    required int seasonNumber,
  }) {
    calls.add((catalog.tvmazeId, seasonNumber));
    return responsesBySeason[seasonNumber] ?? response.future;
  }
}

class _Sources extends CatalogSourcesProvider {
  _Sources(this.sources);
  List<CatalogSource> sources;
  @override
  List<CatalogSource> get connectedSources => sources;
  void change(List<CatalogSource> value) {
    sources = value;
    notifyListeners();
  }
}

class _Library implements MediaServerClient {
  _Library({this.includePriorSeason = false});
  final bool includePriorSeason;
  final pageCalls = <String>[];
  final priorSeason = MediaItem(
    id: 'library-season8',
    backend: MediaBackend.jellyfin,
    kind: MediaKind.season,
    title: 'Season 8',
    index: 8,
    parentId: 'library-show',
    serverId: 'server_1',
  );
  final show = MediaItem(
    id: 'library-show',
    backend: MediaBackend.jellyfin,
    kind: MediaKind.show,
    title: 'Fixture Show',
    year: 2020,
    serverId: 'server_1',
  );
  final season = MediaItem(
    id: 'library-season9',
    backend: MediaBackend.jellyfin,
    kind: MediaKind.season,
    title: 'Season 9',
    index: 9,
    parentId: 'library-show',
    serverId: 'server_1',
  );
  final episode = MediaItem(
    id: 'library-episode3',
    backend: MediaBackend.jellyfin,
    kind: MediaKind.episode,
    title: 'Library Story',
    parentIndex: 9,
    index: 3,
    parentId: 'library-season9',
    grandparentId: 'library-show',
    grandparentTitle: 'Fixture Show',
    serverId: 'server_1',
    thumbPath: _ownedStill,
    viewOffsetMs: 12345,
  );
  @override
  ServerId get serverId => ServerId('server_1');
  @override
  String? get serverName => 'Fixture library';
  @override
  MediaBackend get backend => MediaBackend.jellyfin;
  @override
  ServerCapabilities get capabilities => ServerCapabilities.jellyfin;
  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(String id) async =>
      (item: show, onDeckEpisode: null);
  @override
  Future<MediaItem?> fetchItem(String id) async => [show, season, episode].where((item) => item.id == id).firstOrNull;
  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async => parentId == show.id
      ? [if (includePriorSeason) priorSeason, season]
      : parentId == priorSeason.id
      ? []
      : [episode];
  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    pageCalls.add(parentId);
    return fakeLibraryPage(await fetchChildren(parentId), start: start, size: size);
  }

  @override
  Future<List<MediaHub>> fetchRelatedHubs(String id, {int count = 10}) async => [];
  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) =>
      path?.startsWith('https://') == true ? path! : '';
  @override
  String externalImageUrl(String url, {int? width, int? height, bool cover = true}) => url;
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await tester.pump();
}

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
    TvDetectionService.debugSetAppleTVOverride(true);
    NetworkArtworkProvider.clientOverride = MockClient(
      (_) async => http.Response.bytes(
        base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='),
        200,
      ),
    );
    addTearDown(() {
      NetworkArtworkProvider.clientOverride?.close();
      NetworkArtworkProvider.clientOverride = null;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });
  });
  tearDown(() => TvDetectionService.debugSetAppleTVOverride(null));

  for (final scenario in [
    'delayed stills',
    'disconnect',
    'source replacement',
    'unavailable API',
    'API error',
    'prefetched season selection',
  ]) {
    testWidgets('episode Plex artwork: $scenario preserves episode identity and owned rows', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final prefetched = scenario == 'prefetched season selection';
      final showsStills = scenario == 'delayed stills' || prefetched;
      final library = _Library(includePriorSeason: prefetched);
      final servers = testMultiServer(clients: [library]);
      final plex = _Plex();
      if (prefetched) plex.responsesBySeason[8] = Future.value({});
      final replacement = _Plex();
      final sources = _Sources(scenario == 'unavailable API' ? [] : [plex]);
      addTearDown(sources.dispose);
      addTearDown(plex.dispose);
      addTearDown(replacement.dispose);
      BeamEpisodeIdentity? played;
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiProvider(
            providers: [
              ChangeNotifierProvider<MultiServerProvider>.value(value: servers.provider),
              ChangeNotifierProvider<CatalogSourcesProvider>.value(value: sources),
            ],
            child: MaterialApp(
              theme: monoTheme(dark: true),
              home: withProfileNavigationScope(
                child: MediaDetailScreen(
                  metadata: library.show,
                  initialSeasonIndex: prefetched ? 8 : 9,
                  showEpisodeCatalog: _Catalog(includePriorSeason: prefetched),
                  playCatalogEpisode: (_, identity) async => played = identity,
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
      final beforeRail = tester.widget<TvBrowseRail>(find.byType(TvBrowseRail));
      final before = beforeRail.hubs.singleWhere((hub) => hub.items.any((item) => item.parentIndex == 9)).items;
      final first = before.singleWhere((item) => item.index == 1);
      final second = before.singleWhere((item) => item.index == 2);
      expect(first.thumbPath, _generic);
      expect(second.thumbPath, _generic);
      expect((first.parentIndex, first.index, second.parentIndex, second.index), (9, 1, 9, 2));
      if (prefetched) {
        // Season 9 has been fetched as an adjacent page, but has never been
        // selected. Its cached rows alone must not suppress artwork loading.
        final pageCount = library.pageCalls.where((id) => id == library.season.id).length;
        expect(pageCount, greaterThan(0));
        expect(plex.calls, isNot(contains((900, 9))));
        final index = beforeRail.hubs.indexWhere((hub) => hub.items.any((item) => item.parentIndex == 9));
        beforeRail.onActiveHubChanged!(beforeRail.hubs[index], index);
        await _settle(tester);
        expect(plex.calls.where((call) => call == (900, 9)), hasLength(1));
        expect(
          library.pageCalls.where((id) => id == library.season.id),
          hasLength(pageCount),
          reason: 'The regression must navigate a cached page rather than trigger a fresh episode fetch',
        );
      }
      if (scenario == 'unavailable API') {
        expect(plex.calls, isEmpty);
      } else {
        expect(plex.calls, contains((900, 9)));
        if (scenario == 'disconnect') sources.change([]);
        if (scenario == 'source replacement') sources.change([replacement]);
        if (scenario == 'API error') {
          plex.response.completeError(StateError('Plex episode artwork unavailable'));
        } else {
          plex.response.complete({
            901: _firstStill,
            902: _secondStill,
            903: 'https://fixture.invalid/replace-owned.jpg',
          });
        }
      }
      await _settle(tester);
      final rail = tester.widget<TvBrowseRail>(find.byType(TvBrowseRail));
      final hub = rail.hubs.singleWhere((hub) => hub.items.any((item) => item.parentIndex == 9));
      final updatedFirst = hub.items.singleWhere((item) => item.index == 1);
      final updatedSecond = hub.items.singleWhere((item) => item.index == 2);
      expect(updatedFirst.id, first.id);
      expect(updatedSecond.id, second.id);
      expect(updatedFirst.raw?['tvmazeEpisodeId'], 901);
      expect(updatedSecond.raw?['tvmazeEpisodeId'], 902);
      expect(updatedFirst.serverId, isNull);
      expect(updatedSecond.serverId, isNull);
      expect(updatedFirst.thumbPath, showsStills ? _firstStill : _generic);
      expect(updatedSecond.thumbPath, showsStills ? _secondStill : _generic);
      final owned = hub.items.singleWhere((item) => item.id == library.episode.id);
      expect(owned.thumbPath, _ownedStill);
      expect(owned.serverId, 'server_1');
      expect(owned.viewOffsetMs, 12345);
      if (showsStills) {
        final urls = tester
            .widgetList<OptimizedMediaImage>(find.byType(OptimizedMediaImage))
            .map((art) => art.imagePath);
        expect(urls, containsAll([_firstStill, _secondStill]));
        expect(await rail.onActivateItem!(hub, updatedSecond), isTrue);
        expect((played?.season, played?.episode), (9, 2));
        expect(played?.metadata?.id, second.id);
        expect(played?.metadata?.thumbPath, _secondStill);
        expect(played?.episodeQueue.map((item) => item.id), [
          if (prefetched) 'tvmaze:episode:801',
          ...before.map((item) => item.id),
        ]);
        expect(played?.episodeQueue.map((item) => (item.parentIndex, item.index)), [
          if (prefetched) (8, 1),
          (9, 1),
          (9, 2),
          (9, 3),
        ]);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    });
  }
}
