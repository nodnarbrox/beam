// LibtorrentFlutter — Main engine class.
// Manages a libtorrent session with automatic tracker injection,
// status polling, and a built-in HTTP streaming server.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';

import 'ffi_bindings.dart';
import 'models.dart';

// ─── Tracker Management ─────────────────────────────────────────────────────

/// Automatically fetches and injects best public trackers into magnet URIs.
class TrackerManager {
  static final List<String> _extraTrackers = [];

  /// When true, `udp://` and `https://` trackers are filtered out of the
  /// injected list.
  ///
  /// Some networks carry TCP but silently drop outbound UDP (Surfshark does —
  /// verified on-device: TCP to tracker.opentrackr.org:1337 connects while UDP
  /// to the SAME host:port never answers). The upstream trackers_best.txt list
  /// is overwhelmingly udp://, so injecting it wholesale on such a network
  /// floods the torrent with trackers that can only ever time out, and they
  /// shadow the working http:// endpoint for the same host — the swarm looks
  /// empty and metadata never resolves.
  ///
  /// https:// is filtered too: libtorrent fails these tracker endpoints with
  /// "asio.ssl error" / "unspecified system error" even when the host's plain
  /// http:// endpoint works fine.
  static bool tcpOnly = false;

  /// Trackers that survive [tcpOnly] filtering.
  static List<String> get effectiveTrackers => tcpOnly
      ? _extraTrackers.where((t) {
          final s = t.toLowerCase();
          return !s.startsWith('udp') && !s.startsWith('https');
        }).toList()
      : _extraTrackers;

  /// Fetch the latest best-performing tracker list from GitHub.
  static Future<void> fetchBestTrackers() async {
    // Closed in a finally: on an exception the old code never reached
    // close(), leaking the client and its connections on every failed call.
    final client = HttpClient();
    try {
      client.connectionTimeout = const Duration(seconds: 5);
      final req = await client.getUrl(Uri.parse(
          'https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt'));
      final res = await req.close();
      if (res.statusCode == 200) {
        final body = await res.transform(const SystemEncoding().decoder).join();
        final list = body
            .split('\n')
            .map((s) => s.trim())
            // Skip blanks AND comment lines; the upstream file uses '#'.
            .where((s) => s.isNotEmpty && !s.startsWith('#'))
            .toList();
        _extraTrackers.clear();
        _extraTrackers.addAll(list);
      } else {
        developer.log('tracker list fetch: HTTP ${res.statusCode}',
            name: 'libtorrent');
      }
    } catch (e) {
      // Non-fatal: torrents still have their own trackers. Log it rather than
      // swallowing, so "no extra trackers" is distinguishable from "offline".
      developer.log('tracker list fetch failed: $e', name: 'libtorrent');
    } finally {
      client.close(force: true);
    }
  }

  /// Inject extra trackers into a magnet URI for better peer discovery.
  static String injectTrackers(String magnetUri) {
    final extras = effectiveTrackers;
    if (extras.isEmpty) return magnetUri;
    var uri = magnetUri;
    for (final tr in extras) {
      if (!uri.contains(Uri.encodeComponent(tr))) {
        uri += '&tr=${Uri.encodeComponent(tr)}';
      }
    }
    return uri;
  }
}

// ─── Status converters ──────────────────────────────────────────────────────

TorrentInfo _toTorrentInfo(LtTorrentStatus s) => TorrentInfo(
  id:            s.id,
  name:          readCharArray(s.name, 512),
  savePath:      readCharArray(s.savePath, 1024),
  errorMsg:      readCharArray(s.errorMsg, 256),
  state:         stateFromInt(s.state),
  progress:      s.progress.clamp(0.0, 1.0),
  downloadRate:  s.downloadRate,
  uploadRate:    s.uploadRate,
  totalDone:     s.totalDone,
  totalWanted:   s.totalWanted,
  totalUploaded: s.totalUploaded,
  numPeers:      s.numPeers,
  numSeeds:      s.numSeeds,
  isPaused:      s.isPaused != 0,
  isFinished:    s.isFinished != 0,
  hasMetadata:   s.hasMetadata != 0,
  queuePosition: s.queuePosition,
);

