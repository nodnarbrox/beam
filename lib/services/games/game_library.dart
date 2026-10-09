import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../beam/rclone_service.dart';
import '../../utils/app_logger.dart';

class LibraryGame {
  LibraryGame(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get title => data['title'] as String;
  String get system => data['system'] as String;
  String get systemName => data['systemName'] as String;
  String? get cover => data['cover'] as String?;
  String? get background => data['background'] as String?;
}

class GameCancelled implements Exception {}

/// A catalog and a bounded, disposable ROM cache. Saves never live in the cache.
class GameLibrary {
  GameLibrary(this.prefs, this.profile, {http.Client? client}) : client = client ?? http.Client();
  final SharedPreferences prefs;
  final String profile;
  final http.Client client;
  static const channel = MethodChannel('plezy/games');
  static final rainbow3d = LibraryGame({
    'id': 'rainbow-overdrive-3d',
    'title': 'Rainbow Overdrive 3D',
    'system': 'android',
    'systemName': 'Android TV',
    'description':
        'Coastal racing with your custom garage, changing weather, night lighting and two-player split screen.',
    'genre': 'Racing',
    'players': '1-2',
    'year': '2026',
  });
  String get base =>
      (prefs.getString('games.url') ?? const String.fromEnvironment('PLEZY_GAMES_URL')).replaceAll(RegExp(r'/+$'), '');
  String get token => prefs.getString('games.token') ?? const String.fromEnvironment('PLEZY_GAMES_TOKEN');
  Map<String, String> get headers => {'Authorization': 'Bearer $token'};
  String get profileKey => sha256.convert(utf8.encode(profile)).toString().substring(0, 24);
  String get _key => 'games.$profileKey';
  int get cacheMB => prefs.getInt('games.cacheMB') ?? 2048;
  String get shader => prefs.getString('games.shader') ?? 'sharp';
  Process? _transfer;
  bool _cancelled = false;
  bool _playing = false;
  void cancel() {
    _cancelled = true;
    _transfer?.kill();
  }

  void close() {
    cancel();
    client.close();
  }

  void _check() {
    if (_cancelled) throw GameCancelled();
  }

