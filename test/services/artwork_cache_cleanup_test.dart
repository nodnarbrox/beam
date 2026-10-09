import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plezy/services/artwork_cache_cleanup.dart';

void main() {
  late Directory root;
  late Directory app;
  late Directory temporary;
  late ArtworkCacheCleanup cleanup;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('plezy-artwork-cleanup-test-');
    app = await Directory(p.join(root.path, 'app')).create();
    temporary = await Directory(p.join(root.path, 'temporary')).create();
    cleanup = ArtworkCacheCleanup(applicationCache: () async => app, temporary: () async => temporary);
  });
  tearDown(() async {
    // The generated test root is the only recursive test cleanup target.
    final absolute = p.normalize(root.absolute.path);
    expect(p.isWithin(p.normalize(Directory.systemTemp.absolute.path), absolute), isTrue);
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> write(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    return file.writeAsString('preserved or cached artwork');
  }

  test('deletes only three exact artwork directories and preserves all other stores and bases', () async {
    final targets = [
      p.join(app.path, 'cached_network_image_ce'),
      p.join(temporary.path, 'cached_network_image_ce'),
      p.join(temporary.path, 'plexImageCache'),
    ];
    for (final target in targets) {
      await write(p.join(target, 'nested', 'image.jpg'));
    }
    final protected = [
      for (final base in [app, temporary])
        for (final name in [
          'downloads/video.mkv',
          'artwork/offline.jpg',
          'database.sqlite',
          'profile/avatar.png',
          'cached_network_image_ce-other/keep.jpg',
          'plexImageCache-other/keep.jpg',
        ])
          await write(p.join(base.path, name)),
      await write(p.join(app.path, 'plexImageCache', 'keep.jpg')),
    ];
    await cleanup.clearLegacyDiskCaches();
    for (final target in targets) {
      expect(await Directory(target).exists(), isFalse);
    }
    for (final file in protected) {
      expect(await file.readAsString(), 'preserved or cached artwork');
    }
    expect(await app.exists(), isTrue);
    expect(await temporary.exists(), isTrue);
  });

  test('identical cache and temporary bases are deduplicated and repeated clears are harmless', () async {
    cleanup = ArtworkCacheCleanup(applicationCache: () async => temporary, temporary: () async => temporary);
    await write(p.join(temporary.path, 'cached_network_image_ce', 'image.jpg'));
    await write(p.join(temporary.path, 'plexImageCache', 'image.jpg'));
    await Future.wait([cleanup.clearLegacyDiskCaches(), cleanup.clearLegacyDiskCaches()]);
    await cleanup.clearLegacyDiskCaches();
    expect(await temporary.exists(), isTrue);
    expect(await temporary.list().toList(), isEmpty);
  });

  test('completed migration skips filesystem providers entirely', () async {
    cleanup = ArtworkCacheCleanup(
      applicationCache: () => throw StateError('must not resolve directories'),
      temporary: () => throw StateError('must not resolve directories'),
    );
    var marks = 0;
    await cleanup.migrate(alreadyComplete: true, markComplete: () async => marks++);
    expect(marks, 0);
  });

  test('failed cleanup does not mark migration and the next attempt retries successfully', () async {
    final wrongType = await write(p.join(app.path, 'cached_network_image_ce'));
    var marks = 0;
    await expectLater(
      cleanup.migrate(alreadyComplete: false, markComplete: () async => marks++),
      throwsA(isA<FileSystemException>()),
    );
    expect(marks, 0);
    expect(await wrongType.exists(), isTrue);
    await wrongType.delete();
    await write(p.join(app.path, 'cached_network_image_ce', 'image.jpg'));
    await cleanup.migrate(alreadyComplete: false, markComplete: () async => marks++);
    expect(marks, 1);
    expect(await Directory(p.join(app.path, 'cached_network_image_ce')).exists(), isFalse);
  });

  test('directory provider failure leaves migration retryable', () async {
    var fail = true;
    var marks = 0;
    cleanup = ArtworkCacheCleanup(
      applicationCache: () async {
        if (fail) throw const FileSystemException('platform cache path unavailable');
        return app;
      },
      temporary: () async => temporary,
    );
    await expectLater(
      cleanup.migrate(alreadyComplete: false, markComplete: () async => marks++),
      throwsA(isA<FileSystemException>()),
    );
    expect(marks, 0);
    fail = false;
    await cleanup.migrate(alreadyComplete: false, markComplete: () async => marks++);
    expect(marks, 1);
  });

  for (final nested in [false, true]) {
    test('refuses ${nested ? "nested" : "root"} symbolic link without touching its target', () async {
      final outside = await write(p.join(root.path, 'protected-downloads', 'video.mkv'));
      final cache = Directory(p.join(app.path, 'cached_network_image_ce'));
      if (nested) await cache.create();
      final link = Link(nested ? p.join(cache.path, 'redirect') : cache.path);
      try {
        await link.create(outside.parent.path);
      } on FileSystemException catch (error) {
        markTestSkipped('Host cannot create a directory link: ${error.osError?.errorCode}');
        return;
      }
      var marked = false;
      try {
        await expectLater(
          cleanup.migrate(alreadyComplete: false, markComplete: () async => marked = true),
          throwsA(isA<FileSystemException>()),
        );
        expect(marked, isFalse);
        expect(await outside.readAsString(), 'preserved or cached artwork');
        expect(await link.exists(), isTrue);
      } finally {
        await link.delete();
      }
    });
  }
}
