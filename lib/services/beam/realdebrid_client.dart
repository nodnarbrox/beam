import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:plezy/utils/app_logger.dart';

import 'beam_config.dart';
import 'beam_cancellation.dart';
import 'episode_file_selector.dart';
import 'indexer_search.dart' show buildMagnet;
import 'prowlarr_client.dart';
import 'release_identity.dart';
import 'rd_request_coordinator.dart';

class RdException implements Exception {
  RdException(this.message, {this.code});
  final String message;
  final int? code;
  @override
  String toString() => 'RdException($code): $message';
}

/// A single unrestricted, directly-playable file from a Real-Debrid torrent.
class RdStream {
  RdStream({required this.filename, required this.downloadUrl, required this.filesize, required this.mimeType});

  final String filename;
  final String downloadUrl; // direct HTTPS, streamable by MPV
  final int filesize;
  final String? mimeType;

  bool get isVideo {
    final n = filename.toLowerCase();
    return n.endsWith('.mkv') ||
        n.endsWith('.mp4') ||
        n.endsWith('.avi') ||
        n.endsWith('.mov') ||
        n.endsWith('.m4v') ||
        n.endsWith('.ts') ||
        n.endsWith('.webm');
  }
}

/// Overall result of resolving a magnet through Real-Debrid.
class RdResolveResult {
  RdResolveResult({required this.torrentId, required this.streams});
  final String torrentId;
  final List<RdStream> streams;

  /// The largest video file — almost always the feature/episode the user wants.
  RdStream? get primaryVideo {
    final vids = streams.where((s) => s.isVideo).toList()..sort((a, b) => b.filesize.compareTo(a.filesize));
    return vids.isNotEmpty ? vids.first : null;
  }
}

/// Progress callback stages surfaced to the UI while resolving.
enum RdStage { addingMagnet, selectingFiles, waitingCache, downloading, unrestricting, ready }

typedef RdProgress = void Function(RdStage stage, {double? progress, String? note});

/// Client for the Real-Debrid REST API (v1.0). All traffic here is what we
/// actually want hidden behind the private proxy, so it accepts an injected
/// [http.Client] that the app builds with the proxy configured (see
/// beam_http.dart). The magnet never touches the local swarm — RD fetches it.
class RealDebridClient {
  RealDebridClient({
    required http.Client httpClient,
    Future<String> Function()? tokenProvider,
    DateTime Function()? now,
    RdRequestCoordinator? coordinator,
    this.cancellation,
    this.onRequestWait,
  }) : _http = httpClient,
       _tokenProvider = tokenProvider ?? BeamConfig.getRdToken,
       _now = now ?? DateTime.now,
       _coordinator = coordinator ?? RdRequestCoordinator.shared;

  static const String base = 'https://api.real-debrid.com/rest/1.0';
  final http.Client _http;
  final Future<String> Function() _tokenProvider;
  final DateTime Function() _now;
  final RdRequestCoordinator _coordinator;
  final BeamCancellation? cancellation;
  final BeamCancellation _closed = BeamCancellation();
  final void Function(String)? onRequestWait;

  /// Cancel queued requests before closing this client-owned transport.
  void close() {
    _closed.cancel();
    _http.close();
  }

  Future<http.Response> _request(
    String method,
    String path,
    Duration timeout, {
    Map<String, String>? body,
    BeamCancellation? cancellation,
  }) async {
    final requestCancellation = BeamCancellation();
    for (final signal in [_closed, this.cancellation, cancellation].whereType<BeamCancellation>()) {
      signal.check();
      unawaited(signal.whenCancelled.then((_) => requestCancellation.cancel()));
    }
    try {
      final headers = await requestCancellation.bind(_headers());
      requestCancellation.check();
      return await requestCancellation
          .bind(
            _coordinator.request(
              () async {
                requestCancellation.check();
                final response = await (switch (method) {
                  'POST' => _http.post(_u(path), headers: headers, body: body),
                  'DELETE' => _http.delete(_u(path), headers: headers),
                  _ => _http.get(_u(path), headers: headers),
                }).timeout(timeout);
                return response;
              },
              cancellation: requestCancellation,
              onWait: onRequestWait,
            ),
          )
          .then((response) {
            if (RdRequestCoordinator.isThrottled(response)) {
              throw RdException('Real-Debrid rate limit; waiting before further requests', code: 429);
            }
            return response;
          });
    } finally {
      requestCancellation.cancel();
    }
  }