FileInfo _toFileInfo(LtFileInfo f) => FileInfo(
  index:        f.index,
  name:         readCharArray(f.name, 512),
  path:         readCharArray(f.path, 1024),
  size:         f.size,
  isStreamable: f.isStreamable != 0,
);

StreamInfo _toStreamInfo(LtStreamStatus s) => StreamInfo(
  id:              s.id,
  torrentId:       s.torrentId,
  fileIndex:       s.fileIndex,
  url:             readCharArray(s.url, 256),
  fileSize:        s.fileSize,
  readHead:        s.readHead,
  streamState:     streamStateFromInt(s.streamState),
  bufferSeconds:   s.bufferSeconds,
  bufferPieces:    s.bufferPieces,
  readaheadWindow: s.readaheadWindow,
  activePeers:     s.activePeers,
  downloadRate:    s.downloadRate,
);

// ─── LibtorrentFlutter ──────────────────────────────────────────────────────

/// The main libtorrent engine for Flutter.
///
/// Usage:
/// ```dart
/// await LibtorrentFlutter.init();
/// final torrentId = LibtorrentFlutter.instance.addMagnet(magnetUri, savePath);
/// final stream = LibtorrentFlutter.instance.startStream(torrentId);
/// // Pass stream.url to your video player
/// ```
class LibtorrentFlutter {
  static LibtorrentFlutter? _instance;

  late final TorrentBridgeBindings _b;
  late final Pointer<LtSessionOpaque> _session;
  late final String _defaultSavePath;

  // Torrent status
  final _torrentsCtrl = StreamController<Map<int, TorrentInfo>>.broadcast();
  final Map<int, TorrentInfo> _torrents = {};
  Timer? _pollTimer;

  // Stream status
  final _streamsCtrl = StreamController<Map<int, StreamInfo>>.broadcast();
  final Map<int, StreamInfo> _streams = {};

  static const _maxTorrents = 1024;
  static const _maxStreams  = 64;

  LibtorrentFlutter._();

  /// The singleton instance. Only available after [init] completes.
  static LibtorrentFlutter get instance {
    if (_instance == null) throw StateError('LibtorrentFlutter.init() not called');
    return _instance!;
  }

  /// Whether the engine has been initialized.
  static bool get isInitialized => _instance != null;

  /// Initialize the libtorrent engine.
  ///
  /// - [listenInterface] — network interface to listen on (empty = all).
  /// - [downloadLimit] / [uploadLimit] — speed limits in bytes/sec (0 = unlimited).
  /// - [pollInterval] — how often to poll for torrent/stream status updates.
  /// - [fetchTrackers] — automatically fetch best public trackers on startup.
  /// - [defaultSavePath] — where to save torrent data. Defaults to system temp dir.
  static Future<void> init({
    String listenInterface = '',
    int downloadLimit = 0,
    int uploadLimit = 0,
    Duration pollInterval = const Duration(milliseconds: 600),
    bool fetchTrackers = true,
    String? defaultSavePath,
  }) async {
    if (_instance != null) return;
    final engine = LibtorrentFlutter._();

    // Fetch best trackers in background (fire & forget)
    if (fetchTrackers) {
      TrackerManager.fetchBestTrackers();
    }

    final lib = TorrentBridgeBindings.open();
    engine._b = lib;

    final iface = listenInterface.toNativeUtf8();
    try {
      final session = engine._b.createSession(iface, downloadLimit, uploadLimit);
      if (session == nullptr) {
        final err = engine._b.lastError().toDartString();
        throw StateError('Failed to create libtorrent session: $err');
      }
      engine._session = session;
    } finally {
      malloc.free(iface);
    }

    _instance = engine;
    engine._defaultSavePath = defaultSavePath ?? Directory.systemTemp.path;
    engine._startPolling(pollInterval);
  }

