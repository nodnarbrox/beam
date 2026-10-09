import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/navigation/navigation_tabs.dart';

void main() {
  group('NavigationTab.resolveDefaultTab', () {
    test('offline prefers Downloads when available', () {
      expect(
        NavigationTab.resolveDefaultTab(isOffline: true, hasLiveTv: false, preferredStartup: null),
        NavigationTabId.downloads,
      );
    });

    test('offline ignores an online-only preferred section', () {
      expect(
        NavigationTab.resolveDefaultTab(isOffline: true, hasLiveTv: true, preferredStartup: NavigationTabId.liveTv),
        NavigationTabId.downloads,
      );
    });

    test('online honours the preferred section when it is visible', () {
      expect(
        NavigationTab.resolveDefaultTab(isOffline: false, hasLiveTv: true, preferredStartup: NavigationTabId.liveTv),
        NavigationTabId.liveTv,
      );
      expect(
        NavigationTab.resolveDefaultTab(isOffline: false, hasLiveTv: false, preferredStartup: NavigationTabId.search),
        NavigationTabId.search,
      );
    });

    test('direct Live TV can be preferred without a media server', () {
      expect(
        NavigationTab.resolveDefaultTab(isOffline: false, hasLiveTv: false, preferredStartup: NavigationTabId.liveTv),
        NavigationTabId.liveTv,
      );
    });

    test('online defaults to the video store when no preference is set', () {
      expect(
        NavigationTab.resolveDefaultTab(isOffline: false, hasLiveTv: true, preferredStartup: null),
        NavigationTabId.videoStore,
      );
    });

    test('online falls back to the video store when preferred Explore is unavailable', () {
      expect(
        NavigationTab.resolveDefaultTab(isOffline: false, hasLiveTv: false, preferredStartup: NavigationTabId.explore),
        NavigationTabId.videoStore,
      );
      expect(
        NavigationTab.resolveDefaultTab(
          isOffline: false,
          hasLiveTv: false,
          hasExplore: true,
          preferredStartup: NavigationTabId.explore,
        ),
        NavigationTabId.explore,
      );
    });
  });

  group('NavigationTab.getVisibleTabs', () {
    test('direct TV stays available without a Plex or Jellyfin connection', () {
      expect(NavigationTab.getVisibleTabs(isOffline: true, hasLiveTv: false).map((tab) => tab.id),
        contains(NavigationTabId.liveTv));
    });
    test('hides Explore until a catalog source is connected', () {
      final without = NavigationTab.getVisibleTabs(isOffline: false);
      expect(without.map((tab) => tab.id), isNot(contains(NavigationTabId.explore)));

      final with_ = NavigationTab.getVisibleTabs(isOffline: false, hasExplore: true, hasLiveTv: true);
      final ids = with_.map((tab) => tab.id).toList();
      expect(ids, contains(NavigationTabId.explore));
      // Explore sits after Live TV, directly before Search.
      expect(ids.indexOf(NavigationTabId.explore), ids.indexOf(NavigationTabId.liveTv) + 1);
      expect(ids.indexOf(NavigationTabId.explore), ids.indexOf(NavigationTabId.search) - 1);
    });

    test('Explore is online-only', () {
      final offline = NavigationTab.getVisibleTabs(isOffline: true, hasExplore: true);
      expect(offline.map((tab) => tab.id), isNot(contains(NavigationTabId.explore)));
    });
  });
}
