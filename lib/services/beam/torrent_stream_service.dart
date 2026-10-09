import 'dart:async';
import 'dart:io';

// libtorrent_flutter is vendored at packages/libtorrent_flutter (dep added by
// the maintainer, NOT here). Analysis may not resolve it until then; the code
// is written against the documented API and compiles once the package exists.
import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:plezy/utils/app_logger.dart';

import 'beam_config.dart';
import 'beam_cancellation.dart';
import 'beam_buffer_wait.dart';
import 'beam_playback_duration.dart';
import 'episode_file_selector.dart';
import 'beam_http.dart';
import 'indexer_search.dart' show augmentMagnetForProxy;
import 'prowlarr_client.dart' show infoHashFromMagnet;
import 'vpn_detect.dart';

/// Thrown when a torrent add/start is refused because the privacy preconditions
/// are not met. The Beam UI catches this and falls back to Real-Debrid (which
/// is a remote service and therefore safe to use without a local proxy).
class TorrentProxyRequiredException implements Exception {
  const TorrentProxyRequiredException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// MASTER KILL-SWITCH (fail-closed). The on-device torrent swarm can only be
/// guaranteed private once a proxy-aware native `.so` is verified to route
/// peers + DNS through the user's proxy.
///
/// ENABLED 2026-08-22 after PACKET-LEVEL VERIFICATION on the ONN: with the
/// forked libtorrent .so + proxy on, a live torrent (Interstellar 2014) opened
/// ~22 peer connections and EVERY ONE went to the SOCKS5 proxy
/// (192.0.2.10:1080) — ZERO direct-to-peer connections. `ss -tn` on the
/// device showed only proxy + Android-system/DHCP traffic, proving
/// proxy_peer_connections + proxy_hostnames route the whole swarm + DNS through
/// the proxy. Streaming still stays fail-closed at runtime: [_assertTorrentAllowed]
/// requires proxy enabled AND a live exit-IP probe before any magnet is added.
const bool kTorrentPathEnabled = true;

/// Progress snapshot emitted while a magnet is buffering / playing.
class TorrentStreamStatus {
  const TorrentStreamStatus({
    required this.progress,
    required this.downloadRate,
    required this.numSeeds,
    required this.bufferSeconds,
    required this.ready,
    this.totalDone = 0,
    this.url,
  });

  final double progress; // 0.0–1.0 overall torrent completion
  final int downloadRate; // bytes/sec
  final int totalDone; // verified downloaded bytes; rate alone may be stale
  final int numSeeds;
  final double bufferSeconds; // playable buffer ahead of the read head
  final bool ready; // true once [url] is playable
  final String? url;
}

/// Streams a torrent by playing WHILE downloading, µTorrent-style. Everything is
/// EPHEMERAL: files land in a temp subdir and are wiped (removeTorrent
/// deleteFiles:true + rmdir) on every stop / dispose / app-exit path.
class TorrentStreamService {
  TorrentStreamService._() : _privacyCheck = null, _udpProbe = null, _engineInitializer = null;
  static final TorrentStreamService instance = TorrentStreamService._();

  @visibleForTesting
  TorrentStreamService.forTesting({
    LibtorrentFlutter? engine,
    Future<LibtorrentFlutter> Function()? engineInitializer,
    Directory? tempRoot,
    required Future<void> Function() privacyCheck,
    required Future<bool> Function() udpProbe,
  }) : assert((engine == null) != (engineInitializer == null)),
       _engine = engine,
       // ignore: prefer_initializing_formals
       _engineInitializer = engineInitializer,
       // Named test arguments remain public while their storage is private.
       // ignore: prefer_initializing_formals
       _privacyCheck = privacyCheck,
       // ignore: prefer_initializing_formals
       _udpProbe = udpProbe {
    _tempRoot = tempRoot;
    if (engine != null) _updatesSub = engine.streamUpdates.listen(_onStreamUpdates);
  }

  final Future<void> Function()? _privacyCheck;
  final Future<bool> Function()? _udpProbe;
  final Future<LibtorrentFlutter> Function()? _engineInitializer;

  LibtorrentFlutter? _engine;
  LibtorrentFlutter? _unpublishedEngine;
  Future<LibtorrentFlutter>? _engineInitialization;
  bool _disposed = false;
  Directory? _tempRoot;
  String? _lastTempRootPath;
  int _nextStorageAttempt = 0;

  final Map<String, int> _torrentIds = {}; // magnetUri -> torrent id
  final Map<int, int> _streamIds = {}; // torrent id -> active StreamInfo.id

  /// Magnets whose [stop] arrived BEFORE the torrent existed (the race's RD
  /// leg can win while this leg is still in its engine/VPN probes). Without
  /// this the stop was a silent no-op and the "losing" torrent went on to add
  /// itself and pull metadata for minutes alongside the winning stream.
  /// [streamMagnet] checks it at each checkpoint and aborts.
  final Set<String> _abortRequested = {};
  final Map<String, Object> _pendingRequests = {};
  StreamSubscription<Map<int, StreamInfo>>? _updatesSub;
  // torrent id -> status listener
  final Map<int, void Function(TorrentStreamStatus)> _statusCbs = {};