  // ─── Public Streams ─────────────────────────────────────────────────────────

  /// Stream of all torrent statuses, emitted on every poll update.
  Stream<Map<int, TorrentInfo>> get torrentUpdates => _torrentsCtrl.stream;

  /// Stream of all active stream statuses.
  Stream<Map<int, StreamInfo>> get streamUpdates => _streamsCtrl.stream;

  /// Current snapshot of all known torrents.
  Map<int, TorrentInfo> get torrents => Map.unmodifiable(_torrents);

  /// Current snapshot of all active streams.
  Map<int, StreamInfo> get streams => Map.unmodifiable(_streams);

  /// libtorrent version string.
  String get libraryVersion => _b.version().toDartString();

  // ─── Torrent Management ─────────────────────────────────────────────────────

  /// Add a torrent from a magnet URI.
  ///
  /// Returns the torrent ID. [savePath] defaults to the path set in init().
  /// Set [streamOnly] to true to prevent background downloading.
  int addMagnet(String magnetUri, [String? savePath, bool streamOnly = false]) {
    final enhanced = TrackerManager.injectTrackers(magnetUri);
    final m = enhanced.toNativeUtf8();
    final s = (savePath ?? _defaultSavePath).toNativeUtf8();
    try {
      final id = _b.addMagnet(_session, m, s, streamOnly ? 1 : 0);
      if (id < 0) throw Exception(_b.lastError().toDartString());
      return id;
    } finally {
      malloc.free(m); malloc.free(s);
    }
  }

  /// Add a torrent from a .torrent file path.
  int addTorrentFile(String filePath, [String? savePath, bool streamOnly = false]) {
    final f = filePath.toNativeUtf8();
    final s = (savePath ?? _defaultSavePath).toNativeUtf8();
    try {
      final id = _b.addTorrentFile(_session, f, s, streamOnly ? 1 : 0);
      if (id < 0) throw Exception(_b.lastError().toDartString());
      return id;
    } finally {
      malloc.free(f); malloc.free(s);
    }
  }

  /// Remove a torrent. Optionally delete downloaded files.
  void removeTorrent(int id, {bool deleteFiles = false}) {
    _b.removeTorrent(_session, id, deleteFiles ? 1 : 0);
    _torrents.remove(id);
    _torrentsCtrl.add(Map.unmodifiable(_torrents));
  }

  /// Pause a torrent.
  void pauseTorrent(int id) => _b.pauseTorrent(_session, id);

  /// Resume a paused torrent.
  void resumeTorrent(int id) => _b.resumeTorrent(_session, id);

  /// Recheck torrent integrity.
  void recheckTorrent(int id) => _b.recheckTorrent(_session, id);

  // ─── File Enumeration ───────────────────────────────────────────────────────

  /// Get the list of files in a torrent (requires metadata).
  List<FileInfo> getFiles(int torrentId) {
    final count = _b.getFileCount(_session, torrentId);
    if (count <= 0) return [];
    final buf = calloc<LtFileInfo>(count);
    try {
      final n = _b.getFiles(_session, torrentId, buf, count);
      return List.generate(n, (i) => _toFileInfo(buf[i]));
    } finally {
      calloc.free(buf);
    }
  }

  /// Set download priorities per file (0 = skip, 1-7 = priority levels).
  void setFilePriorities(int torrentId, List<int> priorities) {
    final count = priorities.length;
    final buf = calloc<Int32>(count);
    try {
      for (var i = 0; i < count; i++) {
        buf[i] = priorities[i];
      }
      _b.setFilePriorities(_session, torrentId, buf, count);
    } finally {
      calloc.free(buf);
    }
  }

  // ─── Streaming ──────────────────────────────────────────────────────────────

