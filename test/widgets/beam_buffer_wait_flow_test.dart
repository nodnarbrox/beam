import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/beam/beam_buffer_wait.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_fallback.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/beam_playback_duration.dart';
import 'package:plezy/services/beam/episode_file_selector.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/widgets/beam_buffer_wait_dialog.dart';

import '../test_helpers/prefs.dart';

class _Attempt {
  _Attempt(this.source, this.token, this.wait);
  final ProwlarrResult source;
  final BeamCancellation token;
  final BeamBufferWait wait;
  final ready = Completer<BeamPlayResult>();
  final done = Completer<void>();
  int commits = 0;
  int closes = 0;

  Future<bool> offer({Duration? estimate = const Duration(seconds: 80)}) => wait(
    BeamBufferWaitOffer(
      bufferSeconds: 4,
      targetBufferSeconds: 20,
      elapsed: const Duration(seconds: 30),
      reason: BeamBufferWaitReason.slow,
      estimatedWait: estimate,
      selectedFilename: 'Pioneer.One.S01E01.mp4',
      done: done.future,
    ),
  );

  void complete() {
    if (!done.isCompleted) done.complete();
    ready.complete(
      BeamPlayResult(
        url: 'https://fixture.invalid/episode',
        winner: BeamPlayWinner.torrent,
        magnet: source.magnetUrl!,
        selectedFilename: 'Pioneer.One.S01E01.mp4',
        onPlaybackStarted: () => commits++,
        onCancelled: () => closes++,
      ),
    );
  }
}

