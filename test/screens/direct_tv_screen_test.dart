import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/screens/livetv/direct_tv_screen.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/direct_tv_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/focus/focusable_text_field.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/utils/video_player_navigation.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/prefs.dart';

void main() {
  testWidgets('actual channel row opens the shared player as direct live TV with ExoPlayer preference', (tester) async {
    resetSharedPreferencesForTest();
    await (await SharedPreferences.getInstance()).setString('direct_tv_address', 'http://tv.test:8776');
    await SettingsService.getInstance();
    await SettingsService.instance.write(SettingsService.useExoPlayer, true);
    final backendRequests = <bool>[];
    VideoPlayerScreenState.playerFactoryOverride = ({required useExoPlayer}) {
      backendRequests.add(useExoPlayer);
      throw PlatformException(code: 'direct_tv_backend_probe');
    };
    addTearDown(() => VideoPlayerScreenState.playerFactoryOverride = null);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => PlaybackStateProvider(),
        child: MaterialApp(
          home: DirectTvScreen(
            serviceFactory: (address) => DirectTvService(
              address,
              client: MockClient(
                (request) async => http.Response(
                  jsonEncode(
                    request.url.path == '/health'
                        ? {}
                        : [
                            {'GuideNumber': '112', 'GuideName': 'History', 'URL': '$address/auto/v112'},
                          ],
                  ),
                  200,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('History'));
    for (var i = 0; i < 200 && backendRequests.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (backendRequests.isEmpty) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      }
    }

    expect(backendRequests, [true]);
    final playerFinder = find.byType(VideoPlayerScreen);
    final screen = tester.widget<VideoPlayerScreen>(playerFinder);
    expect(screen.directStreamIsLive, isTrue);
    expect(screen.isLive, isFalse, reason: 'Direct TV must not create a Plex/Jellyfin live session.');
    expect(screen.directVideoUrl, 'http://tv.test:8776/auto/v112');
    expect(ModalRoute.of(tester.element(playerFinder))?.settings.name, kVideoPlayerRouteName);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('TV remote leaves search and starts a channel without opening a keyboard on entry', (tester) async {
    SharedPreferences.setMockInitialValues({'direct_tv_address': 'http://tv.test:8776'});
    await TvDetectionService.getInstance(forceTv: true);
    TvDetectionService.setForceTVSync(true);
    addTearDown(() => TvDetectionService.setForceTVSync(false));
    DirectTvChannel? played;
    await tester.pumpWidget(
      MaterialApp(
        home: DirectTvScreen(
          serviceFactory: (address) => DirectTvService(
            address,
            client: MockClient(
              (request) async => http.Response(
                jsonEncode(
                  request.url.path == '/health'
                      ? {}
                      : [
                          {'GuideNumber': '112', 'GuideName': 'History', 'URL': '$address/auto/v112'},
                        ],
                ),
                200,
              ),
            ),
          ),
          playChannel: (_, channel) async {
            played = channel;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<FocusableTextField>(find.byType(FocusableTextField));
    field.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv_virtual_keyboard_panel')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'directTv.firstChannel');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(played?.number, '112');
    expect(tester.takeException(), isNull);
  });
  testWidgets('without Plex providers: search, filter, favorite, and open direct channel', (tester) async {
    SharedPreferences.setMockInitialValues({'direct_tv_address': 'http://tv.test:8776'});
    DirectTvChannel? played;
    await tester.pumpWidget(
      MaterialApp(
        home: DirectTvScreen(
          serviceFactory: (address) => DirectTvService(
            address,
            client: MockClient(
              (request) async => http.Response(
                jsonEncode(
                  request.url.path == '/health'
                      ? {
                          'preload_candidates': ['112', '20'],
                        }
                      : [
                          {'GuideNumber': '112', 'GuideName': 'History', 'URL': '$address/auto/v112'},
                          {'GuideNumber': '20', 'GuideName': 'A&E', 'URL': '$address/auto/v20'},
                          {'GuideNumber': '400', 'GuideName': 'Other channel', 'URL': '$address/auto/v400'},
                        ],
                ),
                200,
              ),
            ),
          ),
          playChannel: (_, channel) async {
            played = channel;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Plex / Jellyfin guide'), findsNothing);
    await tester.tap(find.text('Major networks'));
    await tester.pumpAndSettle();
    expect(find.text('Other channel'), findsNothing);
    await tester.enterText(find.byType(TextField), 'history');
    await tester.pumpAndSettle();
    expect(find.text('A&E'), findsNothing);
    await tester.tap(find.byTooltip('Add favorite'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('direct_tv_favorites:http://tv.test:8776'), ['112']);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(played?.stream.toString(), 'http://tv.test:8776/auto/v112');
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed request offers retry without Plex login', (tester) async {
    SharedPreferences.setMockInitialValues({'direct_tv_address': 'http://tv.test:8776'});
    await tester.pumpWidget(
      MaterialApp(
        home: DirectTvScreen(
          serviceFactory: (address) =>
              DirectTvService(address, client: MockClient((_) async => http.Response('down', 503))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byTooltip('TV service settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