  /// Start streaming a file from a torrent.
  ///
  /// Returns [StreamInfo] with an HTTP URL that can be passed to any video player.
  /// [fileIndex] = -1 auto-selects the largest streamable file.
  /// [maxCacheBytes] controls how much RAM the piece cache uses (0 = default ~128MB).
  StreamInfo startStream(int torrentId, {int fileIndex = -1, int maxCacheBytes = 0}) {
    final streamId = _b.startStream(_session, torrentId, fileIndex, maxCacheBytes);
    if (streamId < 0) {
      throw Exception('startStream failed: ${_b.lastError().toDartString()}');
    }
    final statusBuf = calloc<LtStreamStatus>();
    try {
      final ok = _b.getStreamStatus(_session, streamId, statusBuf);
      if (ok == 0) throw Exception('Failed to get stream status');
      final info = _toStreamInfo(statusBuf.ref);
      _streams[streamId] = info;
      _streamsCtrl.add(Map.unmodifiable(_streams));
      return info;
    } finally {
      calloc.free(statusBuf);
    }
  }

  /// Apply a known media runtime without changing the stream ABI. Older native
  /// builds retain their estimate and return false. Refresh cached telemetry
  /// immediately so readiness cannot use the previous duration estimate.
  bool setStreamDuration(int streamId, int durationMs) {
    if (durationMs <= 0 || durationMs > 86400000) return false;
    final setter = _b.setStreamDuration;
    if (setter == null || setter(_session, streamId, durationMs) == 0) return false;
    _streams.remove(streamId);
    final statusBuf = calloc<LtStreamStatus>();
    try {
      if (_b.getStreamStatus(_session, streamId, statusBuf) == 0) return false;
      _streams[streamId] = _toStreamInfo(statusBuf.ref);
      _streamsCtrl.add(Map.unmodifiable(_streams));
      return true;
    } finally {
      calloc.free(statusBuf);
    }
  }

  /// Stop a stream.
  void stopStream(int streamId) {
    _b.stopStream(_session, streamId);
    _streams.remove(streamId);
    _streamsCtrl.add(Map.unmodifiable(_streams));
  }

  /// Stop all streams for a specific torrent.
  void stopAllStreamsForTorrent(int torrentId) {
    final toStop = _streams.entries
        .where((e) => e.value.torrentId == torrentId)
        .map((e) => e.key)
        .toList();
    for (final sid in toStop) {
      stopStream(sid);
    }
  }

  /// Get the current info for a specific stream, or null if not found.
  StreamInfo? getStreamInfo(int streamId) => _streams[streamId];

  /// Whether a torrent is currently being streamed.
  bool isStreaming(int torrentId) =>
      _streams.values.any((s) => s.torrentId == torrentId && s.isActive);

  /// Preload head + tail of the stream file for fast playback start.
  /// Port of TorrServer's torr/preload.go Preload() function.
  /// [preloadBytes] = 0 defaults to 16MB (head + tail).
  bool preloadStream(int streamId, {int preloadBytes = 0}) {
    return _b.preloadStream(_session, streamId, preloadBytes) != 0;
  }

  /// Configure the TorrServer-style cache for an active stream.
  /// Port of TorrServer's settings/btsets.go BTSets fields.
  ///
  /// - [capacity] — cache size in bytes (default 64MB).
  /// - [readAheadPct] — percentage 5-100 of cache used for read-ahead (default 95%).
  /// - [connectionsLimit] — max concurrent piece requests per reader (default 25).
  void setCacheSettings(int streamId, {
    int capacity = 0,
    int readAheadPct = 0,
    int connectionsLimit = 0,
  }) {
    _b.setCacheSettings(_session, streamId, capacity, readAheadPct, connectionsLimit);
  }

  // ─── Speed Limits ─────────────────────────────────────────────────────────

  /// Set download speed limit in bytes/sec (0 = unlimited).
  void setDownloadLimit(int bps) => _b.setDownloadLimit(_session, bps);

