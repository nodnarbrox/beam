import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/youtube_browse_screen.dart';
import 'package:plezy/services/youtube/youtube_service.dart';
import 'package:plezy/services/youtube/youtube_library.dart';
import 'package:plezy/widgets/youtube_channel_avatar.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ChannelSearchService extends YouTubeService {
  ChannelSearchService({this.failVideos = false});
  final bool failVideos;
  @override
  Future<List<YouTubeChannel>> searchChannels(String query) async => query == 'creator'
      ? [const YouTubeChannel(id: 'UCcreator', title: 'The Creator', avatarUrl: 'https://yt3.ggpht.com/avatar')]
      : [];
  @override
  Future<List<YouTubeVideo>> search(String query) async {
    if (query == 'creator' && failVideos) throw StateError('Video endpoint offline');
    return [const YouTubeVideo(id: 'v', title: 'Creator video', author: 'Creator', channelId: 'UCcreator')];
  }

  @override
  void close() {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final failVideos in [false, true]) {
    testWidgets('channel avatar, remote open and Back work with video failure=$failVideos', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: YouTubeBrowseScreen(
            query: 'creator',
            youtubeFactory: () => ChannelSearchService(failVideos: failVideos),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        tester.widget<YouTubeChannelAvatar>(find.byType(YouTubeChannelAvatar)).url,
        'https://yt3.ggpht.com/avatar',
      );
      expect(find.text('View channel'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('The Creator'), findsOneWidget);
      expect(find.text('Creator video'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(YouTubeLibrary(prefs, 'local').viewedChannels, ['UCcreator']);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('View channel'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('missing avatar shows a channel initial', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: YouTubeChannelAvatar(title: 'Nate')),
      ),
    );
    expect(find.text('N'), findsOneWidget);
  });
}