  String imageUrl(String path) => '$base/files/${path.split('/').map(Uri.encodeComponent).join('/')}';
  Future<Map<String, dynamic>> get(String route, [Map<String, String>? query]) async {
    if (base.isEmpty) throw StateError('Set your game library address in Games settings.');
    final uri = Uri.parse('$base/$route').replace(queryParameters: query);
    final response = await client.get(uri, headers: headers).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw StateError('Game library is unavailable (${response.statusCode}).');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> catalog({String system = '', String query = '', int offset = 0}) =>
      get('catalog', {'system': system, 'q': query, 'offset': '$offset', 'limit': '60'});
  List<LibraryGame> saved(String kind) => (prefs.getStringList('$_key.$kind') ?? [])
      .map((s) => LibraryGame(jsonDecode(s) as Map<String, dynamic>))
      .toList();
  Future<void> remember(LibraryGame game) async {
    final games = saved('recent')..removeWhere((g) => g.id == game.id);
    games.insert(0, game);
    await prefs.setStringList('$_key.recent', games.take(24).map((g) => jsonEncode(g.data)).toList());
  }

  bool isFavorite(LibraryGame game) => saved('favorites').any((g) => g.id == game.id);
  Future<void> favorite(LibraryGame game) async {
    final games = saved('favorites');
    if (games.any((g) => g.id == game.id)) {
      games.removeWhere((g) => g.id == game.id);
    } else {
      games.add(game);
    }
    await prefs.setStringList('$_key.favorites', games.map((g) => jsonEncode(g.data)).toList());
  }

  static String safeRelative(String raw) {
    if (raw.isEmpty ||
        raw.contains('\\') ||
        raw.startsWith('/') ||
        raw.split('/').any((s) => s == '..' || s == '.' || s.isEmpty) ||
        raw.contains(':')) {
      throw const FormatException('Invalid game path.');
    }
    return raw;
  }

  static Future<int> directorySize(Directory dir) async {
    if (!await dir.exists()) return 0;
    var size = 0;
    await for (final file in dir.list(recursive: true, followLinks: false)) {
      if (file is File) size += await file.length();
    }
    return size;
  }

  Future<void> _space(Directory cache, Directory current, int needed, int free) async {
    await cache.create(recursive: true);
    var used = await directorySize(cache);
    final old = await cache
        .list(followLinks: false)
        .where((f) => f is Directory && f.path != current.path)
        .cast<Directory>()
        .toList();
    final dates = <String, DateTime>{};
    for (final d in old) {
      final marker = File(p.join(d.path, 'ready.json'));
      dates[d.path] = (await marker.exists() ? await marker.stat() : await d.stat()).modified;
    }
    old.sort((a, b) => dates[a.path]!.compareTo(dates[b.path]!));
    for (final d in old) {
      if (used + needed <= cacheMB * 1024 * 1024 && free - needed >= 128 * 1024 * 1024) break;
      final bytes = await directorySize(d);
      // Only generated game-id directories directly under the cache may be evicted.
      if (!RegExp(r'^[a-f0-9]{24}$').hasMatch(p.basename(d.path))) continue;
      await d.delete(recursive: true);
      used -= bytes;
      free += bytes;
    }
    if (free - needed < 128 * 1024 * 1024 || used + needed > cacheMB * 1024 * 1024) {
      throw StateError('This game needs more space. Increase the game cache limit or free device storage in Settings.');
    }
  }

  Future<void> _copy(String relative, File target, int size, void Function(String, double?) progress) async {
    _check();
    if (await target.exists() && await target.length() == size) return;
    await target.parent.create(recursive: true);
    final partial = File('${target.path}.partial');
    final binary = await RcloneService.resolveBinaryPath();
    _check();
    final proc = await Process.start(
      binary,
      [
        'copyto',
        ':http:${safeRelative(relative)}',
        partial.path,
        '--http-url',
        '$base/files/',
        '--http-no-head=false',
        '--retries',
        '2',
        '--low-level-retries',
        '2',
        '--timeout',
        '30s',
        '--contimeout',
        '10s',
        '--stats',
        '0',
        '--log-level',
        'ERROR',
      ],
      environment: {'RCLONE_HTTP_HEADERS': 'Authorization,Bearer $token'},
      runInShell: false,
    );
    _transfer = proc;
    // Drain output without exposing headers or raw process arguments in logs.
    final output = proc.stdout.drain<void>();
    final errors = proc.stderr.drain<void>();
    final timer = Timer.periodic(const Duration(milliseconds: 400), (_) async {
      try {
        if (await partial.exists() && !_cancelled) {
          progress('Getting game ready', (await partial.length() / size).clamp(0, 1));
        }
      } on FileSystemException {
        /* The completed transfer may already be renamed. */
      }
    });
    try {
      final status = await proc.exitCode.timeout(
        const Duration(minutes: 15),
        onTimeout: () {
          proc.kill();
          throw TimeoutException('Game download took too long.');
        },
      );
      await Future.wait([output, errors]);
      _check();
      if (status != 0 || !await partial.exists() || await partial.length() != size) {
        throw StateError('The game download did not finish. Check the library connection and try again.');
      }
      await partial.rename(target.path);
    } finally {
      timer.cancel();
      _transfer = null;
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> _syncSaves(Directory saves, String id, {required bool upload}) async {
    final pending = File(p.join(saves.path, '.pending'));
    if (upload && !await pending.exists()) return;
    for (final name in ['save.srm', 'resume.state']) {
      final file = File(p.join(saves.path, name));
      final uri = Uri.parse('$base/saves/$profileKey/$id/$name');
      if (upload) {
        if (!await file.exists()) continue;
        final response = await client
            .put(uri, headers: headers, body: await file.readAsBytes())
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) throw StateError('Game save sync failed. The save is safe on this ONN.');
      } else {
        if (await pending.exists()) return;
        final response = await client.get(uri, headers: headers).timeout(const Duration(seconds: 30));
        if (response.statusCode == 404) continue;
        if (response.statusCode != 200) throw StateError('Could not check saved progress.');
        final modified = HttpDate.parse(response.headers['last-modified']!);
        if (await file.exists() && !(await file.lastModified()).isBefore(modified)) continue;
        final staging = File('${file.path}.tmp');
        await staging.writeAsBytes(response.bodyBytes);
        await staging.rename(file.path);
        await file.setLastModified(modified);
      }
    }
    if (upload && await pending.exists()) await pending.delete();
  }

  Future<void> play(LibraryGame game, {required void Function(String, double?) progress, bool resume = true}) async {
    if (_playing) throw StateError('A game is already being prepared.');
    _playing = true;
    _cancelled = false;
    try {
      if (game.id == rainbow3d.id) {
        await channel.invokeMethod<void>('launchRainbow');
        await remember(rainbow3d);
        return;
      }
      final paths = await channel.invokeMapMethod<String, dynamic>('paths');
      final root = paths!['root'] as String;
      final cache = Directory(p.join(root, 'cache'));
      if (!RegExp(r'^[a-f0-9]{24}$').hasMatch(game.id)) throw const FormatException('Invalid game id.');
      final folder = Directory(p.join(cache.path, game.id));
      final marker = File(p.join(folder.path, 'ready.json'));
      Map<String, dynamic> manifest;
      try {
        manifest = await get('game/${game.id}');
      } catch (_) {
        if (!await marker.exists()) rethrow;
        manifest = jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
      }
      _check();
      // Refuse before transferring game/BIOS data if this build lacks the core.
      await channel.invokeMethod<void>('checkCore', {'core': manifest['core']});
      final files = (manifest['files'] as List).cast<Map<String, dynamic>>();
      var needed = 0;
      for (final f in files) {
        final local = File(p.join(folder.path, safeRelative(f['path'] as String)));
        if (!await local.exists() || await local.length() != f['size']) needed += f['size'] as int;
      }
      await _space(cache, folder, needed, paths['freeBytes'] as int);
      for (final f in files) {
        await _copy(
          f['path'] as String,
          File(p.join(folder.path, safeRelative(f['path'] as String))),
          f['size'] as int,
          progress,
        );
      }
      _check();
      var path = p.join(folder.path, safeRelative(manifest['path'] as String));
      // Firmware is supplied separately by the user; never fetch it from a catalog.
      if (path.toLowerCase().endsWith('.zip')) {
        progress('Opening game archive', null);
        path = (await channel.invokeMethod<String>('extract', {'path': path, 'extensions': manifest['extensions']}))!;
      }
      await marker.writeAsString(jsonEncode(manifest));
      final saves = Directory(p.join(root, 'saves', profileKey, game.id));
      await saves.create(recursive: true);
      progress('Checking saved progress', null);
      try {
        await _syncSaves(saves, game.id, upload: true);
        await _syncSaves(saves, game.id, upload: false);
      } catch (_) {
        appLogger.w('Game save sync unavailable. Local progress is preserved.');
      }
      _check();
      progress('Starting game', null);
      final result = await channel.invokeMapMethod<String, dynamic>('launch', {
        'path': path,
        'saveDir': saves.path,
        'core': manifest['core'],
        'title': game.title,
        'shader': shader,
        'resume': resume,
      });
      if (result?['played'] == true) await remember(game);
      progress('Saving progress', null);
      try {
        await _syncSaves(saves, game.id, upload: true);
      } catch (_) {
        appLogger.w('Game save sync failed. Your progress is kept on this ONN and will retry next launch.');
      }
    } finally {
      _playing = false;
    }
  }
}