  /// Set upload speed limit in bytes/sec (0 = unlimited).
  void setUploadLimit(int bps) => _b.setUploadLimit(_session, bps);

  // ─── Engine Configuration — port of settings/btsets.go + btserver.go ───────

  /// Apply TorrServer-style engine configuration.
  ///
  /// Port of btserver.go configure(). Maps [BtConfig] fields to libtorrent
  /// settings_pack values: encryption, DHT, UPnP, rate limits, etc.
  /// Also applies cache/reader settings to all future streams.
  void configureSession(BtConfig config) {
    final cfgPtr = calloc<LtBtConfig>();
    try {
      cfgPtr.ref.cacheSize = config.cacheSize;
      cfgPtr.ref.readerReadAhead = config.readerReadAhead;
      cfgPtr.ref.preloadCache = config.preloadCache;
      cfgPtr.ref.connectionsLimit = config.connectionsLimit;
      cfgPtr.ref.torrentDisconnectTimeout = config.torrentDisconnectTimeout;
      cfgPtr.ref.forceEncrypt = config.forceEncrypt ? 1 : 0;
      cfgPtr.ref.disableTcp = config.disableTcp ? 1 : 0;
      cfgPtr.ref.disableUtp = config.disableUtp ? 1 : 0;
      cfgPtr.ref.disableUpload = config.disableUpload ? 1 : 0;
      cfgPtr.ref.disableDht = config.disableDht ? 1 : 0;
      cfgPtr.ref.disableUpnp = config.disableUpnp ? 1 : 0;
      cfgPtr.ref.enableIpv6 = config.enableIpv6 ? 1 : 0;
      cfgPtr.ref.downloadRateLimit = config.downloadRateLimit;
      cfgPtr.ref.uploadRateLimit = config.uploadRateLimit;
      cfgPtr.ref.peersListenPort = config.peersListenPort;
      cfgPtr.ref.responsiveMode = config.responsiveMode ? 1 : 0;
      // SOCKS5/HTTP proxy (MediaBeam).
      cfgPtr.ref.proxyType = config.proxyType;
      cfgPtr.ref.proxyPort = config.proxyPort;
      _writeCharArray(cfgPtr.ref.proxyHost, config.proxyHost, 256);
      _writeCharArray(cfgPtr.ref.proxyUser, config.proxyUser, 128);
      _writeCharArray(cfgPtr.ref.proxyPass, config.proxyPass, 128);
      _b.configureSession(_session, cfgPtr);
    } finally {
      calloc.free(cfgPtr);
    }
  }

  /// Writes [s] (UTF-8) into a fixed C char[] of capacity [maxLen], NUL-terminated.
  static void _writeCharArray(Array<Char> arr, String s, int maxLen) {
    final bytes = utf8.encode(s);
    final n = bytes.length < maxLen - 1 ? bytes.length : maxLen - 1;
    for (var i = 0; i < n; i++) {
      arr[i] = bytes[i];
    }
    arr[n] = 0;
  }

