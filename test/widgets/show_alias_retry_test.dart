import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

import '../test_helpers/prefs.dart';
import '../test_helpers/profile_navigation.dart';

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

  for (final scenario in ['recover', 'leave', 'outage']) {
    testWidgets('current detail retries verified aliases before Play: $scenario', (tester) async {
      final leave = scenario == 'leave';
      final outage = scenario == 'outage';
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const title = 'Spidey and His Amazing Friends';
      const alias = "Marvel's Spidey and His Amazing Friends";
      final retry = Completer<http.Response>();
      final paths = <String>[];
      var aliasRequests = 0;
      final service = ShowEpisodeCatalog(
        clientFactory: () async => MockClient((request) async {
          final path = request.url.path;
          paths.add(path);
          if (path.endsWith('/akas')) {
            aliasRequests++;
            return aliasRequests == 1 ? http.Response('unavailable', 503) : retry.future;
          }
          final Object body = switch (path) {
            '/search/shows' => [
              {
                'show': {
                  'id': 43708,
                  'name': title,
                  'premiered': '2021-08-06',
                  'url': 'https://www.tvmaze.com/shows/43708/spidey',
                },
              },
            ],
            '/shows/43708/seasons' => [
              {'id': 104, 'number': 4},
            ],
            '/shows/43708/episodes' => [
              for (final number in [13, 15])
                {
                  'id': number,
                  'season': 4,
                  'number': number,
                  'name': 'Story $number',
                  'airdate': '2025-01-01',
                  'url': 'https://www.tvmaze.com/episodes/$number',
                },
            ],
            _ => throw StateError('Unexpected metadata request $path'),
          };
          return http.Response(jsonEncode(body), 200);
        }),
      );
      final navigator = GlobalKey<NavigatorState>();
      BeamEpisodeIdentity? played;
      final show = MediaItem(
        id: 'catalog-spidey',
        backend: MediaBackend.plex,
        kind: MediaKind.show,
        title: title,
        year: 2021,
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
              discoverItem: BeamDiscoverItem(title: title, kind: MediaKind.show, year: 2021, ratingKey: show.id),
              discover: _Discover(),
              initialSeasonIndex: 4,
              showEpisodeCatalog: service,
              playCatalogEpisode: (_, identity) async => played = identity,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rail = tester.widget<TvBrowseRail>(find.byType(TvBrowseRail));
      final hub = rail.hubs.singleWhere((hub) => hub.items.any((item) => item.index == 13));
      final selected = hub.items.singleWhere((item) => item.index == 13);
      expect(selected.raw?['beamShowAliases'], isEmpty);
      expect(aliasRequests, 1);
      final operation = Future<bool>.value(rail.onActivateItem!(hub, selected));
      await tester.pump();
      expect(aliasRequests, 2);
      expect(played, isNull);
      expect(find.byType(TvBrowseRail), findsOneWidget);
      if (leave) {
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
      }
      retry.complete(
        outage
            ? http.Response('unavailable', 503)
            : http.Response(
                jsonEncode([
                  {'name': alias},
                ]),
                200,
              ),
      );
      await tester.pump();
      await operation;
      if (leave) {
        expect(played, isNull);
        expect(find.text('Search home'), findsOneWidget);
      } else {
        expect(played?.showTitle, title);
        expect(played?.year, 2021);
        expect(played?.season, 4);
        expect(played?.episode, 13);
        expect(played?.metadata?.serverId, isNull);
        expect(played?.metadata?.raw?['beamShowAliases'], outage ? isEmpty : [alias]);
        expect(played!.episodeQueue.map((item) => item.index), containsAll([13, 15]));
        for (final item in played!.episodeQueue) {
          expect(item.raw?['beamShowAliases'], outage ? isEmpty : [alias]);
        }
        // Success is cached; a repeated outage remains retryable next Play.
        await rail.onActivateItem!(hub, selected);
        expect(aliasRequests, outage ? 3 : 2);
      }
      expect(paths.where((path) => path == '/search/shows'), hasLength(1));
      expect(paths.where((path) => path.endsWith('/episodes')), hasLength(1));
      expect(paths.where((path) => path.endsWith('/akas')), everyElement('/shows/43708/akas'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
