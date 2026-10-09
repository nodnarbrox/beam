import 'dart:async';
import 'dart:convert';

import 'beam_episode_identity.dart';

import 'package:plezy/utils/app_logger.dart';

import '../../database/app_database.dart';

/// A Beam library entry joined with its resume progress — the shape the Beam
/// home rows render.
class BeamLibraryEntry {
  BeamLibraryEntry({required this.item, this.progress});

  final BeamLibraryData item;
  final BeamProgressData? progress;

  String get contentKey => item.infoHash;
  String get infoHash => item.sourceInfoHash ?? item.infoHash;
  BeamEpisodeIdentity? get episode {
    final json = item.playbackMetadataJson;
    if (json == null) return null;
    try {
      return BeamEpisodeIdentity.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (e) {
      appLogger.w('Invalid stored Beam episode metadata: $e');
      return null;
    }
  }

  String get title => item.title;
  String get magnet => item.magnet;
  String? get posterUrl => item.posterUrl;
  String? get quality => item.quality;

  int get positionMs => progress?.positionMs ?? 0;
  int get durationMs => progress?.durationMs ?? 0;

  /// Fractional progress 0..1, or 0 when unknown.
  double get fraction {
    final d = durationMs;
    if (d <= 0) return 0;
    return (positionMs / d).clamp(0.0, 1.0);
  }

  /// A title is "in progress" (Continue Watching) when it's been started but
  /// isn't essentially finished. Mirrors the app's usual 2%–90% window.
  bool get isInProgress {
    final f = fraction;
    return f > 0.02 && f < 0.90;
  }
}

/// Local, server-independent store for titles streamed through Beam. Wraps the
/// Drift [AppDatabase] Beam tables so the UI/resolve code never touches Drift
/// directly. Episode keys identify show/season/episode across source changes;
/// movie keys retain their legacy torrent hash. Source hashes remain separate.
class BeamLibraryService {
  BeamLibraryService(this._db);

  final AppDatabase _db;

  int get _now => DateTime.now().millisecondsSinceEpoch;

  /// Record that a title was just played (insert or refresh + bump recency).
  Future<void> recordPlayed({
    required String infoHash,
    required String title,
    required String magnet,
    String? posterUrl,
    String? quality,
    int sizeBytes = 0,
    BeamEpisodeIdentity? episode,
  }) async {
    if (infoHash.isEmpty && episode == null) return;
    try {
      await _db.upsertBeamLibraryItem(
        infoHash: episode?.contentKey ?? infoHash,
        sourceInfoHash: infoHash,
        playbackMetadataJson: episode == null ? null : jsonEncode(episode.toJson()),
        title: title,
        magnet: magnet,
        posterUrl: posterUrl,
        quality: quality,
        sizeBytes: sizeBytes,
        nowMs: _now,
      );
    } catch (e) {
      appLogger.w('BeamLibraryService.recordPlayed failed (non-fatal): $e');
    }
  }

  /// Persist the current resume position for a title.
  Future<void> saveProgress({required String infoHash, required int positionMs, required int durationMs}) async {
    if (infoHash.isEmpty || positionMs <= 0) return;
    try {
      await _db.upsertBeamProgress(infoHash: infoHash, positionMs: positionMs, durationMs: durationMs, nowMs: _now);
    } catch (e) {
      appLogger.w('BeamLibraryService.saveProgress failed (non-fatal): $e');
    }
  }

  /// The resume position for a title as a [Duration], or null. Returns null
  /// when the title is essentially finished (>= ~95%) so replay starts over.
  Future<Duration?> resumeFor(String infoHash) async {
    if (infoHash.isEmpty) return null;
    try {
      final p = await _db.getBeamProgress(infoHash);
      if (p == null || p.positionMs <= 0) return null;
      if (p.durationMs > 0 && p.positionMs / p.durationMs >= 0.95) return null;
      return Duration(milliseconds: p.positionMs);
    } catch (e) {
      appLogger.w('BeamLibraryService.resumeFor failed: $e');
      return null;
    }
  }

  /// Most-recently-played titles first (drives the "Recently Played" row).
  Future<List<BeamLibraryEntry>> recentlyPlayed({int limit = 20}) async {
    try {
      final items = await _db.getBeamLibrary(limit: limit);
      if (items.isEmpty) return const [];
      final progress = {for (final p in await _db.getAllBeamProgress()) p.infoHash: p};
      return [for (final it in items) BeamLibraryEntry(item: it, progress: progress[it.infoHash])];
    } catch (e) {
      appLogger.w('BeamLibraryService.recentlyPlayed failed: $e');
      return const [];
    }
  }

  /// Titles with a mid-range resume position (drives "Continue Watching"),
  /// most-recently-played first.
  Future<List<BeamLibraryEntry>> continueWatching({int limit = 20}) async {
    final all = await recentlyPlayed(limit: 100);
    return all.where((e) => e.isInProgress).take(limit).toList();
  }

  Future<void> remove(String infoHash) => _db.deleteBeamLibraryItem(infoHash);
}
