import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:plezy/services/beam/beam_fallback.dart';

class _PendingPreferences extends InMemorySharedPreferencesStore {
  _PendingPreferences() : super.empty();
  final result = Completer<Map<String, Object>>();
  @override
  Future<Map<String, Object>> getAll() => result.future;
}

void main() {
  testWidgets('Beam progress renders and BACK cancels without popping its page', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = _PendingPreferences();
    SharedPreferencesStorePlatform.instance = store;
    Future<bool>? playback;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () => playback = BeamFallback.playByTitle(context, title: 'Big Buck Bunny'),
                child: const Text('Stream test title'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('Stream test title'));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Press BACK to cancel'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Press BACK to cancel'), findsNothing);
    expect(find.text('Stream test title'), findsOneWidget);
    // Cancellation must release Play even while the first request is stalled.
    expect(await playback, isFalse);
    await tester.tap(find.text('Stream test title'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Press BACK to cancel'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(await playback, isFalse);
    store.result.completeError(StateError('Simulated settings failure after cancellation'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    SharedPreferences.setMockInitialValues({});
  });
}
