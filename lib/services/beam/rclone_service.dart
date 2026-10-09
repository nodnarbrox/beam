import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:plezy/utils/app_logger.dart';

import 'beam_config.dart';

/// Runs the app-bundled `rclone` binary on-device and controls it through
/// rclone's Remote Control (rc) HTTP API.
///
/// ## How the binary gets here (NATIVE side — Kotlin, not this file)
/// On Android an executable can only be `exec`'d from the app's
/// `nativeLibraryDir`, so `rclone` ships as a jniLibs `.so` (e.g.
/// `librclone.so` under `src/main/jniLibs/armeabi-v7a/`). Android extracts it
/// to `nativeLibraryDir` at install time where it is already executable.
///
/// Dart cannot read `nativeLibraryDir` without a platform channel, so the
/// native side must implement a [MethodChannel] named **`beam/rclone`** with a
/// method **`getBinaryPath`** returning the absolute path to the extracted
/// `librclone.so` (a `String`). [resolveBinaryPath] calls it; alternatively the
/// caller can pass a known `binaryPath` straight to [start].
///
/// ## mount vs serve on Android
/// `mount/mount` needs FUSE (`/dev/fuse`), which is unavailable on stock,
/// non-rooted Android — the mount call will fail there. The robust,
/// FUSE-free path is `rclone serve http`, which exposes the remote as a plain
/// local HTTP server the player can stream from. We therefore spawn `serve
/// http` as a *second* process (the rc `mount/*` endpoints are kept only for
/// rooted/where-supported use). [mount] is provided but documented as
/// best-effort; [serveHttp] is the recommended streaming path.
class RcloneService {
  RcloneService();

  static const MethodChannel _channel = MethodChannel('beam/rclone');

  Process? _rcd;
  final List<Process> _serveProcs = [];
  final http.Client _http = http.Client();

  int _port = 0;
  String _user = '';
  String _pass = '';
  String? _binaryPath;

  int get port => _port;
  bool get isRunning => _rcd != null;
  String get rcBaseUrl => 'http://127.0.0.1:$_port';

  /// Ask the native side (Kotlin) for the extracted binary path.
  static Future<String> resolveBinaryPath() async {
    final path = await _channel.invokeMethod<String>('getBinaryPath');
    if (path == null || path.isEmpty) {
      throw StateError('Native beam/rclone.getBinaryPath returned no path');
    }
    return path;
  }

  /// Launch `rclone rcd` on a random localhost port with generated Basic-auth
  /// credentials. [binaryPath] is the on-device executable path (from
  /// [resolveBinaryPath] or the native side).
  Future<void> start({required String binaryPath}) async {
    if (_rcd != null) {
      appLogger.d('rclone rcd already running on $_port');
      return;
    }
    _binaryPath = binaryPath;
    final rng = Random.secure();
    _port = 20000 + rng.nextInt(20000); // random high localhost port
    _user = 'plezy';
    _pass = _randomToken(rng);

    final env = await _buildEnv();
    final args = <String>[
      'rcd',
      '--rc-addr', '127.0.0.1:$_port',
      '--rc-user', _user,
      '--rc-pass', _pass,
      // Auth is ON (we pass user/pass); never --rc-no-auth on-device.
      '--rc-serve',
    ];

    appLogger.i('Starting rclone rcd on localhost:$_port (authentication enabled)');
    final proc = await Process.start(
      binaryPath,
      args,
      environment: env,
      runInShell: false,
    );
    _rcd = proc;
    _pipe(proc, 'rcd');
    unawaited(proc.exitCode.then((code) {
      appLogger.w('rclone rcd exited: $code');
      if (identical(_rcd, proc)) _rcd = null;
    }));

    await _waitForReady();
  }

  /// Core control primitive: POST `/<command>` with a JSON body and Basic auth.
  Future<Map<String, dynamic>> rc(
    String command, [
    Map<String, dynamic>? params,
  ]) async {
    if (_port == 0) {
      throw StateError('RcloneService.start() must complete before rc()');
    }
    final uri = Uri.parse('$rcBaseUrl/$command');
    final auth = base64Encode(utf8.encode('$_user:$_pass'));
    final resp = await _http.post(
      uri,
      headers: {
        'Authorization': 'Basic $auth',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(params ?? const {}),
    );
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      decoded = {'raw': resp.body};
    }
    if (resp.statusCode >= 300) {
      appLogger.e('rc $command -> ${resp.statusCode}: ${resp.body}');
      throw HttpException('rclone rc $command failed (${resp.statusCode}): '
          '${decoded['error'] ?? resp.body}');
    }
    return decoded;
  }

  // ---- Convenience wrappers ----

  /// Names of configured remotes.
  Future<Map<String, dynamic>> listRemotes() => rc('config/listremotes');

  /// List a directory within [remote] at [path] (e.g. remote='rd', path='movies').
  Future<Map<String, dynamic>> listDir(String remote, String path) =>
      rc('operations/list', {'fs': '$remote:', 'remote': path});

