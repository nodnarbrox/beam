import 'dart:async';

import 'package:plezy/utils/app_logger.dart';

import 'device_capability.dart';
import 'network_class.dart';
import 'prowlarr_client.dart';
import 'release_quality.dart';
import 'torrent_stream_service.dart';

/// How the highest-quality candidate is turned into a playable URL.
enum PlaybackMode { realDebrid, torrent }

/// Lifecycle signals emitted on [AdaptiveQualityController.events].
enum QualityEventKind { resolving, playing, downshifted, upshifted }

/// One event on the controller's stream. [url] is the new playable URL for the
/// player / media-server to switch to (null for a bare `resolving` signal).
class QualityEvent {
  const QualityEvent(this.kind, {this.url, this.candidate, this.index, this.reason});
  final QualityEventKind kind;
  final String? url;
  final ProwlarrResult? candidate;
  final int? index;
  final String? reason;

  @override
  String toString() =>
      'QualityEvent(${kind.name}, idx=$index, reason=$reason, url=$url)';
}

/// The currently-playing selection.
class QualitySession {
  QualitySession({
    required this.playableUrl,
    required this.currentCandidate,
    required this.currentIndex,
  });
  String playableUrl;
  ProwlarrResult currentCandidate;
  int currentIndex;

  ReleaseQuality get quality => ReleaseQuality.parse(currentCandidate.title);
}

/// Glues Prowlarr candidates + a resolver (RD or torrent) + live rate/buffer
/// telemetry into an adaptive-quality controller. It plays the HIGHEST-quality
/// candidate immediately, then DOWNSHIFTS to the next-lower resolution when the
/// measured throughput or torrent buffer can't sustain the current source.
///
/// Decoupled by design: the caller injects [resolveToUrl] (so RD-vs-torrent
/// resolution logic lives with the caller / its creds) and an optional [onSwap]
/// (e.g. `BeamMediaServer.swapStreamUrl` bound to an itemId). Nothing here
/// constructs a RealDebridClient or BeamMediaServer.
class AdaptiveQualityController {
  // ignore_for_file: prefer_initializing_formals, type_init_formals
  AdaptiveQualityController({
    required Future<String> Function(ProwlarrResult candidate) resolveToUrl,
    void Function(String url)? onSwap,
    this.minDwell = const Duration(seconds: 15),
    this.sustainWindow = const Duration(seconds: 8),
    this.lowBufferSeconds = 5.0,
  })  : _resolveToUrl = resolveToUrl,
        _onSwap = onSwap;

  final Future<String> Function(ProwlarrResult) _resolveToUrl;
  final void Function(String url)? _onSwap;

  /// Minimum time to stay on a source before another switch — anti-thrash.
  final Duration minDwell;

  /// A shortfall must persist this long before we act (rules out brief dips).
  final Duration sustainWindow;

  /// Torrent buffer below this many seconds counts as "starving".
  final double lowBufferSeconds;

  final _events = StreamController<QualityEvent>.broadcast();
  Stream<QualityEvent> get events => _events.stream;

  List<ProwlarrResult> _candidates = const [];
  PlaybackMode _mode = PlaybackMode.realDebrid;

  /// The playback mode set by the last [startBest] call (informational; the
  /// injected resolver is what actually performs RD-vs-torrent resolution).
  PlaybackMode get mode => _mode;

  QualitySession? _session;
  QualitySession? get session => _session;

  // Rolling throughput estimate (EWMA over reported bytes/sec samples).
  double _ewmaBytesPerSec = 0;
  bool _haveRate = false;

  DateTime _lastSwitch = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _shortfallSince; // when the current starvation streak began
  bool _switching = false;
  bool _disposed = false;

  // Live connection-type subscription so a WiFi->cellular transition mid-stream
  // re-evaluates and downshifts to the cellular cap.
  StreamSubscription<NetworkClass>? _netSub;
  NetworkClass _netClass = NetworkClass.unknown;

  // ---- required-bitrate table (bits/sec) -----------------------------------
  // Used when we can't derive bitrate from size/duration. These are typical
  // streaming bitrates per resolution tier; the source's *actual* bitrate can
  // be higher (BluRay REMUX) but this is a safe "can the pipe keep up" floor.
  static const Map<int, double> _resBitrate = {
    2160: 25e6, // ~25 Mbps
    1440: 16e6,
    1080: 8e6, // ~8 Mbps
    720: 4e6, // ~4 Mbps
    480: 1.5e6, // ~1.5 Mbps
  };

  /// Resolve + play the highest-quality candidate. Returns the live session.
  Future<QualitySession> startBest({
    required List<ProwlarrResult> candidates,
    required PlaybackMode mode,
    String? itemIdForServer,
  }) async {
    if (candidates.isEmpty) {
      throw StateError('AdaptiveQualityController.startBest: no candidates');
    }
    _candidates = List.unmodifiable(candidates);
    _mode = mode;

    // Capability ceiling: cap the FIRST pick by what this device can actually
    // decode smoothly (RAM + 32/64-bit + codec/HDR), independent of bandwidth.
    // Candidates are best-first, so the first one the device allows() is the
    // highest playable quality. Bandwidth downshift still applies on top.
    final startIndex = await _pickCapableStartIndex();
    final session = await _resolveIndex(startIndex, QualityEventKind.playing);
    _session = session;
    appLogger.i('AdaptiveQuality: playing #$startIndex '
        '${session.quality.label} via ${mode.name} -> ${session.playableUrl}');

    // Watch for the link changing under us (e.g. WiFi -> cellular). On a shift
    // to a more-constrained class, re-evaluate immediately and downshift to the
    // new network cap so a phone leaving WiFi doesn't keep pulling 1080p.
    _listenNetworkChanges();
    return session;
  }

