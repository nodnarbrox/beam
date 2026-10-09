import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:plezy/services/network_artwork_provider.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/utils/media_image_helper.dart';
import 'package:plezy/widgets/optimized_media_image.dart';

void main() {
  setUp(() {
    NetworkArtworkProvider.clientOverride = MockClient(
      (request) async => request.url.path.contains('broken-actor')
          ? http.Response('', 404)
          : http.Response.bytes(
              base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
              ),
              200,
            ),
    );
  });
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    NetworkArtworkProvider.clientOverride?.close();
    NetworkArtworkProvider.clientOverride = null;
  });
  testWidgets('network widget matches the shared server artwork provider', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const imageUrl = 'https://example.invalid/episode-thumb.jpg';

    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 160,
          height: 90,
          child: OptimizedMediaImage.thumb(imagePath: imageUrl, width: 160, height: 90),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    final widgetProvider = image.image as ResizeImage;
    final widgetCached = widgetProvider.imageProvider as NetworkArtworkProvider;
    final sharedProvider =
        MediaImageHelper.serverArtworkProvider(imageUrl: imageUrl, memWidth: 200, memHeight: 180) as ResizeImage;
    final sharedCached = sharedProvider.imageProvider as NetworkArtworkProvider;

    expect(widgetCached, sharedCached);
    expect(widgetProvider.width, sharedProvider.width);
    expect(widgetProvider.width, 200);
    expect(widgetProvider.height, sharedProvider.height);
    expect(widgetProvider.height, 180);
    expect(widgetProvider.policy, sharedProvider.policy);
    expect(widgetProvider.policy, ResizeImagePolicy.fit);
    expect(widgetProvider.allowUpscaling, sharedProvider.allowUpscaling);
    expect(widgetProvider.allowUpscaling, isFalse);
    expect(widgetCached.url, sharedCached.url);
    expect(widgetCached.url, imageUrl);
    expect(widgetCached.cacheKey, sharedCached.cacheKey);
    expect(widgetCached.cacheKey, isNotNull);
    expect(widgetCached.headers, sharedCached.headers);
    expect(widgetCached.headers, const {'User-Agent': 'Plezy'});
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('artwork dim tints image and fallback paint', (tester) async {
    final artworkDim = AnimationController(vsync: tester);
    addTearDown(artworkDim.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 160,
          height: 90,
          child: OptimizedMediaImage.thumb(
            imagePath: 'https://example.invalid/dimmed-thumb.jpg',
            width: 160,
            height: 90,
            artworkDim: artworkDim,
          ),
        ),
      ),
    );

    expect(tester.widget<Image>(find.byType(Image)).color, isNull);

    artworkDim.value = 0.3;
    await tester.pump();

    final dimmedImage = tester.widget<Image>(find.byType(Image));
    expect(dimmedImage.color, Colors.black.withValues(alpha: 0.3));
    expect(dimmedImage.colorBlendMode, BlendMode.srcATop);

    artworkDim.value = 0;
    await tester.pump();

    final restoredImage = tester.widget<Image>(find.byType(Image));
    expect(restoredImage.color, isNull);
    expect(restoredImage.colorBlendMode, isNull);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 160,
          height: 90,
          child: OptimizedMediaImage.thumb(imagePath: null, width: 160, height: 90, artworkDim: artworkDim),
        ),
      ),
    );
    final placeholderFinder = find.descendant(of: find.byType(OptimizedMediaImage), matching: find.byType(Container));
    final baseColor = tester.widget<Container>(placeholderFinder).color!;

    artworkDim.value = 0.3;
    await tester.pump();

    expect(
      tester.widget<Container>(placeholderFinder).color,
      Color.alphaBlend(Colors.black.withValues(alpha: 0.3), baseColor),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('failed image placeholders keep explicit dimensions in loose layouts', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OptimizedMediaImage(
                  client: null,
                  imagePath: 'https://example.invalid/broken-actor-image.jpg',
                  width: 96,
                  height: 96,
                  imageType: ImageType.avatar,
                  fallbackIcon: Symbols.person_rounded,
                ),
                const SizedBox(height: 8),
                const Text('Actor Name'),
              ],
            ),
          ),
        ),
      ),
    );

    for (var attempt = 0; attempt < 50 && PaintingBinding.instance.imageCache.pendingImageCount > 0; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(PaintingBinding.instance.imageCache.pendingImageCount, 0);
    await tester.pumpAndSettle();

    expect(find.byIcon(Symbols.person_rounded), findsOneWidget);

    final placeholder = find.descendant(of: find.byType(OptimizedMediaImage), matching: find.byType(Container));
    expect(placeholder, findsOneWidget);
    expect(tester.getSize(placeholder), const Size(96, 96));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('local resolver rejects stale path completions and disposal completions', (tester) async {
    final checks = <String, Completer<bool>>{};
    final probes = <String, int>{};
    var path = '/artwork/a.png';
    late StateSetter rebuild;
    Future<bool> fileExists(File file) {
      probes.update(file.path, (count) => count + 1, ifAbsent: () => 1);
      return (checks[file.path] ??= Completer<bool>()).future;
    }

    Widget resolutionBuilder(BuildContext context, LocalFileResolution resolution, File? file) {
      return Text('${resolution.name}:${file?.path ?? path}');
    }

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return ResolvedLocalFile(path: path, fileExists: fileExists, builder: resolutionBuilder);
          },
        ),
      ),
    );
    expect(find.text('pending:/artwork/a.png'), findsOneWidget);

    rebuild(() => path = '/artwork/b.png');
    await tester.pump();
    rebuild(() {});
    await tester.pump();
    expect(find.text('pending:/artwork/b.png'), findsOneWidget);
    expect(probes['/artwork/b.png'], 1);

    checks['/artwork/a.png']!.complete(true);
    await tester.pump();
    expect(find.text('pending:/artwork/b.png'), findsOneWidget);

    checks['/artwork/b.png']!.complete(true);
    await tester.pump();
    await tester.pump();
    expect(find.text('present:/artwork/b.png'), findsOneWidget);

    rebuild(() => path = '/artwork/c.png');
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    checks['/artwork/c.png']!.complete(true);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('local resolver caches confirmed missing paths only when requested', (tester) async {
    final probes = <String, int>{};
    var path = '/artwork/missing-a.png';
    late StateSetter rebuild;
    Future<bool> fileExists(File file) {
      probes.update(file.path, (count) => count + 1, ifAbsent: () => 1);
      return Future<bool>.value(false);
    }

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return ResolvedLocalFile(
              path: path,
              cacheMissing: true,
              fileExists: fileExists,
              builder: (context, resolution, file) => Text('${resolution.name}:$path'),
            );
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.text('missing:/artwork/missing-a.png'), findsOneWidget);
    expect(probes['/artwork/missing-a.png'], 1);

    rebuild(() {});
    await tester.pump();
    rebuild(() {});
    await tester.pump();
    expect(probes['/artwork/missing-a.png'], 1);

    rebuild(() => path = '/artwork/missing-b.png');
    await tester.pump();
    await tester.pump();
    expect(probes['/artwork/missing-b.png'], 1);

    rebuild(() => path = '/artwork/missing-a.png');
    await tester.pump();
    expect(find.text('missing:/artwork/missing-a.png'), findsOneWidget);
    expect(probes['/artwork/missing-a.png'], 1);
  });

  testWidgets('same local artwork path re-resolves after the file appears', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final directory = Directory.systemTemp.createTempSync('plezy-image-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/poster.png');
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return OptimizedMediaImage.thumb(
              imagePath: null,
              localFilePath: file.path,
              width: 80,
              height: 120,
              fallbackIcon: Symbols.image_not_supported_rounded,
            );
          },
        ),
      ),
    );

    expect(find.byIcon(Symbols.image_not_supported_rounded), findsNothing);
    // Real filesystem completion can take more than one event-loop turn on
    // Windows under full-suite load. Wait for the observable resolver result.
    for (
      var attempt = 0;
      attempt < 100 && find.byIcon(Symbols.image_not_supported_rounded).evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(find.byIcon(Symbols.image_not_supported_rounded), findsOneWidget);

    file.writeAsBytesSync(
      base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='),
      flush: true,
    );
    rebuild(() {});
    await tester.pump();

    expect(find.byIcon(Symbols.image_not_supported_rounded), findsNothing);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    await tester.pump();
    expect(file.existsSync(), isTrue);
    expect(find.byIcon(Symbols.image_not_supported_rounded), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    final localImage = tester.widget<Image>(find.byType(Image));
    final localResize = localImage.image as ResizeImage;
    final localProvider = localResize.imageProvider as FileImage;
    expect(localResize.width, 120);
    expect(localResize.height, 180);
    expect(localResize.policy, ResizeImagePolicy.fit);
    expect(localProvider.file.path, file.path);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