  /// How long to wait for torrent metadata before giving up.
  ///
  /// 90s is plenty on a healthy swarm, but not when outbound UDP is blocked.
  /// Measured on Surfshark: a tracker returned 50 peers for a 100-seed release
  /// yet only 2 of 12 sampled peers accepted a TCP connection — the rest sit
  /// behind NAT and are normally reached via µTP (UDP) hole-punching, which the
  /// tunnel drops. Metadata still arrives from those few TCP-reachable peers,
  /// it just takes longer, so the UDP-blocked path gets a larger budget rather
  /// than failing a download that was about to work.
  static const Duration _metadataTimeout = Duration(seconds: 90);
  static const Duration _metadataTimeoutTcpOnly = Duration(seconds: 240);
  // Runway before playback starts. 2s was far too small on a constrained swarm/
  // VPN: MPV drained it in seconds and then re-stalled ~12s to refill, an
  // endless rebuffer loop. A large pre-roll lets playback absorb swarm jitter
  // and keep going while pieces trickle in. This is the single biggest lever
  // against "keeps buffering". (libtorrent keeps downloading ahead of the read
  // head, so this is just the head-start, not the whole file.)
  static const double initialBufferSeconds = 20.0;
  static const Duration _initialBufferTimeout = Duration(seconds: 120);

  /// Fail-closed precondition check for ANY torrent add. Throws
  /// [TorrentProxyRequiredException] unless ALL of these hold:
  ///   1. The compile-time master switch [kTorrentPathEnabled] is on.
  ///   2. The Beam proxy is enabled and has a host configured.
  ///   3. A live proxy exit-IP probe actually succeeds (proxy really works).
  /// Only when all three pass may a magnet be added — and by then the session
  /// is configured with a non-zero proxyType, so the native engine routes
  /// peers + DNS through the proxy (proxy_peer_connections/proxy_hostnames).
  Future<void> _assertTorrentAllowed() async {
    if (_privacyCheck != null) return _privacyCheck();
    if (!kTorrentPathEnabled) {
      throw const TorrentProxyRequiredException(
        'Torrent streaming is disabled. Use Real-Debrid (Instant Stream) — '
        'it resolves remotely and never exposes your network.',
      );
    }

    await BeamConfig.init();

    if (!BeamConfig.torrentPlayEnabled) {
      throw const TorrentProxyRequiredException('Torrent playback is turned off in Beam settings.');
    }

    // A DEVICE-LEVEL VPN (Surfshark, Mullvad, PIA, WireGuard…) already tunnels
    // ALL traffic — including the UDP that SOCKS5 can't carry — so it satisfies
    // the "never touch the user's own network" rule on its own, and is the model
    // real torrent streamers use. Accept it INSTEAD of an in-app proxy. This
    // matters for Surfshark in particular, which offers no SOCKS5 endpoint at
    // all, so requiring one would block a fully-protected user.
    if (await VpnDetect.isVpnActive()) {
      final iface = await VpnDetect.activeInterface();
      appLogger.i(
        'TorrentStreamService: device VPN active ($iface) — '
        'torrent swarm allowed (DHT/UDP work through the tunnel).',
      );
      return;
    }

    if (!BeamConfig.proxyEnabled || BeamConfig.proxyHost.trim().isEmpty) {
      throw const TorrentProxyRequiredException(
        'Turn on your VPN (e.g. Surfshark) before streaming a torrent — or set '
        'a SOCKS5 proxy in Beam settings. Real-Debrid works without either.',
      );
    }

    // Prove the proxy actually carries traffic before we let libtorrent touch
    // the wire. If this probe can't reach out through the proxy, we refuse —
    // never fall through to a direct (leaking) connection.
    final exitIp = await BeamHttp.checkProxyExitIp();
    if (exitIp == null) {
      throw const TorrentProxyRequiredException(
        'Proxy is not working — refusing to download over your own network. '
        'Fix the proxy or use Real-Debrid instead.',
      );
    }
    appLogger.i(
      'TorrentStreamService: proxy verified (exit $exitIp) — '
      'torrent swarm allowed.',
    );
  }

  Future<LibtorrentFlutter> _ensureEngine() async {
    if (_disposed) throw const BeamCancelled();
    final existing = _engine;
    if (existing != null) return existing;
    // Candidate races share all cold setup, not only the native singleton.
    // Each caller checks its own cancellation after this shared future returns.
    return _engineInitialization ??= _initializeAndPublishEngine();
  }

  Future<LibtorrentFlutter> _initializeAndPublishEngine() async {
    try {
      final engine = await Future<LibtorrentFlutter>.sync(_engineInitializer ?? _initializeEngine);
      _unpublishedEngine = engine;
      if (_disposed) throw const BeamCancelled();
      _updatesSub = engine.streamUpdates.listen(_onStreamUpdates);
      _engine = engine;
      _unpublishedEngine = null;
      return engine;
    } catch (_) {
      final abandoned = _unpublishedEngine;
      _unpublishedEngine = null;
      try {
        await abandoned?.dispose();
      } catch (_) {}
      await _wipeTempRoot();
      rethrow;
    } finally {
      // A failed attempt is retryable; a disposed service remains closed.
      _engineInitialization = null;
    }
  }

