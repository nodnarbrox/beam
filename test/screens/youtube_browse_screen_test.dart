import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/youtube_browse_screen.dart';
import 'package:plezy/services/youtube/youtube_service.dart';
import 'package:plezy/widgets/discovery_search_results.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SlowYouTube extends YouTubeService {
  @override
  Future<List<YouTubeChannel>> searchChannels(String query) async => [];
  SlowYouTube(this.results, this.opened);
  final Future<List<YouTubeVideo>> results;
  final List<String> opened;
  @override
  Future<List<YouTubeVideo>> search(String query) => results;
  @override
  Future<YouTubePlayback> resolve(String id) {
    opened.add(id);
    return Completer<YouTubePlayback>().future;
  }

  @override
  void close() {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final initialQuery in ['', 'channel']) {
    testWidgets('slow results gain remote focus after ${initialQuery.isEmpty ? 'submission' : 'channel open'}', (
      tester,
    ) async {
      final results = Completer<List<YouTubeVideo>>();
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: YouTubeBrowseScreen(query: initialQuery, youtubeFactory: () => SlowYouTube(results.future, opened)),
        ),
      );
      if (initialQuery.isEmpty) {
        await tester.pump();
        expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isTrue);
        await tester.enterText(find.byType(TextField), 'bunny');
        await tester.testTextInput.receiveAction(TextInputAction.search);
      }
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      results.complete([const YouTubeVideo(id: 'video', title: 'Video', author: 'Creator', channelId: 'channel')]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final discovery = tester.widget<DiscoverySearchResults>(find.byType(DiscoverySearchResults));
      expect(discovery.firstFocus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(opened, ['video']);
      Navigator.of(tester.element(find.text('Opening video…'))).pop();
      await tester.pumpAndSettle();
      expect(discovery.firstFocus.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
