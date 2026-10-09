import 'dart:async';

import 'package:plezy/utils/app_logger.dart';

import 'adaptive_quality.dart';
import 'beam_http.dart';
import 'media_server.dart';
import 'port_forward_service.dart';
import 'prowlarr_client.dart';
import 'realdebrid_client.dart';
import 'torrent_stream_service.dart';

/// Composition root that wires the standalone Beam services into a single
/// running "media center":
///
///  * [BeamMediaServer] — LAN-facing HTTP/DLNA server exposing resolved streams.
///  * [PortForwardService] — auto-opens the server's port on the router
///    (NAT-PMP / UPnP) when it starts, and renews the lease on a timer.
///  * [AdaptiveQualityController] — receives the media server's per-client
///    delivery-rate samples (and torrent buffer telemetry) and downshifts an
///    item to a lower-bitrate candidate, swapping the server's upstream URL.
///
/// The three primitives are intentionally decoupled; this class is the ONLY
/// place they are connected, so the app has one start/stop lifecycle.
///
/// A process-wide [instance] is provided so the settings toggle and any serving
/// UI share one running server; construct your own for tests.
class BeamMediaCenter {
  BeamMediaCenter({
    BeamMediaServer? server,
    PortForwardService? portForward,
    TorrentStreamService? torrent,
  })  : _server = server ?? BeamMediaServer(),
        _portForward = portForward ?? PortForwardService(),
        _torrent = torrent ?? TorrentStreamService.instance;

  /// Process-wide shared instance (used by the settings toggle + serving UI).
  static final BeamMediaCenter instance = BeamMediaCenter();

  final BeamMediaServer _server;
  final PortForwardService _portForward;
  final TorrentStreamService _torrent;

  bool get isRunning => _started;

  BeamMediaServer get server => _server;
  PortForwardService get portForward => _portForward;

  /// One adaptive controller per served item, keyed by item id. Each controller
  /// is bound to swap THIS item's upstream on the media server.
  final Map<String, AdaptiveQualityController> _controllers = {};

  PortMapping? _mapping;
  Timer? _renewTimer;
  bool _started = false;

  /// Whether the router mapping succeeded — a remote peer can reach the server.
  bool get isPubliclyReachable => _mapping != null;

  /// The last port-forward diagnostic (CGNAT explanation, etc.), if any.
  String? get portDiagnostic => _portForward.lastDiagnostic;

  /// The mapping opened for the media server, or null if none succeeded.
  PortMapping? get mapping => _mapping;

  // ---- lifecycle -----------------------------------------------------------

  /// Start the media server and (best-effort) open its port on the router.
  /// [openPort] can be disabled for LAN-only use.
  Future<void> start({bool openPort = true}) async {
    if (_started) return;
    _started = true;

    // Route the media server's per-client rate samples into whichever
    // adaptive controller owns that item.
    _server.onClientRate = (itemId, rateBytesPerSec) {
      _controllers[itemId]?.reportRate(rateBytesPerSec);
    };

    await _server.start();

    if (openPort) {
      unawaited(_openAndScheduleRenew());
    }
  }

  Future<void> _openAndScheduleRenew() async {
    try {
      final m = await _portForward.openPort(
        internalPort: _server.port,
        externalPort: _server.port,
        protocol: 'TCP',
        lifetimeSeconds: 3600,
        description: 'MediaBeam',
      );
      if (m == null) {
        appLogger.w('BeamMediaCenter: port-forward failed — LAN-only. '
            '${_portForward.lastDiagnostic ?? ''}');
        return;
      }
      _mapping = m;
      appLogger.i('BeamMediaCenter: port open $m');
      // Renew at half the granted lifetime (min 60s) so it never lapses.
      final half = (m.lifetime ~/ 2).clamp(60, 1800);
      _renewTimer?.cancel();
      _renewTimer = Timer.periodic(Duration(seconds: half), (_) async {
        try {
          await _portForward.renew(m);
          appLogger.d('BeamMediaCenter: renewed port mapping');
        } catch (e) {
          appLogger.w('BeamMediaCenter: renew failed: $e');
        }
      });
    } catch (e, st) {
      appLogger.e('BeamMediaCenter: openPort threw', error: e, stackTrace: st);
    }
  }

