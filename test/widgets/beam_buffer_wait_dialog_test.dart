import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/beam/beam_buffer_wait.dart';
import 'package:plezy/widgets/beam_buffer_wait_dialog.dart';

void main() {
  for (final estimate in [const Duration(seconds: 80), null]) {
    testWidgets('buffer choice describes ${estimate == null ? "unknown ETA" : "measured 1:20 ETA"}', (tester) async {
      bool? answer;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BeamBufferWaitDialog(
              offer: BeamBufferWaitOffer(
                bufferSeconds: 4,
                targetBufferSeconds: 20,
                elapsed: const Duration(seconds: 30),
                reason: BeamBufferWaitReason.slow,
                estimatedWait: estimate,
                done: Completer<void>().future,
              ),
              onKeepBuffering: () => answer = true,
              onCancel: () => answer = false,
            ),
          ),
        ),
      );
      if (estimate == null) {
        expect(find.textContaining('not enough progress to estimate'), findsOneWidget);
        expect(find.textContaining('About '), findsNothing);
      } else {
        expect(find.text('About 1:20 more to build the starting buffer.'), findsOneWidget);
      }
      expect(find.textContaining('Playback may still pause'), findsOneWidget);
      expect(find.textContaining('start automatically when one is ready'), findsOneWidget);
      await tester.tap(find.text('Keep buffering'));
      expect(answer, isTrue);
      await tester.tap(find.text('Cancel'));
      expect(answer, isFalse);
    });
  }

  test('wait text rounds up and retains hours', () {
    expect(BeamBufferWaitDialog.formatWait(const Duration(milliseconds: 79901)), '1:20');
    expect(BeamBufferWaitDialog.formatWait(const Duration(seconds: 3661)), '1:01:01');
  });
}
