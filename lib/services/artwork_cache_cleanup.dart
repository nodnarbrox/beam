import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Removes only the retired artwork cache directories. No cache manager is
/// constructed, so clearing artwork cannot recreate a disk cache.
class ArtworkCacheCleanup {
  ArtworkCacheCleanup({Future<Directory> Function()? applicationCache, Future<Directory> Function()? temporary})
    : _applicationCache = applicationCache ?? getApplicationCacheDirectory,
      _temporary = temporary ?? getTemporaryDirectory;

  static final instance = ArtworkCacheCleanup();
  final Future<Directory> Function() _applicationCache;
  final Future<Directory> Function() _temporary;
  Future<void>? _pending;

  Future<void> migrate({required bool alreadyComplete, required Future<void> Function() markComplete}) async {
    if (alreadyComplete) return;
    await clearLegacyDiskCaches();
    // A failed lookup, validation, deletion, or marker write remains retryable.
    await markComplete();
  }

  Future<void> clearLegacyDiskCaches() => _pending ??= _clear().whenComplete(() => _pending = null);

  Future<void> _clear() async {
    final applicationCache = await _applicationCache();
    final temporary = await _temporary();
    final targets = <String>{};
    for (final (base, name) in [
      (applicationCache, 'cached_network_image_ce'),
      (temporary, 'cached_network_image_ce'),
      (temporary, 'plexImageCache'),
    ]) {
      // Platform directory providers return existing bases. Resolve failures
      // (including access errors) must not be mistaken for a completed cleanup.
      final canonicalBase = p.normalize(await base.resolveSymbolicLinks());
      final target = p.normalize(p.join(canonicalBase, name));
      if (!p.isWithin(canonicalBase, target) || p.equals(canonicalBase, target)) {
        throw FileSystemException('Artwork cache target is outside its base', target);
      }
      if (!targets.add(Platform.isWindows ? target.toLowerCase() : target)) continue;
      final type = await FileSystemEntity.type(target, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException('Artwork cache target is not an ordinary directory', target);
      }
      await _remove(target, target, canonicalBase);
    }
  }

  Future<void> _remove(String path, String root, String base) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory && type != FileSystemEntityType.file) {
      throw FileSystemException('Refusing linked artwork cache entry', path);
    }
    // Resolve every entry, including Windows junctions/reparse points. A
    // lexical descendant alone does not establish that deletion stays inside.
    final resolved = p.normalize(await File(path).resolveSymbolicLinks());
    if (!p.equals(resolved, p.normalize(path)) ||
        !p.isWithin(base, resolved) ||
        !(p.equals(root, resolved) || p.isWithin(root, resolved))) {
      throw FileSystemException('Refusing redirected artwork cache entry', path);
    }
    if (type == FileSystemEntityType.directory) {
      await for (final child in Directory(path).list(followLinks: false)) {
        await _remove(child.path, root, base);
      }
      // Never recursively delete: a newly inserted link or file causes a
      // failure instead of traversal. The next startup can retry safely.
      await Directory(path).delete();
    } else {
      await File(path).delete();
    }
  }
}
