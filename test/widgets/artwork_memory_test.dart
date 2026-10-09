import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/artwork_memory.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/network_artwork_provider.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/widgets/cycling_media_backdrop.dart';
import 'package:plezy/widgets/network_artwork.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:plezy/widgets/optimized_media_image.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 60 && !condition(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
}

Widget _artwork() => const Column(
  children: [
    NetworkArtwork(imageUrl: 'https://fixture/poster', width: 20, height: 20),
    OptimizedMediaImage(imagePath: 'https://fixture/thumb', width: 20, height: 20),
    SizedBox(
      width: 20,
      height: 20,
      child: CyclingMediaBackdrop(
        mediaKey: 'show',
        imagePaths: ['https://fixture/backdrop'],
        client: null,
        width: 20,
        height: 20,
        fallbackColor: Colors.black,
      ),
    ),
  ],
);

void main() {
  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    NetworkArtworkProvider.clientOverride = MockClient((_) async => http.Response.bytes(_png, 200));
  });
  tearDown(() {
    NetworkArtworkProvider.clientOverride = null;
  });

  testWidgets('playback owners detach all browsing images, clear live RAM, and restore artwork', (tester) async {
    final first = Object();
    final replacement = Object();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: _artwork())));
    await _until(
      tester,
      () =>
          PaintingBinding.instance.imageCache.liveImageCount >= 3 &&
          PaintingBinding.instance.imageCache.currentSizeBytes >= 12,
    );
    final before = PaintingBinding.instance.imageCache.currentSizeBytes;
    expect(find.byType(Image), findsNWidgets(3));
    ArtworkMemory.acquirePlayback(first);
    ArtworkMemory.acquirePlayback(first); // Idempotent ownership.
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(PaintingBinding.instance.imageCache.currentSizeBytes, 0);
    expect(PaintingBinding.instance.imageCache.liveImageCount, 0);
    ArtworkMemory.acquirePlayback(replacement);
    ArtworkMemory.releasePlayback(first);
    await tester.pump();
    expect(ArtworkMemory.isSuspended, isTrue);
    expect(find.byType(Image), findsNothing);
    ArtworkMemory.releasePlayback(replacement);
    await tester.pump();
    await tester.pump();
    await _until(tester, () => PaintingBinding.instance.imageCache.currentSizeBytes > 0);
    expect(find.byType(Image), findsNWidgets(3));
    debugPrint(
      'Artwork fixture: decoded bytes before=$before, during=0, after=${PaintingBinding.instance.imageCache.currentSizeBytes}; live images before=3, during=0, after=${PaintingBinding.instance.imageCache.liveImageCount}',
    );
    expect(before, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('player-owned thumbnails remain decoded while browsing images are suspended', (tester) async {
    final owner = Object();
    ArtworkMemory.acquirePlayback(owner);
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            OptimizedMediaImage.thumb(imagePath: 'https://fixture/browse', width: 20, height: 20),
            OptimizedMediaImage.thumb(
              imagePath: 'https://fixture/player',
              width: 20,
              height: 20,
              isBrowsingArtwork: false,
            ),
          ],
        ),
      ),
    );
    await _until(tester, () => PaintingBinding.instance.imageCache.currentSizeBytes > 0);
    expect(find.byType(Image), findsOneWidget);
    expect(PaintingBinding.instance.imageCache.liveImageCount, 1);
    await tester.pumpWidget(const SizedBox());
    ArtworkMemory.releasePlayback(owner);
    await tester.pump();
  });

  testWidgets('same-frame acquisition and disposal does not interrupt artwork', (tester) async {
    final owner = Object();
    await tester.pumpWidget(MaterialApp(home: _artwork()));
    ArtworkMemory.acquirePlayback(owner);
    ArtworkMemory.releasePlayback(owner);
    await tester.pump();
    expect(ArtworkMemory.isSuspended, isFalse);
    expect(find.byType(Image), findsNWidgets(3));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('suspension aborts a browsing request while direct trickplay still decodes', (tester) async {
    final owner = Object();
    final held = Completer<http.StreamedResponse>();
    final aborted = Completer<void>();
    NetworkArtworkProvider.clientOverride = MockClient.streaming((request, _) {
      if (request.url.path == '/held') {
        (request as http.AbortableRequest).abortTrigger!.then((_) => aborted.complete());
        return held.future;
      }
      return Future.value(http.StreamedResponse(Stream.value(_png), 200));
    });
    await tester.pumpWidget(const MaterialApp(home: NetworkArtwork(imageUrl: 'https://fixture/held')));
    await tester.pump();
    ArtworkMemory.acquirePlayback(owner);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(aborted.isCompleted, isTrue);
    // A direct provider is used by player trickplay, not a browsing widget.
    await tester.pumpWidget(MaterialApp(home: Image(image: NetworkArtworkProvider('https://fixture/trickplay'))));
    await _until(tester, () => PaintingBinding.instance.imageCache.currentSizeBytes > 0);
    expect(find.byType(RawImage), findsOneWidget);
    held.complete(http.StreamedResponse(Stream.value(_png), 200));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    ArtworkMemory.releasePlayback(owner);
    await tester.pump();
  });

  testWidgets('actual player route suspends retained browsing artwork and Back restores it', (tester) async {
    resetSharedPreferencesForTest();
    SharedPreferences.setMockInitialValues({});
    SettingsService.resetForTesting();
    final initialize = Completer<bool>();
    final navigator = GlobalKey<NavigatorState>();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) => call.method == 'initialize' ? initialize.future : Future<Object?>.value(null),
      testBody: () async {
        await tester.pumpWidget(
          ChangeNotifierProvider(
            create: (_) => PlaybackStateProvider(),
            child: MaterialApp(
              navigatorKey: navigator,
              home: Scaffold(body: _artwork()),
            ),
          ),
        );
        await _until(tester, () => PaintingBinding.instance.imageCache.currentSizeBytes > 0);
        const identity = BeamEpisodeIdentity(showId: 'pioneer', showTitle: 'Pioneer One', season: 1, episode: 1);
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => VideoPlayerScreen.direct(
                url: 'https://fixture/video',
                title: 'Pioneer One',
                metadata: identity.playerMetadata,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(ArtworkMemory.isSuspended, isTrue);
        expect(PaintingBinding.instance.imageCache.currentSizeBytes, 0);
        expect(PaintingBinding.instance.imageCache.liveImageCount, 0);
        tester.widget<OverlaySheetHost>(find.byType(OverlaySheetHost)).onSystemBack!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        await tester.pump();
        await _until(tester, () => !ArtworkMemory.isSuspended);
        await _until(tester, () => PaintingBinding.instance.imageCache.currentSizeBytes > 0);
        await tester.pumpWidget(const SizedBox());
        initialize.complete(true);
        await tester.pump();
      },
    );
  });
}