  Future<LibtorrentFlutter> _initializeEngine() async {
    _tempRoot = await _makeTempRoot();
    if (_disposed) throw const BeamCancelled();

    // The native engine must be initialized before `.instance` is legal;
    // init() is idempotent (no-ops if already initialized). Point its default
    // save path at our ephemeral temp root so any stray writes stay wipeable.
    // Bind an EXPLICIT IPv4 listen port. The plugin default is
    // "0.0.0.0:0,[::]:0" and both halves of that are broken on Android:
    //
    //  * port 0 ("pick any") makes libtorrent enumerate routes to choose a
    //    port, and Android 11+ blocks NETLINK_ROUTE socket binding — the
    //    session logs "listening on 0.0.0.0:0 failed: [enum_route] [TCP]
    //    Operation not supported on transport endpoint" and falls back to a
    //    random ephemeral port that changes every run.
    //  * the "[::]" IPv6 half fails on devices without working IPv6 with
    //    "Operation not supported on transport endpoint" (libtorrent #6688).
    //
    // The consequence is subtle and severe: with no stable, properly-bound
    // listen port the session cannot accept INCOMING connections, so it can
    // only ever reach peers that are themselves fully connectable. Seeds
    // behind NAT — which is most of them — need incoming/uTP hole punching,
    // which is why the swarm showed peers but seeds=0 and metadata never
    // arrived. 6881 is the standard BitTorrent port.
    // Alerts carry the swarm diagnostics (tracker replies, listen failures),
    // so keep them on in debug builds only — they are far too chatty for a
    // release build.
    LibtorrentFlutter.debugLogAlerts = kDebugMode;
    await LibtorrentFlutter.init(defaultSavePath: _tempRoot!.path, listenInterface: '0.0.0.0:6881');
    final engine = LibtorrentFlutter.instance;
    _unpublishedEngine = engine;
    if (_disposed) throw const BeamCancelled();

    // Privacy hardening. Wrapped so a missing/renamed field can't brick the
    // whole engine bring-up. BtConfig is immutable (copyWith), and proxy needs
    // the async pass, so build the config via applyProxyFromConfig.
    try {
      var cfg = engine.getDefaultConfig().copyWith(
        // forceEncrypt maps to libtorrent pe_forced, which REFUSES any
        // peer that will not do encrypted transport. Most public-swarm
        // peers won't, so this rejected almost the entire swarm: 357 of
        // 400 captured alerts were CONNECTION FAILED, and metadata never
        // arrived because there was nobody left to fetch it from.
        //
        // false => pe_enabled, which still encrypts with every peer that
        // supports it and only falls back to plaintext for peers that
        // don't. The traffic already rides inside the VPN tunnel, so the
        // ISP-visible privacy posture is unchanged.
        forceEncrypt: false,
        // Must NOT disable upload. BitTorrent is reciprocal: a client that
        // uploads nothing gets choked by peers, which starves the very
        // metadata/piece requests we are waiting on. Leaving upload on is
        // required for the swarm to serve us at all, and it is bounded by
        // the ephemeral lifetime of the torrent (removed + wiped on stop).
        disableUpload: false,
      );
      cfg = await _withProxy(cfg);
      if (_disposed) throw const BeamCancelled();
      engine.configureSession(cfg);
    } on BeamCancelled {
      rethrow;
    } on TorrentProxyRequiredException {
      // NEVER swallow a privacy failure. If the proxy could not be applied to
      // the session, the engine must not come up in a state that can download
      // direct. Propagate so streamMagnet tears down and refuses.
      rethrow;
    } catch (e) {
      // Only non-privacy config knobs (a renamed field, etc.) are tolerated.
      appLogger.w('TorrentStreamService: non-proxy config hardening skipped: $e');
    }

    return engine;
  }

