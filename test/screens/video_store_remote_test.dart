import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:plezy/navigation/main_screen_scope.dart';
import 'package:plezy/navigation/navigation_tabs.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/screens/video_store/video_store_2d_fallback.dart';

void main() {
  test('the redundant Beam search tab is absent, including saved startup values', () {
    expect(allNavigationTabs.map((tab) => tab.id), isNot(contains(NavigationTabId.beam)));
    expect(
      NavigationTab.resolveDefaultTab(isOffline: false, hasLiveTv: false, preferredStartup: NavigationTabId.beam),
      NavigationTabId.videoStore,
    );
  });

  for (final key in [LogicalKeyboardKey.goBack, LogicalKeyboardKey.arrowLeft]) {
    testWidgets('empty fallback accepts content focus and returns to sidebar with ${key.keyLabel}', (tester) async {
      final storeKey = GlobalKey<VideoStore2DFallbackState>();
      final sidebarFocus = FocusNode();
      addTearDown(sidebarFocus.dispose);
      final libraries = LibrariesProvider();
      addTearDown(libraries.dispose);
      var sidebarRequests = 0;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: libraries,
          child: MaterialApp(
            home: MainScreenFocusScope(
              focusSidebar: () {
                sidebarRequests++;
                sidebarFocus.requestFocus();
              },
              focusContent: () => storeKey.currentState!.focusActiveTabIfReady(),
              isSidebarFocused: false,
              sideNavigationWidth: 60,
              child: Row(
                children: [
                  Focus(focusNode: sidebarFocus, child: const SizedBox(width: 60)),
                  Expanded(child: VideoStore2DFallback(key: storeKey, halloween: true)),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      storeKey.currentState!.focusActiveTabIfReady();
      await tester.pump();
      expect(sidebarFocus.hasFocus, isFalse);
      await tester.sendKeyEvent(
        key,
        physicalKey: key == LogicalKeyboardKey.goBack ? PhysicalKeyboardKey.escape : PhysicalKeyboardKey.arrowLeft,
      );
      await tester.pump();
      expect(sidebarRequests, 1);
      expect(sidebarFocus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
