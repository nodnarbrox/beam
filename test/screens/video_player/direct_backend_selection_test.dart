import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  tearDown(() {
    VideoPlayerScreenState.playerFactoryOverride = null;
  });

  for (final scenario
      in <({String name, bool preferredExo, bool direct, bool directLive, String? audioUrl, bool expectedExo})>[
        (
          name: 'direct movie retains MPV even with ExoPlayer preference',
          preferredExo: true,
          direct: true,
          directLive: false,
          audioUrl: null,
          expectedExo: false,
        ),
        (
          name: 'muxed direct stream honors MPV opt-out',
          preferredExo: false,
          direct: true,
          directLive: false,
          audioUrl: null,
          expectedExo: false,
        ),
        (
          name: 'separate direct audio retains MPV support',
          preferredExo: true,
          direct: true,
          directLive: false,
          audioUrl: 'https://fixture/audio.m4a',
          expectedExo: false,
        ),
        (
          name: 'direct live TV honors ExoPlayer preference',
          preferredExo: true,
          direct: true,
          directLive: true,
          audioUrl: null,
          expectedExo: true,
        ),
        (
          name: 'direct live TV honors MPV opt-out',
          preferredExo: false,
          direct: true,
          directLive: true,
          audioUrl: null,
          expectedExo: false,
        ),
        (
          name: 'separate audio retains MPV even for a direct live stream',
          preferredExo: true,
          direct: true,
          directLive: true,
          audioUrl: 'https://fixture/audio.m4a',
          expectedExo: false,
        ),
        (
          name: 'server media retains ExoPlayer preference',
          preferredExo: true,
          direct: false,
          directLive: false,
          audioUrl: null,
          expectedExo: true,
        ),
      ]) {
    testWidgets(scenario.name, (tester) async {
      await SettingsService.instance.write(SettingsService.useExoPlayer, scenario.preferredExo);
      final requestedBackends = <bool>[];
      var directFailures = 0;
      var directStarts = 0;
      VideoPlayerScreenState.playerFactoryOverride = ({required useExoPlayer}) {
        requestedBackends.add(useExoPlayer);
        // Capture the decision dispatched by the real initialization path,
        // then stop before native or server dependencies. The native factory
        // itself uses dart:io Platform and cannot select Android on this host.
        throw PlatformException(code: 'backend_selection_probe');
      };
      final screen = scenario.direct
          ? VideoPlayerScreen.direct(
              url: 'https://fixture/video.mp4',
              audioUrl: scenario.audioUrl,
              directStreamIsLive: scenario.directLive,
              onPlaybackStarted: () => directStarts++,
              onPlaybackFailed: () => directFailures++,
            )
          : VideoPlayerScreen(metadata: testMediaItem(title: 'Server movie'));
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => PlaybackStateProvider(),
          child: MaterialApp(home: screen),
        ),
      );
      await _pumpUntil(tester, () => find.widgetWithText(FilledButton, 'Retry').evaluate().isNotEmpty);

      expect(requestedBackends, [scenario.expectedExo]);
      expect(directStarts, 0);
      expect(directFailures, scenario.direct ? 1 : 0);
      expect(SettingsService.instance.read(SettingsService.useExoPlayer), scenario.preferredExo);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
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
