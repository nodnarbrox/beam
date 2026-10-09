import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/media_detail_screen.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/beam/plex_public_discover.dart';
import 'package:plezy/services/beam/show_episode_catalog.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/tv_browse_rail.dart';

import '../services/show_episode_numbering_test.dart' as fixture;
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_navigation.dart';

class _Catalog extends ShowEpisodeCatalog {
  _Catalog(this.original, this.verifier, this.gate);
  final ShowEpisodeCatalogResult original;
  final ShowEpisodeCatalog verifier;
  final Completer<void> gate;
  var checks = 0;
  ShowEpisodeCatalogResult? lastVerification;
  @override
  Future<ShowEpisodeCatalogResult?> load({required String title, int? year, String? imdbId, int? tvdbId}) async =>
      original;
  @override
  Future<ShowEpisodeCatalogResult> verifyNumbering(ShowEpisodeCatalogResult catalog) async {
    checks++;
    await gate.future;
    return lastVerification = await verifier.verifyNumbering(catalog);
  }
}

class _Discover extends PlexPublicDiscover {
  @override
  Future<BeamDiscoverDetail?> detail(BeamDiscoverItem item) async => BeamDiscoverDetail(item: item);
}

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
    TvDetectionService.debugSetAppleTVOverride(true);
  });
  tearDown(() => TvDetectionService.debugSetAppleTVOverride(null));
  for (final leave in [false, true]) {
    testWidgets('actual catalog detail waits for broadcast numbering proof; Back=$leave', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final data = fixture.fixture('burbs');
      final gate = Completer<void>();
      final catalog = _Catalog(fixture.catalog(data), fixture.service(data, []), gate);
      final navigator = GlobalKey<NavigatorState>();
      BeamEpisodeIdentity? played;
      final show = MediaItem(
        id: 'burbs',
        backend: MediaBackend.plex,
        kind: MediaKind.show,
        title: "The 'Burbs",
        year: 2026,
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: monoTheme(dark: true),
          builder: (_, child) => withProfileNavigationScope(child: child!),
          home: const Scaffold(body: Text('Search home')),
        ),
      );
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => MediaDetailScreen(
              metadata: show,
              discoverItem: BeamDiscoverItem(title: show.title!, kind: MediaKind.show, year: 2026, ratingKey: show.id),
              discover: _Discover(),
              showEpisodeCatalog: catalog,
              playCatalogEpisode: (_, identity) async => played = identity,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rail = tester.widget<TvBrowseRail>(find.byType(TvBrowseRail));
      final hub = rail.hubs.singleWhere((h) => h.items.any((e) => e.index == 2));
      final item = hub.items.singleWhere((e) => e.index == 2);
      expect(BeamEpisodeIdentity.fromMetadata(item)!.storyConstraint, isNotNull);
      final operation = Future<bool>.value(rail.onActivateItem!(hub, item));
      await tester.pump();
      expect(catalog.checks, 1);
      expect(played, isNull);
      if (leave) {
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
      }
      gate.complete();
      await tester.pump();
      await operation;
      if (leave) {
        expect(played, isNull);
        expect(find.text('Search home'), findsOneWidget);
      } else {
        expect(catalog.lastVerification?.numberingChecked, isTrue);
        expect(catalog.lastVerification?.numberingEvidence, hasLength(8));
        expect((played?.season, played?.episode), (1, 2));
        expect(played?.metadata?.title, 'Mind Your Own Business');
        expect(played?.metadata?.serverId, isNull);
        expect(played!.metadata?.raw?['beamNumberingEvidence'], containsPair('alternateListId', 5340));
        expect(played!.storyConstraint, isNull, reason: '${played!.metadata?.raw}');
        expect(played!.episodeQueue, hasLength(8));
        expect(played!.episodeQueue.every((e) => BeamEpisodeIdentity.fromMetadata(e)!.storyConstraint == null), isTrue);
        await rail.onActivateItem!(hub, item);
        expect(catalog.checks, 1);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
