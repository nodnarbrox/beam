import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/key_event_utils.dart';
import 'package:plezy/screens/youtube_account_screen.dart';
import 'package:plezy/screens/youtube_browse_screen.dart';
import 'package:plezy/screens/youtube_playback_screen.dart';
import 'package:plezy/services/youtube/youtube_service.dart';
import 'package:plezy/widgets/discovery_search_results.dart';
import 'package:shared_preferences/shared_preferences.dart';

const video = YouTubeVideo(id: 'video', title: 'Test video', author: 'Creator', channelId: 'channel');

class BackTestYouTube extends YouTubeService {
  @override
  Future<List<YouTubeChannel>> searchChannels(String query) async => [];
  BackTestYouTube({this.failPlayback = false});
  final bool failPlayback;
  @override
  Future<List<YouTubeVideo>> search(String query) async => [video];
  @override
  Future<YouTubePlayback> resolve(String id) =>
      failPlayback ? Future.error(StateError('Unavailable')) : Completer<YouTubePlayback>().future;
  @override
  void close() {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BackKeyCoordinator.clear();
  });

  for (final screen in ['search field', 'channel results', 'opening video', 'playback error', 'account']) {
    for (final key in [LogicalKeyboardKey.goBack, LogicalKeyboardKey.escape]) {
      testWidgets('$screen exits exactly one route with ${key.keyLabel}', (tester) async {
        final preferences = await SharedPreferences.getInstance();
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Root')),
          ),
        );
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Return here'))),
          ),
        );
        await tester.pumpAndSettle();
        final Widget target = switch (screen) {
          'search field' || 'channel results' => YouTubeBrowseScreen(
            query: screen == 'channel results' ? 'channel' : '',
            youtubeFactory: () => BackTestYouTube(),
          ),
          'account' => YouTubeAccountScreen(
            preferences: preferences,
            profileId: 'test',
            onPlay: (_) async {},
            onChannel: (_) {},
          ),
          _ => YouTubePlaybackScreen(
            video: video,
            youtubeFactory: () => BackTestYouTube(failPlayback: screen == 'playback error'),
          ),
        };
        unawaited(navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => target)));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        if (screen == 'search field') {
          await tester.tap(find.byType(TextField));
          await tester.pump();
        }
        if (screen == 'channel results') {
          expect(
            tester.widget<DiscoverySearchResults>(find.byType(DiscoverySearchResults)).firstFocus.hasFocus,
            isTrue,
          );
        }
        await tester.sendKeyDownEvent(key, physicalKey: PhysicalKeyboardKey.escape);
        await tester.sendKeyRepeatEvent(key, physicalKey: PhysicalKeyboardKey.escape);
        await tester.pump();
        expect(find.byWidget(target), findsOneWidget);
        await tester.sendKeyUpEvent(key, physicalKey: PhysicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Return here'), findsOneWidget);
        expect(navigator.currentState!.canPop(), isTrue);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