  /// Get TorrServer's default engine configuration.
  ///
  /// Port of settings.SetDefaultConfig(). Returns a [BtConfig] with the
  /// same defaults TorrServer uses out of the box.
  BtConfig getDefaultConfig() {
    final cfgPtr = calloc<LtBtConfig>();
    try {
      _b.getDefaultConfig(cfgPtr);
      return BtConfig(
        cacheSize: cfgPtr.ref.cacheSize,
        readerReadAhead: cfgPtr.ref.readerReadAhead,
        preloadCache: cfgPtr.ref.preloadCache,
        connectionsLimit: cfgPtr.ref.connectionsLimit,
        torrentDisconnectTimeout: cfgPtr.ref.torrentDisconnectTimeout,
        forceEncrypt: cfgPtr.ref.forceEncrypt != 0,
        disableTcp: cfgPtr.ref.disableTcp != 0,
        disableUtp: cfgPtr.ref.disableUtp != 0,
        disableUpload: cfgPtr.ref.disableUpload != 0,
        disableDht: cfgPtr.ref.disableDht != 0,
        disableUpnp: cfgPtr.ref.disableUpnp != 0,
        enableIpv6: cfgPtr.ref.enableIpv6 != 0,
        downloadRateLimit: cfgPtr.ref.downloadRateLimit,
        uploadRateLimit: cfgPtr.ref.uploadRateLimit,
        peersListenPort: cfgPtr.ref.peersListenPort,
        responsiveMode: cfgPtr.ref.responsiveMode != 0,
        proxyType: cfgPtr.ref.proxyType,
        proxyHost: readCharArray(cfgPtr.ref.proxyHost, 256),
        proxyPort: cfgPtr.ref.proxyPort,
        proxyUser: readCharArray(cfgPtr.ref.proxyUser, 128),
        proxyPass: readCharArray(cfgPtr.ref.proxyPass, 128),
      );
    } finally {
      calloc.free(cfgPtr);
    }
  }

  /// Number of active streams across all torrents.
  int get activeStreamCount => _b.getActiveStreams(_session);

  // ─── Polling ──────────────────────────────────────────────────────────────

  void _startPolling(Duration interval) {
    _pollTimer = Timer.periodic(interval, (_) => _poll());
  }

  void _poll() {
    _pollTorrents();
    _pollStreams();
    _pollAlerts();
  }

  void _pollAlerts() {
    final callback = NativeCallable<LtAlertCallbackNative>.isolateLocal(_onAlert);
    try {
      _b.pollAlerts(_session, callback.nativeFunction, nullptr);
    } finally {
      callback.close();
    }
  }

  /// Set true to echo every libtorrent alert to the log. Off by default:
  /// alerts arrive continuously and printing them all is expensive noise in
  /// production.
  static bool debugLogAlerts = false;

  /// Rolling buffer of recent libtorrent alerts.
  ///
  /// Alerts are the ONLY window into why a magnet stalls (did DHT bootstrap?
  /// did peers advertise ut_metadata? did a tracker actually reply?), but
  /// `developer.log` does not surface in Android logcat in this build, so
  /// logging alone left them unreadable. Keeping them in memory lets them be
  /// pulled out over the Dart VM Service with:
  ///   beamctl.py eval-lib libtorrent_flutter_base.dart \
  ///     'LibtorrentFlutter.alertLog.join("\n")'
  static final List<String> alertLog = <String>[];
  static const int _alertLogMax = 400;

  /// Only keep alerts matching this pattern (null = keep all). Useful to cut
  /// the firehose down to e.g. dht/metadata lines.
  static RegExp? alertFilter;

  static void _onAlert(int type, int torrentId, Pointer<Utf8> message,
      Pointer<Void> userData) {
    // This runs on a NATIVE callback. An exception thrown here does not become
    // a catchable Dart error — it tears down the isolate. A null/garbage
    // `message` pointer from native would do exactly that via toDartString(),
    // so guard the pointer AND wrap the conversion.
    if (!debugLogAlerts) return;
    if (message == nullptr) return;
    try {
      final msg = message.toDartString();
      if (alertFilter != null && !alertFilter!.hasMatch(msg)) return;
      alertLog.add('[T$torrentId] $msg');
      if (alertLog.length > _alertLogMax) {
        alertLog.removeRange(0, alertLog.length - _alertLogMax);
      }
    } catch (_) {
      // A malformed alert string must never crash the app.
    }
  }