  void _listenNetworkChanges() {
    _netSub ??= NetworkClassProbe.instance.changes.listen((cls) {
      if (_disposed) return;
      final prev = _netClass;
      _netClass = cls;
      appLogger.i('AdaptiveQuality: network changed $prev -> $cls');
      _enforceNetworkCap();
    });
  }

  /// If the CURRENT session's resolution exceeds the cap for the current
  /// network class, downshift to the best candidate that fits the new cap.
  void _enforceNetworkCap() {
    final session = _session;
    if (session == null || _switching || _disposed) return;
    final cap = NetworkClassProbe.capForClass(_netClass);
    if (cap == null) return; // unmetered/unknown -> no network cap
    final curRes = ReleaseQuality.parse(session.currentCandidate.title).resolution;
    if (curRes <= cap) return; // already within the cap
    // Find the best (earliest, since best-first) candidate at/under the cap.
    for (var i = 0; i < _candidates.length; i++) {
      final r = ReleaseQuality.parse(_candidates[i].title).resolution;
      if (r > 0 && r <= cap) {
        if (i != session.currentIndex) {
          unawaited(_downshift(i, 'network ${_netClass.name} cap ${cap}p'));
        }
        return;
      }
    }
  }

  /// Chooses the highest-quality candidate index the device can DECODE. Scans
  /// best-first and returns the first one [DeviceCapability.allows]. If nothing
  /// clears the ceiling (e.g. every result is 4K on a 1080p box), falls back to
  /// the lowest-resolution candidate as the least-bad option.
  Future<int> _pickCapableStartIndex() async {
    // First pick = min(device-can-decode, connection-type-cap). On cellular the
    // network cap (e.g. 720p) tightens the hardware ceiling so we start
    // conservative to stream smoothly and spare the data cap; bandwidth
    // measurement can still upshift/downshift from there.
    _netClass = await NetworkClassProbe.instance.probe();
    final baseCap = await DeviceCapability.probe();
    final cap = baseCap.cappedTo(NetworkClassProbe.capForClass(_netClass));
    for (var i = 0; i < _candidates.length; i++) {
      final q = ReleaseQuality.parse(_candidates[i].title);
      if (cap.allows(q)) {
        if (i > 0) {
          appLogger.i('AdaptiveQuality: capability ceiling (${cap.label}) '
              'skipped $i higher pick(s); starting at #$i ${q.label}');
        }
        return i;
      }
    }
    // No candidate is within the device ceiling — pick the lowest resolution.
    var lowest = 0;
    var lowestRes = ReleaseQuality.parse(_candidates[0].title).resolution;
    for (var i = 1; i < _candidates.length; i++) {
      final r = ReleaseQuality.parse(_candidates[i].title).resolution;
      // Prefer a strictly-lower known resolution; unknown (0) is a last resort.
      if (r > 0 && (lowestRes == 0 || r < lowestRes)) {
        lowest = i;
        lowestRes = r;
      }
    }
    appLogger.w('AdaptiveQuality: no candidate within device ceiling '
        '(${cap.label}); starting at lowest-res #$lowest');
    return lowest;
  }

  /// Feed a measured client/download rate (bytes/sec). Safe to call ~1/sec.
  void reportRate(int bytesPerSec) {
    if (_disposed || bytesPerSec < 0) return;
    // EWMA (alpha=0.3): smooths spikes but still reacts within a few samples.
    _ewmaBytesPerSec =
        _haveRate ? _ewmaBytesPerSec * 0.7 + bytesPerSec * 0.3 : bytesPerSec.toDouble();
    _haveRate = true;
    _evaluate(bufferSeconds: null);
  }

  /// Wire this as `TorrentStreamService.streamMagnet(onStatus: ...)` so the
  /// controller sees live buffer + download-rate telemetry for torrent mode.
  void onTorrentStatus(TorrentStreamStatus s) {
    if (_disposed) return;
    if (s.downloadRate > 0) reportRate(s.downloadRate);
    _evaluate(bufferSeconds: s.bufferSeconds);
  }

  // ---- decision core -------------------------------------------------------

  /// Required throughput (bytes/sec) to sustain [candidate] without stalling.
  /// Prefer a real estimate from size/duration; else fall back to the
  /// resolution tier table. bitrate = size_bytes * 8 / durationSeconds.
  double _requiredBytesPerSec(ProwlarrResult candidate) {
    final durSecs = _durationGuessSeconds(candidate);
    if (durSecs > 0 && candidate.size > 0) {
      final bitsPerSec = candidate.size * 8 / durSecs;
      return bitsPerSec / 8; // -> bytes/sec
    }
    final res = ReleaseQuality.parse(candidate.title).resolution;
    final bitsPerSec = _resBitrate[res] ?? _resBitrate[1080]!; // sane default
    return bitsPerSec / 8;
  }

