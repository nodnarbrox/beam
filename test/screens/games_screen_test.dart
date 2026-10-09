import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/screens/games/games_screen.dart';
import 'package:plezy/services/games/game_library.dart';
import 'package:plezy/focus/key_event_utils.dart';
import 'package:plezy/focus/focusable_text_field.dart';
import 'package:plezy/navigation/main_screen_scope.dart';
import 'package:plezy/utils/platform_detector.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'games.url': 'http://library'});
    BackKeyCoordinator.clear();
  });
  tearDown(() => TvDetectionService.setForceTVSync(false));

  for (final empty in [false, true]) {
    testWidgets('TV Games search escapes keyboard and moves down (empty=$empty)', (tester) async {
      await TvDetectionService.getInstance(forceTv: true);
      TvDetectionService.setForceTVSync(true);
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final requests = <Uri>[];
      final sidebar = FocusNode(debugLabel: 'test.sidebar');
      addTearDown(sidebar.dispose);
      var backs = 0;
      final library = GameLibrary(
        await SharedPreferences.getInstance(),
        'local',
        client: MockClient((r) async {
          requests.add(r.url);
          return http.Response(
            jsonEncode(
              r.url.path == '/systems'
                  ? {'systems': []}
                  : {
                      'games': empty && r.url.queryParameters['q'] == '2048'
                          ? []
                          : [
                              {
                                'id': '012345678901234567890123',
                                'title': '2048',
                                'system': 'nes',
                                'systemName': 'Nintendo',
                                'genre': 'Puzzle',
                                'description': 'Slide the tiles.',
                              },
                            ],
                      'total': empty && r.url.queryParameters['q'] == '2048' ? 0 : 1,
                    },
            ),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MainScreenFocusScope(
              focusSidebar: () {
                backs++;
                sidebar.requestFocus();
              },
              focusContent: () {},
              isSidebarFocused: false,
              sideNavigationWidth: 24,
              child: Row(
                children: [
                  Focus(focusNode: sidebar, child: const SizedBox(width: 24)),
                  Expanded(child: GamesScreen(library: library)),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = tester.widget<FocusableTextField>(find.byType(FocusableTextField));
      await tester.ensureVisible(find.byType(FocusableTextField));
      field.focusNode!.requestFocus();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsOneWidget);
      field.controller.text = '2048';
      await tester.sendKeyEvent(LogicalKeyboardKey.goBack, physicalKey: PhysicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);
      expect(backs, 0);
      expect(field.focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(requests.last.queryParameters['q'], '2048');
      expect(FocusManager.instance.primaryFocus?.debugLabel, empty ? 'games.collections' : 'games.firstResult');
      if (!empty) {
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(find.byType(GameDetailScreen), findsOneWidget);
        expect(find.text('Play / Resume'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.goBack, physicalKey: PhysicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(GameDetailScreen), findsNothing);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'games.firstResult');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(field.focusNode!.hasFocus, isTrue);
        expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.goBack, physicalKey: PhysicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(backs, 1);
      expect(sidebar.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
  testWidgets('console selection and search update the graphical collection', (tester) async {
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <Uri>[];
    final library = GameLibrary(
      await SharedPreferences.getInstance(),
      'local',
      client: MockClient((r) async {
        requests.add(r.url);
        return http.Response(
          jsonEncode(
            r.url.path == '/systems'
                ? {
                    'systems': [
                      {'id': 'nes', 'title': 'Nintendo', 'count': 1},
                    ],
                  }
                : {
                    'games': [
                      {
                        'id': '012345678901234567890123',
                        'title': '2048',
                        'system': 'nes',
                        'systemName': 'Nintendo',
                        'genre': 'Puzzle',
                        'description': 'Slide the tiles.',
                      },
                    ],
                    'total': 1,
                  },
          ),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GamesScreen(library: library)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Choose your collection'), findsOneWidget);
    final console = find.byKey(const ValueKey('games.collection.nes'));
    await tester.ensureVisible(console);
    await tester.tap(console);
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['system'], 'nes');
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '2048');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['q'], '2048');
    expect(tester.takeException(), isNull);
  });
  testWidgets('detail and settings each return with remote Back', (tester) async {
    final library = GameLibrary(await SharedPreferences.getInstance(), 'local');
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: Text('Games root')),
      ),
    );
    for (final screen in [
      GameDetailScreen(
        library: library,
        game: LibraryGame({
          'id': '012345678901234567890123',
          'title': 'Demo',
          'system': 'nes',
          'systemName': 'Nintendo',
          'description': '',
        }),
      ),
      GamesSettingsScreen(library: library),
    ]) {
      unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => screen)));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.goBack, physicalKey: PhysicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Games root'), findsOneWidget);
      expect(tester.takeException(), isNull);
      BackKeyCoordinator.clear();
    }
    library.close();
  });
}
