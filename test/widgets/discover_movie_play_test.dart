import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/focusable_action_bar.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/catalog/catalog_item.dart';
import 'package:plezy/screens/beam/beam_detail_screen.dart';
import 'package:plezy/screens/media_detail_screen.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/beam/beam_fallback.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/plex_public_discover.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/services/beam/show_episode_catalog.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/catalog/catalog_library_matcher.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/discovery_search_results.dart';
import 'package:plezy/widgets/focusable_media_card.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_navigation.dart';

class _Catalog extends PlexPublicDiscover {
  _Catalog({BeamDiscoverItem? result})
    : item =
          result ??
          BeamDiscoverItem(
            title: 'The Butler',
            year: 2013,
            kind: MediaKind.movie,
            guid: 'plex://movie/butler-2013',
            ratingKey: 'butler-2013',
            overview: 'A White House butler serves eight presidents.',
          );
  final BeamDiscoverItem item;
  @override
  Future<List<BeamDiscoverItem>> search(
    String query, {
    MediaKind? kind,
    int limit = 40,
    bool throwOnError = false,
  }) async => [item];
  @override
  Future<BeamDiscoverDetail?> detail(BeamDiscoverItem item) async =>
      BeamDiscoverDetail(item: item, durationMinutes: 132, contentRating: 'PG-13');
  @override
  Future<List<BeamSeason>> seasons(String ratingKey, {int fallbackSeasonCount = 0}) async => const [];
}

class _LibraryMatcher implements CatalogLibraryMatcher {
  _LibraryMatcher(this.item);
  final MediaItem? item;
  @override
  Future<List<MediaItem>> match(CatalogItem item) async => [?this.item];
}

class _EmptyEpisodes extends ShowEpisodeCatalog {
  @override
  Future<ShowEpisodeCatalogResult?> load({required String title, int? year, String? imdbId, int? tvdbId}) async => null;
}

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });
  tearDown(() {
    TvDetectionService.debugSetAppleTVOverride(null);
    BeamFallback.searchOverride = null;
    BeamFallback.playServiceOverride = null;
    BeamFallback.cachedSourcesOverride = null;
    BeamFallback.playerWrapper = null;
  });

  for (final matched in [false, true]) {
    testWidgets('show delegates to full library detail with real match=$matched', (tester) async {
      TvDetectionService.debugSetAppleTVOverride(true);
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final show = BeamDiscoverItem(title: 'Pioneer One', kind: MediaKind.show, year: 2010, ratingKey: 'pioneer-one');
      final libraryShow = MediaItem(
        id: 'library-show',
        serverId: 'real-server',
        backend: MediaBackend.plex,
        title: 'Pioneer One',
        kind: MediaKind.show,
        year: 2010,
      );
      final episodes = _EmptyEpisodes();
      await tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(dark: true),
          home: withProfileNavigationScope(
            child: BeamDetailScreen(
              item: show,
              discover: _Catalog(),
              libraryMatcher: _LibraryMatcher(matched ? libraryShow : null),
              showEpisodeCatalog: episodes,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final detail = tester.widget<MediaDetailScreen>(find.byType(MediaDetailScreen));
      expect(detail.discoverItem, same(show));
      expect(detail.showEpisodeCatalog, same(episodes));
      expect(detail.metadata.title, 'Pioneer One');
      expect(detail.metadata.kind, MediaKind.show);
      expect(detail.metadata.year, 2010);
      if (matched) {
        expect(detail.metadata, same(libraryShow));
        expect(detail.metadata.serverId, 'real-server');
      } else {
        expect(detail.metadata.serverId, isNull);
        expect(detail.metadata.id, isNot('library-show'));
      }
      expect(find.byType(FocusableActionBar), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('search show card opens full media detail with the selected catalog identity', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Unknown year intentionally prevents a speculative external metadata match.
    final show = BeamDiscoverItem(title: 'Pioneer One', kind: MediaKind.show, ratingKey: 'pioneer-one');
    final focus = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        builder: (_, child) => withProfileNavigationScope(child: child!),
        home: Scaffold(
          body: SingleChildScrollView(
            child: DiscoverySearchResults(
              query: 'Pioneer One',
              scope: SearchScope.tv,
              libraryItems: const [],
              firstFocus: focus,
              onNavigateLeft: () {},
              onNavigateUp: () {},
              onQuery: (_) {},
              catalog: _Catalog(result: show),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(tester.widget<FocusableMediaCard>(find.byType(FocusableMediaCard)).forceListMode, isTrue);
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(BeamDetailScreen), findsOneWidget);
    final detail = tester.widget<MediaDetailScreen>(find.byType(MediaDetailScreen));
    expect(detail.discoverItem, same(show));
    expect(detail.metadata.title, 'Pioneer One');
    expect(detail.metadata.kind, MediaKind.show);
    expect(detail.metadata.serverId, isNull);
    expect(find.byType(FocusableActionBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    focus.dispose();
  });

  testWidgets('catalog full card opens its real detail Play and retains selected movie through fallback', (
    tester,
  ) async {
    final catalog = _Catalog();
    final focus = FocusNode();
    final opened = Completer<VideoPlayerScreen>();
    final queries = <String>[];
    BeamFallback.searchOverride = (query, kind) async {
      queries.add(query);
      expect(kind, MediaKind.movie);
      return [
        ProwlarrResult.fromJson({
          'title': 'The.Butler.2013.1080p.BluRay.RELEASE',
          'seeders': 50,
          'guid': 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
        }),
      ];
    };
    BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
    BeamFallback.playServiceOverride = BeamPlayService(
      torrent: (source, season, episode, cancel) async =>
          BeamPlayResult(url: 'https://fixture/butler.mp4', winner: BeamPlayWinner.torrent, magnet: source.magnetUrl!),
    );
    BeamFallback.playerWrapper = (player) {
      if (!opened.isCompleted) opened.complete(player);
      return const Scaffold(body: Text('Native player boundary'));
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(
          body: SingleChildScrollView(
            child: DiscoverySearchResults(
              query: 'The butler',
              scope: SearchScope.movies,
              libraryItems: const [],
              firstFocus: focus,
              onNavigateLeft: () {},
              onNavigateUp: () {},
              onQuery: (_) {},
              catalog: catalog,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final card = tester.widget<FocusableMediaCard>(find.byType(FocusableMediaCard));
    expect(card.forceListMode, isTrue);
    final item = card.item as MediaItem;
    expect(item.serverId, isNull);
    expect(item.title, 'The Butler');
    expect(find.text(catalog.item.overview!), findsOneWidget);
    expect(find.textContaining('Find a stream'), findsNothing);
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(BeamDetailScreen), findsOneWidget);
    expect(find.byType(FocusableActionBar), findsOneWidget);
    await tester.tap(find.text('Play'));
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && !opened.isCompleted; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(opened.isCompleted, isTrue);
    final player = await opened.future;
    expect(queries, ['The Butler 2013']);
    expect(player.metadata.title, 'The Butler');
    expect(player.metadata.year, 2013);
    expect(player.metadata.kind, MediaKind.movie);
    expect(player.metadata.serverId, isNull);
    expect(player.metadata.durationMs, 132 * 60000);
    expect(player.directVideoUrl, 'https://fixture/butler.mp4');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    focus.dispose();
  });
}