  /// Duration is not carried on ProwlarrResult, so guess from size + tier: a
  /// TV episode (<3 GB) ~ 45 min, a movie ~ 120 min. Only used to derive a
  /// bitrate; wrong guesses just fall closer to the tier table.
  double _durationGuessSeconds(ProwlarrResult candidate) {
    final gb = candidate.size / (1024 * 1024 * 1024);
    if (gb <= 0) return 0;
    return gb < 3 ? 45 * 60 : 120 * 60;
  }

  /// Called on every telemetry sample. Decides whether to downshift.
  void _evaluate({double? bufferSeconds}) {
    final session = _session;
    if (session == null || _switching || _disposed) return;

    // Already at the lowest-resolution candidate? Nothing to drop to.
    final nextIdx = _nextLowerIndex(session.currentIndex);
    if (nextIdx == null) {
      _shortfallSince = null;
      return;
    }

    // Two independent starvation signals:
    //  (1) sustained throughput below what this source needs, and
    //  (2) torrent buffer draining below the floor.
    final need = _requiredBytesPerSec(session.currentCandidate);
    final rateStarved = _haveRate && _ewmaBytesPerSec < need;
    final bufferStarved =
        bufferSeconds != null && bufferSeconds < lowBufferSeconds;
    final starved = rateStarved || bufferStarved;

    if (!starved) {
      _shortfallSince = null; // recovered; reset the streak
      return;
    }

    // Start / continue the shortfall streak; require it to persist.
    final now = DateTime.now();
    _shortfallSince ??= now;
    if (now.difference(_shortfallSince!) < sustainWindow) return;

    // Debounce: honor the minimum dwell between switches.
    if (now.difference(_lastSwitch) < minDwell) return;

    final reason = rateStarved
        ? 'rate ${(_ewmaBytesPerSec / 1e6 * 8).toStringAsFixed(1)}Mbps < '
            'need ${(need / 1e6 * 8).toStringAsFixed(1)}Mbps'
        : 'buffer ${bufferSeconds!.toStringAsFixed(1)}s < ${lowBufferSeconds}s';
    unawaited(_downshift(nextIdx, reason));
  }

  /// Index of the next candidate whose resolution is strictly lower than the
  /// one at [fromIndex]. Candidates are best-first, so we scan forward.
  int? _nextLowerIndex(int fromIndex) {
    final curRes = ReleaseQuality.parse(_candidates[fromIndex].title).resolution;
    for (var i = fromIndex + 1; i < _candidates.length; i++) {
      final r = ReleaseQuality.parse(_candidates[i].title).resolution;
      // Treat unknown (0) as lower too — it's a smaller/riskier file to try.
      if (r < curRes || (curRes == 0 && i > fromIndex)) return i;
    }
    return null;
  }

  Future<void> _downshift(int index, String reason) async {
    if (_switching || _disposed) return;
    _switching = true;
    try {
      appLogger.i('AdaptiveQuality: DOWNSHIFT -> #$index ($reason)');
      final session = await _resolveIndex(index, QualityEventKind.downshifted,
          reason: reason);
      _session = session;
      _lastSwitch = DateTime.now();
      _shortfallSince = null;
      // Reset the rate estimate so the new source gets a fresh measurement
      // window and we don't immediately re-trigger on the old reading.
      _haveRate = false;
      _ewmaBytesPerSec = 0;
    } catch (e, st) {
      appLogger.e('AdaptiveQuality: downshift to #$index failed',
          error: e, stackTrace: st);
      // Skip this rung on next evaluation by advancing past it if possible.
      _lastSwitch = DateTime.now(); // still honor dwell so we don't hammer
    } finally {
      _switching = false;
    }
  }

  /// Resolve candidate [index] to a playable URL, emit `resolving` then the
  /// terminal [kind] event, and push the URL to [onSwap].
  Future<QualitySession> _resolveIndex(
    int index,
    QualityEventKind kind, {
    String? reason,
  }) async {
    final candidate = _candidates[index];
    _emit(QualityEvent(QualityEventKind.resolving,
        candidate: candidate, index: index, reason: reason));
    final url = await _resolveToUrl(candidate);
    if (url.isEmpty) {
      throw StateError('resolver returned empty URL for #$index');
    }
    final session = QualitySession(
      playableUrl: url,
      currentCandidate: candidate,
      currentIndex: index,
    );
    try {
      _onSwap?.call(url);
    } catch (e) {
      appLogger.w('AdaptiveQuality: onSwap threw: $e');
    }
    _emit(QualityEvent(kind,
        url: url, candidate: candidate, index: index, reason: reason));
    return session;
  }

  void _emit(QualityEvent e) {
    if (!_disposed && !_events.isClosed) _events.add(e);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _netSub?.cancel();
    _netSub = null;
    _events.close();
  }
}