class _Service extends BeamPlayService {
  final attempts = <_Attempt>[];
  @override
  Future<BeamPlayResult> race(
    ProwlarrResult result, {
    required bool rdEnabled,
    required bool torrentEnabled,
    BeamPlayProgress? onProgress,
    BeamBufferWait? onBufferWait,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    BeamPlaybackDuration? playbackDuration,
    Duration? torrentStall,
    bool deferLoserCancellation = false,
    BeamCancellation? cancellation,
  }) {
    final attempt = _Attempt(result, cancellation!, onBufferWait!);
    attempts.add(attempt);
    unawaited(
      cancellation.whenCancelled.then((_) {
        if (!attempt.done.isCompleted) attempt.done.complete();
      }),
    );
    return cancellation.bind(attempt.ready.future);
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(ready(), isTrue, reason: 'Fixture did not reach the expected playback stage');
}

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
  });

  for (final action in [
    'keep',
    'remote keep then Back',
    'cancel',
    'system Back',
    'ready',
    'late offer then ready',
    'late offer reaches consent expiry',
  ]) {
    testWidgets('actual automatic buffering flow: $action preserves route and race ownership', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final service = _Service();
      final navigator = GlobalKey<NavigatorState>();
      VideoPlayerScreen? player;
      Future<bool>? operation;
      var cancellationCalls = 0;
      BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
      BeamFallback.searchOverride = (_, _) async => [
        for (var i = 1; i <= 2; i++)
          ProwlarrResult.fromJson({
            'title': 'Pioneer.One.S01E01.720p.Source$i',
            'seeders': 20 - i,
            'guid': 'magnet:?xt=urn:btih:${i.toString().padLeft(40, '0')}',
          }),
      ];
      BeamFallback.playServiceOverride = service;
      BeamFallback.playerWrapper = (screen) {
        player = screen;
        return const Scaffold(body: Text('Fixture player'));
      };
      addTearDown(() async {
        BeamFallback.cachedSourcesOverride = null;
        BeamFallback.searchOverride = null;
        BeamFallback.playServiceOverride = null;
        BeamFallback.playerWrapper = null;
        await tester.runAsync(db.close);
      });
      await tester.pumpWidget(
        Provider.value(
          value: db,
          child: MaterialApp(
            navigatorKey: navigator,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => Scaffold(
                        body: Column(
                          children: [
                            const Text('Episode details'),
                            TextButton(
                              onPressed: () => operation = BeamFallback.playByTitle(
                                context,
                                title: 'Pioneer One',
                                season: 1,
                                episode: 1,
                                onCancelled: () => cancellationCalls++,
                              ),
                              child: const Text('Play episode'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  child: const Text('Open details'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play episode'));
      await _until(tester, () => service.attempts.isNotEmpty);
      expect(service.attempts, hasLength(2), reason: 'Both selected sources start without a hedge delay');
      final first = service.attempts.first;
      final decision = first.offer(estimate: action == 'system Back' ? null : const Duration(seconds: 80));
      await tester.pump();
      expect(find.byType(BeamBufferWaitDialog), findsOneWidget);
      if (action == 'system Back') {
        expect(find.textContaining('not enough progress to estimate'), findsOneWidget);
      } else {
        expect(find.textContaining('About 1:20'), findsOneWidget);
      }

      if (action == 'cancel' || action == 'system Back') {
        if (action == 'cancel') {
          await tester.tap(find.text('Cancel'));
        } else {
          await tester.binding.handlePopRoute();
        }
        await tester.pumpAndSettle();
        expect(await decision, isFalse);
        expect(await operation!, isFalse);
        expect(first.token.isCancelled, isTrue);
        expect(cancellationCalls, 1);
        expect(find.text('Episode details'), findsOneWidget);
        expect(find.text('Fixture player'), findsNothing);
        expect(find.byType(BeamBufferWaitDialog), findsNothing);
        expect(navigator.currentState!.canPop(), isTrue);
      } else if (action == 'remote keep then Back') {
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(find.byType(BeamBufferWaitDialog), findsNothing);
        expect(await decision, isTrue);
        expect(first.token.isCancelled, isFalse);
        expect(find.byType(BeamBufferWaitDialog), findsNothing);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(await operation!, isFalse);
        expect(first.token.isCancelled, isTrue);
        expect(cancellationCalls, 1);
        expect(find.text('Episode details'), findsOneWidget);
      } else {
        final lateOffer = action.startsWith('late offer');
        if (action == 'keep' || lateOffer) {
          await tester.tap(find.text('Keep buffering'));
          await tester.pump();
          expect(await decision, isTrue);
          expect(first.token.isCancelled, isFalse);
          expect(find.byType(BeamBufferWaitDialog), findsNothing);
        }
        // Both sources are already running. A second slow offer can arrive
        // ten seconds later without interrupting the agreed buffering wait.
        if (lateOffer) await tester.pump(const Duration(seconds: 10));
        expect(service.attempts, hasLength(2));
        final second = service.attempts[1];
        Future<bool>? secondDecision;
        if (lateOffer) {
          var answered = false;
          secondDecision = second.offer(estimate: const Duration(seconds: 45)).then((value) {
            answered = true;
            return value;
          });
          await tester.pump();
          expect(find.byType(BeamBufferWaitDialog), findsNothing);
          expect(answered, isFalse, reason: 'A later source must not receive unlimited automatic consent');
          // 80s estimate + 30s margin is below the minimum accepted 120s.
          // Ten seconds have elapsed; the second offer remains hidden at 119s.
          await tester.pump(const Duration(seconds: 109));
          expect(find.byType(BeamBufferWaitDialog), findsNothing);
          expect(answered, isFalse);
          expect(first.token.isCancelled, isFalse);
          expect(second.token.isCancelled, isFalse);
          if (action == 'late offer reaches consent expiry') {
            await tester.pump(const Duration(seconds: 1));
            expect(find.byType(BeamBufferWaitDialog), findsOneWidget);
            expect(find.textContaining('not enough progress to estimate'), findsOneWidget);
            expect(find.textContaining('About '), findsNothing, reason: 'The deferred ETA snapshot is stale');
            expect(answered, isFalse);
            await tester.tap(find.text('Keep buffering'));
            await tester.pump();
            expect(await secondDecision, isTrue);
          }
        }
        if (action == 'ready' || lateOffer) {
          second.complete();
        } else {
          first.complete();
        }
        await _until(tester, () => player != null);
        await tester.pumpAndSettle();
        expect(await operation!, isTrue);
        expect(find.byType(BeamBufferWaitDialog), findsNothing);
        expect(find.text('Fixture player'), findsOneWidget);
        expect(service.attempts.every((attempt) => !attempt.token.isCancelled), isTrue);
        final winner = action == 'ready' || lateOffer ? second : first;
        final loser = action == 'ready' || lateOffer ? first : second;
        expect(winner.commits, 0);
        player!.onDirectPlaybackStarted!();
        await tester.pump();
        expect(winner.commits, 1);
        expect(loser.token.isCancelled, isTrue);
        expect(winner.token.isCancelled, isFalse);
        expect(await decision, isTrue);
        if (secondDecision != null) expect(await secondDecision, isTrue);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(winner.token.isCancelled, isTrue);
        expect(winner.closes, 1);
        expect(find.text('Episode details'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
