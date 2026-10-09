import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:provider/provider.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });
  testWidgets('fatal direct-player initialization reports failure without claiming first frame', (tester) async {
    var failed = 0;
    var started = 0;
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) {
        if (call.method == 'observeProperty') {
          throw PlatformException(code: 'forced_startup_failure');
        }
        return Future<Object?>.value(call.method == 'initialize' ? true : null);
      },
      eventHandler: (_) async => null,
      testBody: () async {
        await tester.pumpWidget(
          ChangeNotifierProvider(
            create: (_) => PlaybackStateProvider(),
            child: MaterialApp(
              home: VideoPlayerScreen.direct(
                url: 'https://fixture/video.mp4',
                title: 'Fixture',
                playbackNotice: 'Combined file fixture notice',
                onPlaybackStarted: () => started++,
                onPlaybackFailed: () => failed++,
              ),
            ),
          ),
        );
        await _pumpUntil(tester, () => failed > 0);
        expect(failed, 1);
        expect(started, 0);
        expect(
          find.text('Combined file fixture notice'),
          findsNothing,
          reason: 'A combined-file notice must not claim playback before a first frame.',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (!condition()) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
  }
  expect(condition(), isTrue);
}