  /// Create a remote so the user can add e.g. a Real-Debrid WebDAV or an SFTP
  /// seedbox from inside the app. [parameters] are rclone backend options
  /// (url, user, pass, host, key_file, ...).
  Future<Map<String, dynamic>> createRemote(
    String name,
    String type,
    Map<String, dynamic> parameters,
  ) =>
      rc('config/create', {
        'name': name,
        'type': type,
        'parameters': parameters,
      });

  /// FUSE mount — BEST-EFFORT ONLY. Requires `/dev/fuse`, generally absent on
  /// non-rooted Android; prefer [serveHttp]. VFS is tuned for streaming.
  Future<Map<String, dynamic>> mount(String remote, String mountPoint) =>
      rc('mount/mount', {
        'fs': '$remote:',
        'mountPoint': mountPoint,
        'vfsOpt': {
          'CacheMode': 'full', // full cache -> smooth seeking of media
          'ChunkSize': '32M',
          'ChunkSizeLimit': '256M',
          'ReadAhead': '128M',
        },
      });

  /// Serve [remote] over plain local HTTP — the Android-friendly streaming path
  /// (no FUSE). Spawned as a SECOND process rather than the rc `serve` endpoint
  /// because a dedicated process gives an independent lifecycle, its own logs,
  /// and clean teardown without touching the rcd daemon. Returns the base URL
  /// the player can stream from: `http://127.0.0.1:<port>/`.
  Future<String> serveHttp(String remote, {int port = 0}) async {
    final bin = _binaryPath;
    if (bin == null) {
      throw StateError('start() must run before serveHttp()');
    }
    final rng = Random.secure();
    final p = port != 0 ? port : 8000 + rng.nextInt(4000);
    final env = await _buildEnv();
    final args = <String>[
      'serve', 'http', '$remote:',
      '--addr', '127.0.0.1:$p',
      '--vfs-cache-mode', 'full',
      '--vfs-read-ahead', '128M',
      '--buffer-size', '32M',
    ];
    appLogger.i('Starting rclone serve http on 127.0.0.1:$p for $remote');
    final proc = await Process.start(bin, args, environment: env);
    _serveProcs.add(proc);
    _pipe(proc, 'serve[$remote]');
    unawaited(proc.exitCode.then((code) {
      appLogger.w('rclone serve[$remote] exited: $code');
      _serveProcs.remove(proc);
    }));
    return 'http://127.0.0.1:$p/';
  }

  /// Transfer / job stats.
  Future<Map<String, dynamic>> stats() => rc('core/stats');

  /// Graceful shutdown: ask rcd to quit, kill any serve processes, then reap.
  Future<void> stop() async {
    for (final proc in List<Process>.from(_serveProcs)) {
      proc.kill(ProcessSignal.sigterm);
    }
    _serveProcs.clear();
    final rcd = _rcd;
    if (rcd != null) {
      try {
        await rc('core/quit').timeout(const Duration(seconds: 3));
      } catch (e) {
        appLogger.d('core/quit failed (killing instead): $e');
      }
      rcd.kill(ProcessSignal.sigterm);
      _rcd = null;
    }
    _port = 0;
    _http.close();
  }

  // ---- internals ----

  /// Build the process environment, routing rclone's OWN outbound traffic
  /// through the configured proxy (rclone honors ALL_PROXY / HTTP(S)_PROXY and
  /// supports socks5://). This keeps rclone hidden alongside everything else.
  Future<Map<String, String>> _buildEnv() async {
    final env = Map<String, String>.from(Platform.environment);
    if (!BeamConfig.proxyEnabled) return env;
    final host = BeamConfig.proxyHost.trim();
    if (host.isEmpty) return env;
    final scheme = BeamConfig.proxyScheme; // socks5 | http
    final user = BeamConfig.proxyUser.trim();
    final pass = await BeamConfig.getProxyPass();
    final creds = user.isNotEmpty
        ? '${Uri.encodeComponent(user)}:${Uri.encodeComponent(pass)}@'
        : '';
    final url = '$scheme://$creds$host:${BeamConfig.proxyPort}';
    // ALL_PROXY covers both http and https for rclone; set the http(s) ones too
    // for backends that read them specifically.
    env['ALL_PROXY'] = url;
    env['HTTP_PROXY'] = url;
    env['HTTPS_PROXY'] = url;
    env['NO_PROXY'] = '127.0.0.1,localhost'; // never proxy the local rc/serve
    appLogger.d('rclone proxy env: $scheme://$host:${BeamConfig.proxyPort}');
    return env;
  }

  void _pipe(Process proc, String tag) {
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => appLogger.d('[rclone $tag] $l'));
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => appLogger.w('[rclone $tag] $l'));
  }

  /// Poll rc/noop until the daemon answers (or time out).
  Future<void> _waitForReady() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (_rcd == null) {
        throw StateError('rclone rcd died during startup');
      }
      try {
        await rc('rc/noop');
        appLogger.i('rclone rc ready on $_port');
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    throw TimeoutException('rclone rc did not become ready on $_port');
  }

  String _randomToken(Random rng) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(32, (_) => chars[rng.nextInt(chars.length)]).join();
  }
}
