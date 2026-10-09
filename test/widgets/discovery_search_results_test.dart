import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/beam/plex_public_discover.dart';
import 'package:plezy/services/youtube/youtube_service.dart';
import 'package:plezy/services/youtube/youtube_library.dart';
import 'package:plezy/widgets/discovery_search_results.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeCatalog extends PlexPublicDiscover {
  @override
  Future<List<BeamDiscoverItem>> search(
    String query, {
    MediaKind? kind,
    int limit = 40,
    bool throwOnError = false,
  }) async {
    throw StateError('Catalog offline');
  }
}

class FakeYouTube extends YouTubeService {
  @override
  Future<List<YouTubeChannel>> searchChannels(String query) async => [];
  FakeYouTube(this.lookup, {this.onResolve});
  final Future<List<YouTubeVideo>> Function(String) lookup;
  final void Function(String)? onResolve;
  @override
  Future<List<YouTubeVideo>> search(String query) => lookup(query);
  @override
  Future<List<YouTubeVideo>> related(YouTubeVideo seed) => lookup(seed.id);
  @override
  Future<YouTubePlayback> resolve(String id) {
    onResolve?.call(id);
    return Completer<YouTubePlayback>().future;
  }

  @override
  void close() {}
}

YouTubeVideo video(String id) => YouTubeVideo(id: id, title: 'Video $id', author: 'Creator', channelId: 'channel');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final scope in [SearchScope.youtube, SearchScope.forYou, SearchScope.saved]) {
    testWidgets('${scope.name}: remote selects video rows and starts playback, without bookmark focus', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final library = YouTubeLibrary(prefs, 'local');
      await library.toggleSaved(video('second'));
      await library.toggleSaved(video('first'));
      final opened = <String>[];
      final focus = FocusNode();
      var movedLeft = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DiscoverySearchResults(
                query: scope == SearchScope.youtube ? 'bunny' : '',
                scope: scope,
                libraryItems: const [],
                firstFocus: focus,
                onNavigateLeft: () => movedLeft = true,
                onNavigateUp: () {},
                onQuery: (_) {},
                youtubeFactory: () =>
                    FakeYouTube((_) async => [video('result1'), video('result2')], onResolve: opened.add),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.bookmark), findsNothing);
      expect(find.byIcon(Icons.bookmark_border), findsNothing);
      expect(find.text('Play'), findsNWidgets(2));
      focus.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(movedLeft, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(opened, [scope == SearchScope.saved ? 'second' : 'result2']);
      expect(find.text('Opening video…'), findsOneWidget);
      expect(library.saved.map((v) => v.id), ['first', 'second']);
      Navigator.of(tester.element(find.text('Opening video…'))).pop();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      focus.dispose();
    });
  }

  testWidgets('tapping the Play affordance opens the video', (tester) async {
    final focus = FocusNode();
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DiscoverySearchResults(
            query: 'bunny',
            scope: SearchScope.youtube,
            libraryItems: const [],
            firstFocus: focus,
            onNavigateLeft: () {},
            onNavigateUp: () {},
            onQuery: (_) {},
            youtubeFactory: () => FakeYouTube((_) async => [video('first')], onResolve: opened.add),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(opened, ['first']);
    expect(find.text('Opening video…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    focus.dispose();
  });

  testWidgets('YouTube remains usable when movie catalog fails', (tester) async {
    final focus = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DiscoverySearchResults(
              query: 'bunny',
              scope: SearchScope.all,
              libraryItems: const [],
              firstFocus: focus,
              onNavigateLeft: () {},
              onNavigateUp: () {},
              onQuery: (_) {},
              catalog: FakeCatalog(),
              youtubeFactory: () => FakeYouTube((_) async => [video('first')]),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('Video first'), findsOneWidget);
    expect(find.text('Movie and TV search is unavailable. Try again.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    focus.dispose();
  });

  testWidgets('late results from a previous query cannot replace current videos', (tester) async {
    final focus = FocusNode();
    final old = Completer<List<YouTubeVideo>>();
    final current = Completer<List<YouTubeVideo>>();
    Widget screen(String query) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DiscoverySearchResults(
            query: query,
            scope: SearchScope.youtube,
            libraryItems: const [],
            firstFocus: focus,
            onNavigateLeft: () {},
            onNavigateUp: () {},
            onQuery: (_) {},
            youtubeFactory: () => FakeYouTube((q) => q == 'old' ? old.future : current.future),
          ),
        ),
      ),
    );
    await tester.pumpWidget(screen('old'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(screen('current'));
    await tester.pump(const Duration(milliseconds: 500));
    current.complete([video('current')]);
    await tester.pumpAndSettle();
    old.complete([video('old')]);
    await tester.pumpAndSettle();
    expect(find.text('Video current'), findsOneWidget);
    expect(find.text('Video old'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    focus.dispose();
  });
}