  /// Serve an item to LAN clients under [itemId], starting from the best of
  /// [candidates]. As clients pull the stream, throughput is measured and the
  /// item is downshifted to a lower-bitrate candidate if the pipe can't keep up.
  ///
  /// [mode] selects how a candidate becomes a URL: Real-Debrid instant links
  /// (default) or a local torrent-stream URL. Returns the media server's public
  /// `/stream/<id>` URL that other devices should open.
  Future<String> serve({
    required String itemId,
    required String title,
    required List<ProwlarrResult> candidates,
    PlaybackMode mode = PlaybackMode.realDebrid,
    String? posterUrl,
  }) async {
    if (!_started) await start();
    if (candidates.isEmpty) {
      throw StateError('BeamMediaCenter.serve: no candidates');
    }

    // Tear down any prior controller for this id.
    _controllers.remove(itemId)?.dispose();

    final controller = AdaptiveQualityController(
      resolveToUrl: (c) => _resolveCandidate(c, mode, itemId),
      onSwap: (url) => _server.swapStreamUrl(itemId, url),
    );
    _controllers[itemId] = controller;

    final session = await controller.startBest(
      candidates: candidates,
      mode: mode,
      itemIdForServer: itemId,
    );

    _server.addItem(MediaItem(
      id: itemId,
      title: title,
      streamUrl: session.playableUrl,
      posterUrl: posterUrl,
    ));

    return '${_server.baseUrl}/stream/$itemId';
  }

  /// Resolve one candidate to a directly-playable upstream URL. For torrent
  /// mode the returned URL is a local torrent-stream endpoint, and the torrent
  /// engine's buffer/rate telemetry is fed back into that item's controller.
  Future<String> _resolveCandidate(
    ProwlarrResult candidate,
    PlaybackMode mode,
    String itemId,
  ) async {
    switch (mode) {
      case PlaybackMode.realDebrid:
        final link = candidate.grabLink;
        if (link == null || link.isEmpty) {
          throw StateError('candidate has no grabbable link for Real-Debrid');
        }
        final client = await BeamHttp.client();
        try {
          final rd = RealDebridClient(httpClient: client);
          final res = await rd.resolveMagnet(link);
          final vid = res.primaryVideo;
          if (vid == null) throw StateError('RD returned no video stream');
          return vid.downloadUrl;
        } finally {
          client.close();
        }
      case PlaybackMode.torrent:
        final magnet = candidate.magnetUrl;
        if (magnet == null || magnet.isEmpty) {
          throw StateError('candidate has no magnet for torrent streaming');
        }
        return _torrent.streamMagnet(
          magnet,
          onStatus: (s) => _controllers[itemId]?.onTorrentStatus(s),
        );
    }
  }

  /// Stop serving one item: remove it from the catalog, dispose its controller,
  /// and stop any torrent backing it.
  Future<void> unserve(String itemId, {String? magnet}) async {
    _controllers.remove(itemId)?.dispose();
    _server.removeItem(itemId);
    if (magnet != null) {
      try {
        await _torrent.stop(magnet);
      } catch (e) {
        appLogger.w('BeamMediaCenter.unserve torrent stop: $e');
      }
    }
  }

  /// Full shutdown: close the port mapping, stop the server, dispose everything.
  Future<void> stop() async {
    _renewTimer?.cancel();
    _renewTimer = null;
    final m = _mapping;
    if (m != null) {
      try {
        await _portForward.closePort(m);
      } catch (e) {
        appLogger.w('BeamMediaCenter: closePort failed: $e');
      }
      _mapping = null;
    }
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    // Note: _torrent is a shared singleton — do NOT dispose it here; per-item
    // torrents are stopped via [unserve].
    await _server.stop();
    _started = false;
  }
}
