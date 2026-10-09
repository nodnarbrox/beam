import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/services/games/game_library.dart';
import 'package:plezy/widgets/game_search_results.dart';

void main() {
  testWidgets('late game search cannot replace the newer query or cleared results', (tester) async {
    SharedPreferences.setMockInitialValues({'games.url': 'http://library'});
    final slow = Completer<http.Response>();
    http.Response response(String title) => http.Response(
      jsonEncode({
        'games': [
          {'id': title, 'title': title, 'system': 'nes', 'systemName': 'Nintendo'},
        ],
        'total': 1,
      }),
      200,
    );
    final library = GameLibrary(
      await SharedPreferences.getInstance(),
      'local',
      client: MockClient((r) async {
        return r.url.queryParameters['q'] == 'old' ? slow.future : response('New game');
      }),
    );
    final focus = FocusNode();
    addTearDown(focus.dispose);
    Future<void> query(String text) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GameSearchResults(
              query: text,
              library: library,
              firstFocus: focus,
              onNavigateLeft: () {},
              onNavigateUp: () {},
              onResultsReady: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }

    await query('old');
    await query('new');
    expect(find.text('New game'), findsOneWidget);
    slow.complete(response('Old game'));
    await tester.pumpAndSettle();
    expect(find.text('Old game'), findsNothing);
    expect(find.text('New game'), findsOneWidget);
    await query('');
    expect(find.text('New game'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