  Future<Map<String, String>> _headers() async {
    final token = (await _tokenProvider()).trim();
    if (token.isEmpty) {
      throw RdException('Real-Debrid token not configured');
    }
    return {'Authorization': 'Bearer $token'};
  }

  Uri _u(String path) => Uri.parse('$base$path');

  /// GET /user — verifies the token and returns the account (username, premium
  /// expiry, points). Used by the settings "Test" button.
  Future<Map<String, dynamic>> user() async {
    final r = await _request('GET', '/user', const Duration(seconds: 12));
    if (r.statusCode != 200) {
      throw RdException('user ${r.statusCode}: ${r.body}', code: r.statusCode);
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Returns true when the token authenticates and the account is premium.
  Future<bool> isPremium() async {
    try {
      final u = await user();
      // 'type' == 'premium' and 'premium' (seconds remaining) > 0.
      final type = '${u['type']}';
      final prem = (u['premium'] is int) ? u['premium'] as int : 0;
      return type == 'premium' || prem > 0;
    } catch (e) {
      appLogger.w('RD isPremium check failed: $e');
      return false;
    }
  }

  /// POST /torrents/addMagnet — returns the new torrent id.
  Future<String> addMagnet(String magnet, {BeamCancellation? cancellation}) async {
    final r = await _request(
      'POST',
      '/torrents/addMagnet',
      const Duration(seconds: 20),
      body: {'magnet': magnet},
      cancellation: cancellation,
    );
    if (r.statusCode != 201 && r.statusCode != 200) {
      throw RdException('addMagnet ${r.statusCode}: ${r.body}', code: r.statusCode);
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final id = j['id']?.toString();
    if (id == null || id.isEmpty) {
      throw RdException('addMagnet returned no id');
    }
    return id;
  }

  /// POST /torrents/selectFiles/{id} — select all files (default) so RD begins
  /// caching/downloading. Idempotent-ish; RD 204s on success.
  Future<void> selectFiles(String id, {String files = 'all', BeamCancellation? cancellation}) async {
    final r = await _request(
      'POST',
      '/torrents/selectFiles/$id',
      const Duration(seconds: 20),
      body: {'files': files},
      cancellation: cancellation,
    );
    // 204 success; 202 already-processing is also fine.
    if (r.statusCode != 204 && r.statusCode != 202 && r.statusCode != 200) {
      throw RdException('selectFiles ${r.statusCode}: ${r.body}', code: r.statusCode);
    }
  }

  /// GET /torrents — the account's existing torrents (one page). Used to reuse
  /// an already-added torrent instead of piling up duplicates on every Play.
  Future<List<Map<String, dynamic>>> listTorrents({int limit = 100, BeamCancellation? cancellation}) async {
    final r = await _request('GET', '/torrents?limit=$limit', const Duration(seconds: 15), cancellation: cancellation);
    if (r.statusCode != 200) {
      throw RdException('torrents ${r.statusCode}: ${r.body}', code: r.statusCode);
    }
    final decoded = jsonDecode(r.body);
    if (decoded is! List) return const [];
    return decoded.whereType<Map<String, dynamic>>().toList();
  }

  /// Completed account downloads are evidence of an available RD copy. This
  /// read-only lookup never adds a magnet or treats active jobs as cached.
  Future<List<ProwlarrResult>> completedCandidates({
    required String title,
    int? year,
    int? season,
    int? episode,
    Iterable<String> aliases = const [],
  }) async {
    final candidates = <ProwlarrResult>[];
    final seen = <String>{};
    for (final torrent in await listTorrents()) {
      if (torrent['status'] != 'downloaded') continue;
      final hash = infoHashFromMagnet('magnet:?xt=urn:btih:${torrent['hash'] ?? ''}');
      if (hash == null || !RegExp(r'^[a-f0-9]{40}$').hasMatch(hash)) continue;
      final filename = '${torrent['filename'] ?? ''}';
      final candidate = ProwlarrResult(
        title: filename,
        indexer: 'Real-Debrid (downloaded)',
        size: (torrent['bytes'] as num?)?.toInt() ?? 0,
        seeders: 0,
        leechers: 0,
        // The native leg races this same candidate. Supply the usual trackers
        // even when UDP is available; a bare RD hash lacks tracker discovery.
        magnetUrl: buildMagnet(hash, filename),
        downloadUrl: null,
        infoUrl: null,
        categories: const [],
        publishDate: null,
      );
      final matches = season == null && episode == null
          ? ReleaseIdentity.matchesMovie(candidate, title: title, year: year, aliases: aliases)
          : season != null &&
                episode != null &&
                ReleaseIdentity.matchesEpisodeSource(
                  candidate,
                  show: title,
                  season: season,
                  episode: episode,
                  aliases: aliases,
                );
      if (matches && seen.add(hash)) candidates.add(candidate);
    }
    return candidates;
  }

  /// GET /torrents/info/{id}.
  Future<Map<String, dynamic>> info(String id, {BeamCancellation? cancellation}) async {
    final r = await _request('GET', '/torrents/info/$id', const Duration(seconds: 15), cancellation: cancellation);
    if (r.statusCode != 200) {
      throw RdException('info ${r.statusCode}: ${r.body}', code: r.statusCode);
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// POST /unrestrict/link — turn an RD hoster link into a direct download URL.
  Future<RdStream> unrestrict(String link, {BeamCancellation? cancellation}) async {
    final r = await _request(
      'POST',
      '/unrestrict/link',
      const Duration(seconds: 20),
      body: {'link': link},
      cancellation: cancellation,
    );
    if (r.statusCode != 200) {
      throw RdException('unrestrict ${r.statusCode}: ${r.body}', code: r.statusCode);
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return RdStream(
      filename: (j['filename'] ?? 'file').toString(),
      downloadUrl: (j['download'] ?? '').toString(),
      filesize: (j['filesize'] is int) ? j['filesize'] as int : 0,
      mimeType: j['mimeType']?.toString(),
    );
  }

  /// DELETE /torrents/delete/{id} — housekeeping so the RD "downloads" list
  /// doesn't fill with one-off streams.
  Future<void> deleteTorrent(String id, {BeamCancellation? cancellation}) async {
    try {
      await _request('DELETE', '/torrents/delete/$id', const Duration(seconds: 12), cancellation: cancellation);
    } catch (e) {
      appLogger.w('RD deleteTorrent($id) failed (non-fatal): $e');
    }
  }

  /// Wait for RD's playable link. Uncached torrents may keep downloading while
  /// progress advances; [timeout] bounds inactivity and [maxWait] bounds the
  /// whole poll. A timeout leaves the job available for a later playback.
  Future<RdResolveResult> resolveMagnet(
    String magnet, {
    RdProgress? onProgress,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    BeamCancellation? cancellation,
    bool cachedOnly = false,
    Duration timeout = const Duration(seconds: 120),
    Duration maxWait = const Duration(minutes: 30),
    Duration pollEvery = const Duration(seconds: 2),
  }) async {
    cancellation?.check();
    onProgress?.call(RdStage.addingMagnet);
    final id = await _wait(addMagnet(magnet, cancellation: cancellation), cancellation);
    cancellation?.check();
    try {
      return await _pollTorrent(
        id,
        owned: true,
        cachedOnly: cachedOnly,
        onProgress: onProgress,
        season: season,
        episode: episode,
        storyConstraint: storyConstraint,
        cancellation: cancellation,
        timeout: timeout,
        maxWait: maxWait,
        pollEvery: pollEvery,
      );
    } on EpisodeSelectionException {
      // This attempt created the job, but its files cannot prove the catalog
      // story. Do not leave a rejected job waiting for file selection. Other
      // failures (including slow valid downloads) retain their existing policy.
      if (storyConstraint != null) await deleteTorrent(id, cancellation: cancellation);
      rethrow;
    }
  }

  static Future<T> _wait<T>(Future<T> operation, BeamCancellation? cancellation) =>
      cancellation?.bind(operation) ?? operation;

  Future<RdResolveResult> _finish(
    String id,
    Map<String, dynamic> data,
    RdProgress? onProgress, {
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    BeamCancellation? cancellation,
  }) async {
    onProgress?.call(RdStage.unrestricting);
    cancellation?.check();
    var links = (data['links'] is List) ? (data['links'] as List).map((e) => '$e').toList() : <String>[];
    if (links.isEmpty) {
      throw RdException('downloaded torrent has no links');
    }
    if (season != null || episode != null) {
      final target = _episodeFile(data, season, episode, storyConstraint);
      final selected = _files(data).where((f) => f['selected'] == 1).toList();
      final index = selected.indexWhere((f) => f['id'] == target.id);
      if (index < 0 || selected.length != links.length) {
        throw const EpisodeSelectionException('Requested episode is not available in cached links.');
      }
      links = [links[index]];
    }
    final streams = <RdStream>[];
    for (final link in links) {
      try {
        cancellation?.check();
        final stream = await _wait(unrestrict(link, cancellation: cancellation), cancellation);
        cancellation?.check();
        if (season != null || episode != null) {
          EpisodeFileSelector.select(
            [EpisodeFile(id: 0, path: stream.filename, size: stream.filesize)],
            season: season,
            episode: episode,
            storyConstraint: storyConstraint,
          );
        }
        if (stream.downloadUrl.isEmpty) throw RdException('Unrestricted stream has no download URL');
        streams.add(stream);
      } on BeamCancelled {
        rethrow;
      } catch (e) {
        // Throttling applies to the account, not this individual link.
        if (e is RdException && e.code == 429) rethrow;
        appLogger.w('unrestrict failed for one link: $e');
      }
    }
    if (streams.isEmpty) {
      throw RdException('could not unrestrict any link');
    }
    onProgress?.call(RdStage.ready);
    return RdResolveResult(torrentId: id, streams: streams);
  }

  static List<Map<String, dynamic>> _files(Map<String, dynamic> data) =>
      (data['files'] as List? ?? const []).whereType<Map<String, dynamic>>().toList();

  static EpisodeFile _episodeFile(
    Map<String, dynamic> data,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
  ) => EpisodeFileSelector.select(
    _files(
      data,
    ).map((f) => EpisodeFile(id: f['id'] as int, path: '${f['path']}', size: (f['bytes'] as num?)?.toInt() ?? 0)),
    season: season,
    episode: episode,
    storyConstraint: storyConstraint,
  );

  static String _selection(
    Map<String, dynamic> data,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
  ) => season == null && episode == null ? 'all' : '${_episodeFile(data, season, episode, storyConstraint).id}';

  /// Reuse existing completed or active jobs. Lookup failures may add fresh;
  /// failures after adopting an active job propagate without creating duplicates.
  Future<RdResolveResult> resolveMagnetSmart(
    String magnet, {
    String? infoHash,
    RdProgress? onProgress,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    BeamCancellation? cancellation,
    Duration timeout = const Duration(seconds: 120),
    Duration maxWait = const Duration(minutes: 30),
    Duration pollEvery = const Duration(seconds: 2),
  }) async {
    cancellation?.check();
    Map<String, dynamic>? match;
    if (infoHash != null && infoHash.isNotEmpty) {
      try {
        final existing = await _wait(listTorrents(cancellation: cancellation), cancellation);
        for (final torrent in existing) {
          if ('${torrent['hash']}'.toLowerCase() == infoHash.toLowerCase()) {
            if (match == null || torrent['status'] == 'downloaded') match = torrent;
            if (torrent['status'] == 'downloaded') break;
          }
        }
      } on BeamCancelled {
        rethrow;
      } catch (e) {
        // A throttled lookup is not a cache miss. Adding now only amplifies
        // the same account-level limit across concurrent source races.
        if (e is RdException && e.code == 429) rethrow;
        appLogger.w('RD dedupe lookup failed (continuing with fresh add): $e');
      }
    }
    cancellation?.check();
    if (match != null) {
      final id = '${match['id']}';
      final status = '${match['status']}';
      if (status == 'downloaded') {
        // Cached links may have expired or contain only a different episode.
        // Preserve that user's job while requesting our own file selection.
        Map<String, dynamic>? cachedData;
        try {
          final data = await _wait(info(id, cancellation: cancellation), cancellation);
          cachedData = data;
          cancellation?.check();
          if ('${data['status']}' == 'downloaded') {
            return await _finish(
              id,
              data,
              onProgress,
              season: season,
              episode: episode,
              storyConstraint: storyConstraint,
              cancellation: cancellation,
            );
          }
        } on BeamCancelled {
          rethrow;
        } catch (e) {
          if (e is RdException && e.code == 429) rethrow;
          if (e is EpisodeSelectionException && storyConstraint != null && cachedData != null) {
            // A fresh copy of the same hash has the same filenames. If none
            // proves this story, adding it again cannot help. If the correct
            // file exists but was not selected, allow the usual fresh selection.
            _episodeFile(cachedData, season, episode, storyConstraint);
          }
          appLogger.w('RD cached job cannot supply requested stream: $e');
        }
      } else if (!_terminalStatus(status)) {
        try {
          return await _pollTorrent(
            id,
            owned: false,
            onProgress: onProgress,
            season: season,
            episode: episode,
            storyConstraint: storyConstraint,
            cancellation: cancellation,
            timeout: timeout,
            maxWait: maxWait,
            pollEvery: pollEvery,
          );
        } on _RdDifferentSelection {
          // This job is fetching another episode. Leave it alone and select
          // our requested episode in a fresh job without waiting for that file.
          appLogger.i('RD active job $id is downloading a different episode');
        }
      }
    }
    cancellation?.check();
    return resolveMagnet(
      magnet,
      season: season,
      episode: episode,
      storyConstraint: storyConstraint,
      cancellation: cancellation,
      onProgress: onProgress,
      timeout: timeout,
      maxWait: maxWait,
      pollEvery: pollEvery,
    );
  }

  static bool _terminalStatus(String status) =>
      status == 'magnet_error' || status == 'error' || status == 'virus' || status == 'dead';

  Future<RdResolveResult> _pollTorrent(
    String id, {
    required bool owned,
    bool cachedOnly = false,
    RdProgress? onProgress,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    BeamCancellation? cancellation,
    required Duration timeout,
    required Duration maxWait,
    required Duration pollEvery,
  }) async {
    final hardDeadline = _now().add(maxWait);
    var idleDeadline = _now().add(timeout);
    var selected = false;
    var highestProgress = 0.0;
    var furthestStage = 0;
    Map<String, dynamic>? last;
    while (_now().isBefore(hardDeadline) && _now().isBefore(idleDeadline)) {
      cancellation?.check();
      final remainingIdle = idleDeadline.difference(_now());
      final remainingTotal = hardDeadline.difference(_now());
      final requestBudget = remainingIdle < remainingTotal ? remainingIdle : remainingTotal;
      Map<String, dynamic> data;
      final pollCancellation = BeamCancellation();
      if (cancellation != null) unawaited(cancellation.whenCancelled.then((_) => pollCancellation.cancel()));
      try {
        data = await _wait(info(id, cancellation: pollCancellation).timeout(requestBudget), cancellation);
      } on TimeoutException {
        break;
      } finally {
        // A queue wait that exhausts the polling budget must not dispatch later.
        pollCancellation.cancel();
      }
      cancellation?.check();
      last = data;
      final status = '${data['status']}';
      final rawProgress = (data['progress'] as num?)?.toDouble() ?? 0.0;
      final progress = rawProgress.isFinite ? rawProgress.clamp(0.0, 100.0) : 0.0;
      final processingStage = switch (status) {
        'downloading' => 1,
        'compressing' => 2,
        'uploading' => 3,
        _ => 0,
      };
      if (processingStage > furthestStage) {
        furthestStage = processingStage;
        highestProgress = 0.0;
      }
      // A later processing phase may report its own percentage. Only rising
      // progress in the furthest phase extends the wait; revisiting an earlier
      // phase or repeating statuses cannot continually renew the budget.
      if (processingStage > 0 && processingStage == furthestStage && progress > highestProgress) {
        highestProgress = progress;
        idleDeadline = _now().add(timeout);
      }
      if (!owned && (season != null || episode != null) && !_terminalStatus(status)) {
        final selectedFiles = _files(data).where((file) => file['selected'] == 1);
        if (selectedFiles.isNotEmpty) {
          final target = _episodeFile(data, season, episode, storyConstraint);
          if (!selectedFiles.any((file) => file['id'] == target.id)) throw const _RdDifferentSelection();
        }
      }
      switch (status) {
        case 'waiting_files_selection':
          if (!selected) {
            cancellation?.check();
            onProgress?.call(RdStage.selectingFiles);
            await _wait(
              selectFiles(id, cancellation: cancellation, files: _selection(data, season, episode, storyConstraint)),
              cancellation,
            );
            cancellation?.check();
            selected = true;
            // Successful selection is a single forward step, never a reset
            // based on recurring status changes or fluctuating percentages.
            idleDeadline = _now().add(timeout);
          }
          break;
        case 'magnet_conversion':
        case 'queued':
          onProgress?.call(RdStage.waitingCache);
          break;
        case 'downloading':
        case 'compressing':
        case 'uploading':
          if (cachedOnly) {
            cancellation?.check();
            if (owned) await _wait(deleteTorrent(id, cancellation: cancellation), cancellation);
            throw RdException('Real-Debrid release is not instantly cached', code: 408);
          }
          onProgress?.call(RdStage.downloading, progress: progress / 100.0, note: status);
          break;
        case 'downloaded':
          return _finish(
            id,
            data,
            onProgress,
            season: season,
            episode: episode,
            storyConstraint: storyConstraint,
            cancellation: cancellation,
          );
        case 'magnet_error':
        case 'error':
        case 'virus':
        case 'dead':
          if (owned) await _wait(deleteTorrent(id, cancellation: cancellation), cancellation);
          throw RdException('Real-Debrid status: $status');
        default:
          onProgress?.call(RdStage.waitingCache, note: status);
      }
      final remaining = [
        idleDeadline.difference(_now()),
        hardDeadline.difference(_now()),
        pollEvery,
      ].reduce((a, b) => a < b ? a : b);
      if (remaining.isNegative) break;
      await _wait(Future<void>.delayed(remaining), cancellation);
    }
    cancellation?.check();
    final reason = !_now().isBefore(hardDeadline) ? 'download wait limit reached' : 'download stopped progressing';
    throw RdException('Real-Debrid $reason (status=${last?['status']}); job kept for later playback', code: 408);
  }
}

class _RdDifferentSelection implements Exception {
  const _RdDifferentSelection();
}