  void _pollTorrents() {
    final count = _b.getTorrentCount(_session);
    final buf   = calloc<LtTorrentStatus>(max(count, _maxTorrents));
    try {
      final n = _b.getAllStatuses(_session, buf, max(count, _maxTorrents));
      bool changed = false;
      final seen = <int>{};

      for (var i = 0; i < n; i++) {
        final info = _toTorrentInfo(buf[i]);
        seen.add(info.id);
        final old = _torrents[info.id];
        if (old == null || _changed(old, info)) {
          _torrents[info.id] = info;
          changed = true;
        }
      }
      final stale = _torrents.keys.where((k) => !seen.contains(k)).toList();
      for (final k in stale) {
        _torrents.remove(k);
        changed = true;
      }
      if (changed) _torrentsCtrl.add(Map.unmodifiable(_torrents));
    } finally { calloc.free(buf); }
  }

  void _pollStreams() {
    if (_streams.isEmpty) return;
    final buf = calloc<LtStreamStatus>(_maxStreams);
    try {
      final n = _b.getAllStreamStatuses(_session, buf, _maxStreams);
      bool changed = false;
      for (var i = 0; i < n; i++) {
        final info = _toStreamInfo(buf[i]);
        final old  = _streams[info.id];
        if (old == null ||
            old.streamState != info.streamState ||
            old.bufferPieces != info.bufferPieces ||
            old.readHead    != info.readHead ||
            old.activePeers != info.activePeers) {
          _streams[info.id] = info;
          changed = true;
        }
        if (!info.isActive) {
          _streams.remove(info.id);
          changed = true;
        }
      }
      if (changed) _streamsCtrl.add(Map.unmodifiable(_streams));
    } finally { calloc.free(buf); }
  }

  bool _changed(TorrentInfo a, TorrentInfo b) =>
      a.state       != b.state       ||
      a.progress    != b.progress    ||
      a.downloadRate!= b.downloadRate||
      a.uploadRate  != b.uploadRate  ||
      a.totalDone   != b.totalDone   ||
      a.numPeers    != b.numPeers    ||
      a.isPaused    != b.isPaused    ||
      a.hasMetadata != b.hasMetadata ||
      a.name        != b.name;

  // ─── Cleanup ───────────────────────────────────────────────────────────────

  /// Clean up a single torrent: stops its streams, removes it, deletes files.
  ///
  /// Returns true if the torrent existed and was removed, false if it was
  /// already gone.
  bool disposeTorrent(int torrentId) {
    if (!_torrents.containsKey(torrentId)) return false;

    // Stop any active streams for this torrent
    stopAllStreamsForTorrent(torrentId);

    // Remove the torrent and delete its files
    removeTorrent(torrentId, deleteFiles: true);
    return true;
  }

  /// Clean up ALL torrents: stops every stream, removes every torrent,
  /// deletes all downloaded files. Call this on your exit button.
  /// Stops every stream and removes every torrent, deleting their files.
  ///
  /// Returns the number of torrents whose removal FAILED. Callers that promise
  /// "nothing is left on disk" must check this: swallowing these errors
  /// silently meant a failed wipe was indistinguishable from a clean one, with
  /// nothing in the log to diagnose leftover downloaded video.
  int disposeAll() {
    var failures = 0;
    // Stop all streams first
    for (final sid in _streams.keys.toList()) {
      try {
        stopStream(sid);
      } catch (e) {
        developer.log('stopStream($sid) failed: $e', name: 'libtorrent');
      }
    }

    // Remove all torrents and delete their files
    for (final tid in _torrents.keys.toList()) {
      try {
        removeTorrent(tid, deleteFiles: true);
      } catch (e) {
        failures++;
        developer.log('removeTorrent($tid, deleteFiles: true) FAILED: $e — '
            'files may remain on disk', name: 'libtorrent');
      }
    }
    return failures;
  }

  /// Shut down the engine entirely. Calls [disposeAll] first, then
  /// destroys the native session. After this, you'd need to call
  /// [init] again to use the engine.
  Future<void> dispose() async {
    disposeAll();
    _pollTimer?.cancel();
    _b.destroySession(_session);
    await _torrentsCtrl.close();
    await _streamsCtrl.close();
    _instance = null;
  }
}