  Future<Directory> _makeTempRoot() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}plezy_torrents_'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    await dir.create(recursive: true);
    _lastTempRootPath = dir.path;
    return dir;
  }

  String _sourceSavePath(String magnet) {
    // Native storage creates this directory. Keep the application-owned root
    // after stopAll so a warm engine never falls back to its shared save path.
    // Injected test engines have no platform temporary-directory provider.
    final root = _tempRoot ??= Directory(
      _lastTempRootPath ??
          '${Directory.systemTemp.path}${Platform.pathSeparator}plezy_torrents_test_${identityHashCode(this)}',
    );
    _lastTempRootPath = root.path;
    final parsed = infoHashFromMagnet(magnet);
    final hash = parsed != null && RegExp(r'^[0-9a-f]{40}$').hasMatch(parsed) ? parsed : 'unidentified';
    // The extra attempt leaf also isolates delayed delete_files completion
    // from a replacement of the same hash (for example the TCP retry).
    return '${root.path}${Platform.pathSeparator}$hash${Platform.pathSeparator}attempt_${++_nextStorageAttempt}';
  }

  /// Adds [magnetUri], waits for metadata + a streamable video file, starts the
  /// stream on the largest streamable file, and returns the localhost URL for
  /// the player. [onStatus] receives live buffering/progress events.
  Future<String> streamMagnet(
    String magnetUri, {
    void Function(TorrentStreamStatus)? onStatus,
    void Function(String)? onPreparationStatus,
    void Function(String filename)? onFileSelected,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    BeamPlaybackDuration? playbackDuration,
    BeamBufferWaitController? bufferWait,
    BeamCancellation? cancellation,
  }) async {
    final request = Object();
    _pendingRequests[magnetUri] = request;
    _abortRequested.remove(magnetUri);
    bool Function() ownsStatus = () => identical(_pendingRequests[magnetUri], request);
    String? lastPreparationStatus;
    void reportPreparation(String status) {
      if (_disposed || (cancellation?.isCancelled ?? false) || _abortRequested.contains(magnetUri) || !ownsStatus()) {
        return;
      }
      if (lastPreparationStatus == status) return;
      lastPreparationStatus = status;
      onPreparationStatus?.call(status);
    }

    void checkPending() {
      cancellation?.check();
      if (!identical(_pendingRequests[magnetUri], request) || _abortRequested.contains(magnetUri)) {
        throw const BeamCancelled();
      }
    }

    // Pending request order is separate from active stream ownership: a new
    // refusal cannot disown the old player, nor can a stale privacy check win
    // ownership back from a more recent request.
    late final LibtorrentFlutter engine;
    late final int? existingId;
    int? reuseIndex;
    try {
      reportPreparation('Checking torrent connection');
      await _assertTorrentAllowed();
      checkPending();
      reportPreparation('Starting torrent engine');
      engine = await _ensureEngine();
      checkPending();
      existingId = _torrentIds[magnetUri];
      if (existingId != null && _streamIds.containsKey(existingId) && engine.torrents.containsKey(existingId)) {
        reuseIndex = _pickFileIndex(
          engine,
          existingId,
          season: season,
          episode: episode,
          storyConstraint: storyConstraint,
          onPreparationStatus: reportPreparation,
        );
      }
    } finally {
      if (identical(_pendingRequests[magnetUri], request)) _pendingRequests.remove(magnetUri);
    }
    final owner = Object();
    _owners[magnetUri] = owner;
    bool owns() => identical(_owners[magnetUri], owner);
    ownsStatus = owns;
    bool shouldAbort() => !owns() || (cancellation?.isCancelled ?? false) || _abortRequested.contains(magnetUri);
    void check() {
      if (shouldAbort()) throw const BeamCancelled();
    }

    void listenForCancellation(int Function() torrentId) {
      if (cancellation == null) return;
      unawaited(
        cancellation.whenCancelled
            .then((_) async {
              if (!owns()) return;
              await _teardownTorrent(engine, torrentId());
              if (owns()) {
                _torrentIds.remove(magnetUri);
                _owners.remove(magnetUri);
              }
            })
            .catchError((Object error) {
              appLogger.w('TorrentStreamService: cancellation cleanup failed: $error');
            }),
      );
    }

    check();
    if (existingId != null && reuseIndex != null) {
      listenForCancellation(() => existingId!);
      try {
        // Native startStream creates a new URL/stream ID while retaining the
        // torrent's metadata, peers and downloaded pieces.
        final info = engine.startStream(existingId, fileIndex: reuseIndex);
        _applyPlaybackDuration(engine, existingId, reuseIndex, info.id, playbackDuration, season, episode);
        if (onFileSelected != null) {
          final file = engine.getFiles(existingId).singleWhere((file) => file.index == reuseIndex);
          onFileSelected(file.path.isEmpty ? file.name : file.path);
        }
        _streamIds[existingId] = info.id;
        if (onStatus != null) {
          _statusCbs[existingId] = onStatus;
        } else {
          _statusCbs.remove(existingId);
        }
        reportPreparation('Buffering video');
        await _waitForInitialBuffer(engine, existingId, shouldAbort: shouldAbort, bufferWait: bufferWait);
        check();
        return info.url;
      } catch (_) {
        if (owns()) {
          await _teardownTorrent(engine, existingId);
          if (owns()) {
            _torrentIds.remove(magnetUri);
            _owners.remove(magnetUri);
          }
        }
        rethrow;
      }
    }
    if (existingId != null) {
      await _teardownTorrent(engine, existingId);
      check();
      _torrentIds.remove(magnetUri);
    }

    // Rewrite the tracker set for the current network path. When UDP can't get
    // out — always true through SOCKS5 (TCP-only by protocol), and true through
    // VPNs that drop UDP such as Surfshark — udp:// trackers and DHT find 0
    // peers and the engine stalls forever on "downloading metadata". Swapping
    // in verified TCP trackers (and dropping the udp:// ones that shadow them)
    // is what makes peer discovery work at all on those paths.
    reportPreparation('Checking tracker connectivity');
    final udpOk = await (_udpProbe?.call() ?? VpnDetect.udpWorks());
    check();
    // The plugin injects ngosang/trackers_best.txt into every magnet, and that
    // list is overwhelmingly udp:// — on a UDP-blocked path those entries can
    // only time out AND they shadow the working http:// endpoint for the same
    // host. Filter them at the injector, not just in our own magnet string.
    TrackerManager.tcpOnly = !udpOk;
    final proxiedMagnet = udpOk ? magnetUri : augmentMagnetForProxy(magnetUri);
    if (!udpOk) {
      appLogger.i(
        'TorrentStreamService: outbound UDP blocked — using '
        'TCP-only trackers for peer discovery.',
      );
    }
    var id = engine.addMagnet(proxiedMagnet, _sourceSavePath(magnetUri), true);
    _torrentIds[magnetUri] = id;
    // Keep listening after readiness: cancellation can lose the race in the
    // same event turn that the URL is produced. Ownership prevents late cleanup
    // from tearing down a subsequent episode in the same season pack.
    listenForCancellation(() => id);
    if (onStatus != null) _statusCbs[id] = onStatus;
    // From here on a stop() finds the id directly; a request that raced the
    // add above is honored inside the metadata wait via shouldAbort.

    try {
      int fileIndex;
      try {
        fileIndex = await _waitForStreamableFile(
          engine,
          id,
          tcpOnly: !udpOk,
          shouldAbort: shouldAbort,
          season: season,
          episode: episode,
          storyConstraint: storyConstraint,
          onPreparationStatus: reportPreparation,
        );
      } on TimeoutException {
        // Metadata never arrived. A successful UDP tracker probe does not
        // guarantee reachable peers for this source. When no peers remain,
        // retry once with HTTP trackers. This changes the torrent's tracker
        // list only; the shared session's DHT/uTP settings remain unchanged.
        final t = engine.torrents[id];
        final noPeers = (t?.numPeers ?? 0) == 0 && (t?.numSeeds ?? 0) == 0;
        if (udpOk && noPeers) {
          appLogger.w(
            'TorrentStreamService: metadata timed out with 0 peers — '
            'retrying with HTTP trackers; DHT/uTP settings unchanged.',
          );
          check();
          await _teardownTorrent(engine, id);
          check();
          TrackerManager.tcpOnly = true;
          reportPreparation('Retrying with HTTP trackers');
          final tcpMagnet = augmentMagnetForProxy(magnetUri);
          id = engine.addMagnet(tcpMagnet, _sourceSavePath(magnetUri), true);
          _torrentIds[magnetUri] = id;
          if (onStatus != null) _statusCbs[id] = onStatus;
          fileIndex = await _waitForStreamableFile(
            engine,
            id,
            tcpOnly: true,
            shouldAbort: shouldAbort,
            season: season,
            episode: episode,
            storyConstraint: storyConstraint,
            onPreparationStatus: reportPreparation,
          );
        } else {
          rethrow;
        }
      }
      check();
      final info = engine.startStream(id, fileIndex: fileIndex);
      _applyPlaybackDuration(engine, id, fileIndex, info.id, playbackDuration, season, episode);
      if (onFileSelected != null) {
        final file = engine.getFiles(id).singleWhere((file) => file.index == fileIndex);
        onFileSelected(file.path.isEmpty ? file.name : file.path);
      }
      _streamIds[id] = info.id;
      reportPreparation('Buffering video');
      // startStream creates the localhost HTTP endpoint immediately, but that
      // does not mean the first media pieces exist yet. Wait for the native
      // engine's contiguous-buffer telemetry before opening the player; this
      // avoids handing MPV a valid URL whose body is still unable to respond.
      await _waitForInitialBuffer(engine, id, shouldAbort: shouldAbort, bufferWait: bufferWait);
      check();
      appLogger.i(
        'TorrentStreamService: streaming t=$id file=$fileIndex '
        'url=${info.url}',
      );
      return info.url;
    } catch (e) {
      // Never leak a half-added torrent's files on failure.
      appLogger.e('TorrentStreamService: streamMagnet failed: $e');
      if (owns()) {
        await _teardownTorrent(engine, id);
        if (owns()) {
          _torrentIds.remove(magnetUri);
          _owners.remove(magnetUri);
        }
      }
      rethrow;
    }
  }

  void _applyPlaybackDuration(
    LibtorrentFlutter engine,
    int torrentId,
    int fileIndex,
    int streamId,
    BeamPlaybackDuration? duration,
    int? season,
    int? episode,
  ) {
    if (duration == null) return;
    final file = engine.getFiles(torrentId).singleWhere((file) => file.index == fileIndex);
    final runtime = duration.forFile(file.path.isEmpty ? file.name : file.path, season: season, episode: episode);
    if (runtime != null) engine.setStreamDuration(streamId, runtime);
  }

  Future<void> _waitForInitialBuffer(
    LibtorrentFlutter engine,
    int torrentId, {
    required bool Function() shouldAbort,
    BeamBufferWaitController? bufferWait,
  }) async {
    var expired = false;
    var acceptedCount = bufferWait?.continuationCount ?? 0;
    Timer? deadline;
    void renew() {
      expired = false;
      deadline?.cancel();
      final consent = bufferWait?.remainingConsent ?? Duration.zero;
      final budget = consent > _initialBufferTimeout ? consent : _initialBufferTimeout;
      deadline = Timer(budget, () => expired = true);
    }

    renew();
    try {
      while (true) {
        if (shouldAbort()) throw const BeamCancelled();
        final stream = engine.streams[_streamIds[torrentId]];
        // Readiness keeps racing while the UI is waiting for an answer.
        if (stream != null && stream.torrentId == torrentId && stream.bufferSeconds >= initialBufferSeconds) return;
        if (bufferWait?.declined ?? false) {
          throw TimeoutException('Initial torrent buffer wait declined', _initialBufferTimeout);
        }
        if (bufferWait != null && acceptedCount != bufferWait.continuationCount) {
          acceptedCount = bufferWait.continuationCount;
          renew();
        }
        if (expired) {
          if (bufferWait == null) throw TimeoutException('Initial torrent buffer timed out', _initialBufferTimeout);
          // Coalesces with a pending slow/stall offer; never await the dialog.
          unawaited(bufferWait.request(BeamBufferWaitReason.initialDeadline));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      deadline?.cancel();
    }
  }

  /// Polls getFiles until metadata arrives and at least one streamable video
  /// file exists, then returns the index of the largest such file.
  Future<int> _waitForStreamableFile(
    LibtorrentFlutter engine,
    int id, {
    bool tcpOnly = false,
    bool Function()? shouldAbort,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    void Function(String)? onPreparationStatus,
  }) async {
    final budget = tcpOnly ? _metadataTimeoutTcpOnly : _metadataTimeout;
    final deadline = DateTime.now().add(budget);
    var lastLog = DateTime.now();
    while (DateTime.now().isBefore(deadline)) {
      if (shouldAbort?.call() ?? false) {
        throw StateError('torrent stream cancelled during metadata wait');
      }
      final idx = _pickFileIndex(
        engine,
        id,
        season: season,
        episode: episode,
        storyConstraint: storyConstraint,
        onPreparationStatus: onPreparationStatus,
      );
      if (idx != null) return idx;
      final torrent = engine.torrents[id];
      final peers = torrent?.numPeers ?? 0;
      final seeds = torrent?.numSeeds ?? 0;
      onPreparationStatus?.call(
        '${peers > 0 ? 'Downloading torrent metadata' : 'Finding peers'}${tcpOnly ? ' via HTTP trackers' : ''} · $peers peers · $seeds seeds',
      );
      // Surface progress so a slow-but-working TCP-only fetch is visibly
      // alive rather than looking identical to a hung one.
      if (DateTime.now().difference(lastLog) >= const Duration(seconds: 15)) {
        lastLog = DateTime.now();
        final t = engine.torrents[id];
        appLogger.i(
          'TorrentStreamService: awaiting metadata '
          '(peers=${t?.numPeers ?? 0} seeds=${t?.numSeeds ?? 0}, '
          '${deadline.difference(DateTime.now()).inSeconds}s left)',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw TimeoutException('No streamable file after metadata wait', budget);
  }

  /// Largest streamable video file index, or null if metadata/files not ready.
  /// Consecutive getFiles() failures per torrent. Before metadata arrives
  /// getFiles legitimately throws, so a few failures are normal — but a
  /// PERSISTENT failure means something real is broken (dead session, bad id)
  /// and must not masquerade as "still waiting for metadata" for the whole
  /// timeout with nothing in the log.
  final Map<int, int> _getFilesFailures = {};

  final Map<String, Object> _owners = {};

  int? _pickFileIndex(
    LibtorrentFlutter engine,
    int id, {
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    void Function(String)? onPreparationStatus,
  }) {
    final List<FileInfo> files;
    try {
      files = engine.getFiles(id);
      _getFilesFailures.remove(id);
    } catch (e) {
      final n = (_getFilesFailures[id] ?? 0) + 1;
      _getFilesFailures[id] = n;
      // ~0.5s poll interval, so 20 ≈ 10s of solid failure.
      if (n == 20) {
        appLogger.w(
          'TorrentStreamService: getFiles(t=$id) failing '
          'persistently ($n consecutive): $e',
        );
      }
      return null; // metadata not in yet
    }
    if (files.isEmpty) return null;

    onPreparationStatus?.call(
      season != null && episode != null ? 'Verifying requested episode' : 'Selecting video file',
    );

    return selectFileIndex(files, season: season, episode: episode, storyConstraint: storyConstraint);
  }

  static int selectFileIndex(
    List<FileInfo> files, {
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
  }) {
    return EpisodeFileSelector.select(
      files.map(
        (f) =>
            EpisodeFile(id: f.index, path: f.path.isEmpty ? f.name : f.path, size: f.size, streamable: f.isStreamable),
      ),
      season: season,
      episode: episode,
      storyConstraint: storyConstraint,
    ).id;
  }

  void _onStreamUpdates(Map<int, StreamInfo> updates) {
    final engine = _engine;
    if (engine == null) return;
    for (final info in updates.values) {
      if (_streamIds[info.torrentId] != info.id) continue;
      final cb = _statusCbs[info.torrentId];
      if (cb == null) continue;

      // Status comes from the engine's torrents map (updated via its own
      // torrentUpdates stream); may briefly be absent right after add.
      final TorrentInfo? st = engine.torrents[info.torrentId];
      cb(
        TorrentStreamStatus(
          progress: st?.progress ?? 0,
          downloadRate: st?.downloadRate ?? 0,
          totalDone: st?.totalDone ?? 0,
          numSeeds: st?.numSeeds ?? 0,
          bufferSeconds: info.bufferSeconds,
          // The native stream starts in BUFFERING and moves to READY only after
          // it has actually served playable bytes to the local player. Do not
          // claim readiness merely because the localhost URL exists.
          ready: info.isReady,
          url: info.url,
        ),
      );
    }
  }

  /// Returns [cfg] with the active BeamConfig proxy applied. Uses the forked
  /// libtorrent_flutter BtConfig proxy fields so the SWARM (and its DNS) routes
  /// through the user's proxy — the "hidden while downloading" guarantee.
  /// proxyType values (native): 2=socks5, 4=socks5_pw, 3=http, 5=http_pw.
  Future<BtConfig> _withProxy(BtConfig cfg) async {
    // DEVICE VPN path: the tunnel already carries everything, so we do NOT set
    // a libtorrent proxy at all — and crucially we LEAVE DHT + uTP ON. They were
    // only ever disabled to work around SOCKS5 being TCP-only; over a VPN they
    // work normally and give far better peer discovery (this is how Elementum /
    // Stremio operate). No proxy fields => no SOCKS bottleneck, full speed.
    if (await VpnDetect.isVpnActive()) {
      // A tunnel being up does NOT mean it carries UDP. Surfshark drops
      // outbound UDP (verified on-device), which kills DHT and every udp://
      // tracker. Probe, then only keep DHT/uTP when UDP genuinely works —
      // otherwise they burn the whole metadata timeout finding nothing.
      final udpOk = await VpnDetect.udpWorks();
      appLogger.i(
        'TorrentStreamService: VPN tunnel carries the swarm — '
        'UDP ${udpOk ? "works, DHT/uTP enabled" : "BLOCKED, TCP-only mode"}, '
        'no SOCKS5 layer.',
      );
      return cfg.copyWith(
        proxyType: 0,
        disableDht: !udpOk,
        disableUtp: !udpOk,
        // A VPN sustains far more sockets than a SOCKS5 proxy could.
        //
        // This is multiplied by 20 natively (=> ~400 peer connections). It
        // needs to be generous: only a small minority of a public swarm is
        // directly connectable (measured: 1 of 20 sampled peers accepted a TCP
        // connection — the rest are NAT'd), so a tight cap means we exhaust
        // our slots on unreachable peers and never find the few that answer.
        connectionsLimit: 20,
      );
    }

    // Fail-closed: this is only ever reached AFTER _assertTorrentAllowed has
    // confirmed the proxy is enabled, configured, and working. If the proxy is
    // somehow off/unset here, DO NOT return an unproxied cfg (that was the
    // leak) — throw so the session is never brought up able to download direct.
    if (!BeamConfig.proxyEnabled) {
      throw const TorrentProxyRequiredException('Refusing to configure the torrent engine without a proxy.');
    }
    final host = BeamConfig.proxyHost.trim();
    if (host.isEmpty) {
      throw const TorrentProxyRequiredException('Refusing to configure the torrent engine: proxy host is empty.');
    }

    final port = BeamConfig.proxyPort;
    final user = BeamConfig.proxyUser;
    final pass = await BeamConfig.getProxyPass();
    final isHttp = BeamConfig.proxyScheme.toLowerCase().startsWith('http');
    final hasAuth = user.isNotEmpty || pass.isNotEmpty;

    final int proxyType = isHttp ? (hasAuth ? 5 : 3) : (hasAuth ? 4 : 2);

    appLogger.i(
      'TorrentStreamService: swarm via '
      '${BeamConfig.proxyScheme}://$host:$port (type=$proxyType)',
    );
    // SOCKS5 carries TCP only. libtorrent 2.x deliberately refuses to send UDP
    // (DHT, uTP, udp:// trackers) unless the proxy does UDP-ASSOCIATE — which
    // most (incl. simple SOCKS5) do NOT — and it does NOT fall back to direct
    // (anti-leak). So when proxied we commit to the TCP path: disable DHT + uTP
    // and rely on TCP peers + http/https trackers (augmentMagnetForProxy adds
    // those). Otherwise the engine sits forever "downloading metadata" with 0
    // reachable peers. (Researched: BEP-37 + libtorrent settings, 2026.)
    return cfg.copyWith(
      proxyType: proxyType,
      proxyHost: host,
      proxyPort: port,
      proxyUser: user,
      proxyPass: pass,
      disableDht: true,
      disableUtp: true,
      // Cap peer connections when proxied. The native fork multiplies this by
      // 20, so 3 => ~60 sockets. Free/public SOCKS5 proxies (and even many
      // paid ones) DROP connections under a full torrent swarm's volume
      // ("SOCKS5 error: End of file"), which stalls metadata. A modest cap lets
      // the proxy sustain the sockets — verified: 500 conns floods + stalls,
      // ~30-60 conns streams metadata in ~15s then data @200KB/s+.
      connectionsLimit: 3,
    );
  }

  /// Stops one torrent by its magnet URI (the value passed to [streamMagnet]).
  /// Falls back to treating the arg as a stringified torrent id.
  Future<void> stop(String magnetOrId) async {
    final engine = _engine;
    // Record the abort FIRST, always. Tearing the torrent down does not stop
    // an in-flight streamMagnet: its metadata wait keeps polling the (now
    // removed) id until its 90/240s budget expires, which is how the losing
    // race leg kept logging "awaiting metadata" after the winner was already
    // playing. The wait checks this set every 500ms and bails out.
    if (magnetOrId.startsWith('magnet:')) _abortRequested.add(magnetOrId);
    int? id = engine == null ? null : _torrentIds[magnetOrId];
    id ??= int.tryParse(magnetOrId);
    if (engine == null || id == null) {
      // Nothing to tear down YET — the torrent for this magnet may still be
      // starting (engine bring-up / metadata). Remember the request so the
      // in-flight streamMagnet aborts at its next checkpoint instead of
      // silently continuing as an orphan.
      if (magnetOrId.startsWith('magnet:')) {
        appLogger.i('TorrentStreamService.stop: torrent not started yet — abort requested');
      } else {
        appLogger.w('TorrentStreamService.stop: unknown target "$magnetOrId"');
      }
      return;
    }
    for (final key in _torrentIds.entries.where((entry) => entry.value == id).map((entry) => entry.key).toList()) {
      _owners.remove(key);
    }
    await _teardownTorrent(engine, id);
    _torrentIds.removeWhere((_, v) => v == id);
  }

  /// Stops the torrent backing a localhost player URL. Real-Debrid/remote URLs
  /// are ignored, so callers can use this unconditionally when a direct-player
  /// route closes.
  Future<void> stopUrl(String url) async {
    final engine = _engine;
    if (engine == null || !url.startsWith('http://127.0.0.1:')) return;
    StreamInfo? stream;
    for (final info in engine.streams.values) {
      if (info.url == url) {
        stream = info;
        break;
      }
    }
    if (stream == null) return;
    final torrentId = stream.torrentId;
    if (_streamIds[torrentId] != stream.id) {
      // Closing the old episode route must not tear down the new episode's
      // stream when both share this retained torrent.
      engine.stopStream(stream.id);
      return;
    }
    for (final key
        in _torrentIds.entries.where((entry) => entry.value == torrentId).map((entry) => entry.key).toList()) {
      _owners.remove(key);
    }
    await _teardownTorrent(engine, torrentId);
    _torrentIds.removeWhere((_, id) => id == torrentId);
  }

  /// Stops and DELETES every active torrent + wipes the temp subdir.
  Future<void> stopAll() async {
    _pendingRequests.clear();
    final engine = _engine;
    if (engine == null) {
      await _wipeTempRoot();
      return;
    }
    _owners.clear();
    final ids = _torrentIds.values.toSet();
    for (final id in ids) {
      await _teardownTorrent(engine, id);
    }
    _torrentIds.clear();
    _statusCbs.clear();
    _streamIds.clear();
    await _wipeTempRoot();
  }

  /// Stops streams + removeTorrent(deleteFiles:true) for a single torrent id.
  Future<void> _teardownTorrent(LibtorrentFlutter engine, int id) async {
    try {
      engine.stopAllStreamsForTorrent(id);
    } catch (e) {
      appLogger.w('TorrentStreamService: stopStreams t=$id: $e');
    }
    try {
      // deleteFiles:true is the EPHEMERAL guarantee — no partial pieces remain.
      engine.removeTorrent(id, deleteFiles: true);
    } catch (e) {
      appLogger.w('TorrentStreamService: removeTorrent t=$id: $e');
    }
    _streamIds.remove(id);
    _statusCbs.remove(id);
  }

  Future<void> _wipeTempRoot() async {
    final root = _tempRoot;
    if (root == null) return;
    try {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    } catch (e) {
      appLogger.w('TorrentStreamService: temp wipe failed: $e');
    }
    _tempRoot = null;
  }

  /// Full teardown: remove+delete every torrent, wipe temp dir, drop the engine.
  /// Safe to call from app-exit / widget dispose. Fire-and-forget friendly.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final engine = _engine;
    final initializing = _engineInitialization;
    _updatesSub?.cancel();
    _updatesSub = null;
    unawaited(() async {
      try {
        await initializing;
      } catch (_) {}
      await stopAll(); // removeTorrent(deleteFiles:true) for all + wipe temp dir
      try {
        await engine?.dispose();
      } catch (_) {}
      _engine = null;
    }());
  }
}
