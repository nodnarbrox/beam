import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/catalog/catalog_item.dart';
import 'package:plezy/screens/beam/beam_detail_screen.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/beam/beam_fallback.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/plex_public_discover.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/services/catalog/catalog_library_matcher.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import '../test_helpers/prefs.dart';

class _Matcher implements CatalogLibraryMatcher {
  _Matcher(this.lookup);
  final Future<List<MediaItem>> Function(CatalogItem) lookup;
  @override
  Future<List<MediaItem>> match(CatalogItem item) => lookup(item);
}

class _Catalog extends PlexPublicDiscover {
  @override
  Future<BeamDiscoverDetail?> detail(BeamDiscoverItem item) async => throw StateError('Metadata service unavailable');
}

final _butler = BeamDiscoverItem(
  title: 'The Butler',
  year: 2013,
  kind: MediaKind.movie,
  guid: 'plex://movie/butler-2013',
  ratingKey: 'butler-2013',
  overview: 'The selected movie must remain The Butler.',
);

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });
  tearDown(() {
    BeamFallback.searchOverride = null;
    BeamFallback.playServiceOverride = null;
    BeamFallback.cachedSourcesOverride = null;
    BeamFallback.playerWrapper = null;
  });

  Widget app(CatalogLibraryMatcher matcher, {Future<void> Function(BuildContext, MediaItem)? play}) => MaterialApp(
    theme: monoTheme(dark: true),
    home: BeamDetailScreen(item: _butler, discover: _Catalog(), libraryMatcher: matcher, playLibraryItem: play),
  );

  testWidgets('verified library match uses original server playback item and no torrent search', (tester) async {
    final libraryItem = MediaItem(
      id: 'original-library-rating-key',
      serverId: 'real-server',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'The Butler',
      year: 2013,
    );
    MediaItem? played;
    final queries = <String>[];
    BeamFallback.searchOverride = (query, _) async {
      queries.add(query);
      return [];
    };
    await tester.pumpWidget(
      app(
        _Matcher((catalog) async {
          expect(catalog.ids.plex, 'butler-2013');
          expect(catalog.title, 'The Butler');
          expect(catalog.year, 2013);
          return [libraryItem];
        }),
        play: (_, item) async => played = item,
      ),
    );
    await tester.pumpAndSettle();
    // The same focused action machinery must work with remote Select.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(played, same(libraryItem));
    expect(queries, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final failure in ['lookup error', 'serverless match', 'stalled lookup']) {
    testWidgets('$failure falls back with the selected movie metadata', (tester) async {
      final stalled = Completer<List<MediaItem>>();
      final queries = <String>[];
      final opened = <VideoPlayerScreen>[];
      var serverPlays = 0;
      final matcher = _Matcher((_) {
        if (failure == 'lookup error') return Future.error(StateError('Library offline'));
        if (failure == 'stalled lookup') return stalled.future;
        return Future.value([_butler.toCatalogItem().toMediaItem()]);
      });
      BeamFallback.searchOverride = (query, kind) async {
        queries.add(query);
        expect(kind, MediaKind.movie);
        return [
          ProwlarrResult.fromJson({
            'title': 'The.Butler.2013.1080p.RELEASE',
            'seeders': 10,
            'guid': 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
          }),
        ];
      };
      BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
      BeamFallback.playServiceOverride = BeamPlayService(
        torrent: (source, season, episode, cancellation) async {
          expect(season, isNull);
          expect(episode, isNull);
          return BeamPlayResult(
            url: 'https://fixture/butler.mp4',
            winner: BeamPlayWinner.torrent,
            magnet: source.magnetUrl!,
          );
        },
      );
      BeamFallback.playerWrapper = (player) {
        opened.add(player);
        return const Scaffold(body: Text('Correct movie playback boundary'));
      };
      await tester.pumpWidget(
        app(
          matcher,
          play: (_, _) async {
            serverPlays++;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play'));
      if (failure == 'stalled lookup') await tester.pump(const Duration(seconds: 16));
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && opened.isEmpty; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(queries, ['The Butler 2013']);
      expect(serverPlays, 0);
      expect(opened, hasLength(1));
      expect(opened.single.metadata.title, 'The Butler');
      expect(opened.single.metadata.year, 2013);
      expect(opened.single.metadata.serverId, isNull);
      expect(opened.single.metadata.kind, MediaKind.movie);
      expect(opened.single.directVideoUrl, 'https://fixture/butler.mp4');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      if (!stalled.isCompleted) stalled.complete([]);
      await tester.pump();
    });
  }
}
