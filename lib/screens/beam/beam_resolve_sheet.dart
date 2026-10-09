import 'dart:async';

import 'package:flutter/material.dart';

import 'package:plezy/utils/app_logger.dart';

import '../../services/beam/beam_config.dart';
import '../../services/beam/beam_cancellation.dart';
import '../../services/beam/beam_play_service.dart';
import '../../services/beam/beam_playback_duration.dart';
import '../../services/beam/episode_file_selector.dart';
import '../../services/beam/prowlarr_client.dart';
import '../../services/beam/torrent_stream_service.dart' show kTorrentPathEnabled;

/// Legacy resolution-mode selector. The sheet no longer branches on this (it
/// races both paths), but [beam_fallback.dart] still uses it for its own
/// single-path resolve, so the enum stays here where it was exported from.
enum BeamResolveMode { realDebrid, torrent }

/// Called once a race has produced a playable stream. [infoHash] is the stable
/// Beam library/resume key (may be null if the source had no magnet).
typedef BeamOnPlay = void Function(String url, String title, {String? infoHash, String? magnet});

/// A modal bottom sheet that "flex-seals" a chosen [ProwlarrResult] into a
/// playable stream by RACING Real-Debrid and the (privacy-gated) instant
/// torrent stream at the same time — whichever is ready first wins and plays.
///
/// This never weakens the fail-closed torrent rule: the torrent leg self-gates
/// inside [TorrentStreamService], so when no VPN/proxy is verified it loses
/// instantly and the race is Real-Debrid-only. Real-Debrid is remote/safe and
/// always races when a token is configured.
class BeamResolveSheet extends StatefulWidget {
  const BeamResolveSheet({
    super.key,
    required this.result,
    this.onPlay,
    this.onPlayResolved,
    this.season,
    this.episode,
    this.storyConstraint,
    this.playbackDuration,
    this.playService,
  }) : assert(onPlay != null || onPlayResolved != null);

  final ProwlarrResult result;
  final int? season;
  final int? episode;
  final EpisodeStoryConstraint? storyConstraint;
  final BeamPlaybackDuration? playbackDuration;
  final BeamPlayService? playService;

  /// Called once a directly-playable URL is available. The sheet closes itself
  /// first (via Navigator.pop) so the caller can push the player cleanly.
  final BeamOnPlay? onPlay;

  /// Transfers ownership to a player. Return true only after its route is
  /// installed; the player must commit on first frame and cancel on close.
  final Future<bool> Function(BeamPlayResult playback)? onPlayResolved;

  /// Opens the sheet. Returns when it is dismissed.
  static Future<void> show(
    BuildContext context, {
    required ProwlarrResult result,
    BeamOnPlay? onPlay,
    Future<bool> Function(BeamPlayResult playback)? onPlayResolved,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    BeamPlaybackDuration? playbackDuration,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => BeamResolveSheet(
        result: result,
        onPlay: onPlay,
        onPlayResolved: onPlayResolved,
        season: season,
        episode: episode,
        storyConstraint: storyConstraint,
        playbackDuration: playbackDuration,
      ),
    );
  }

  @override
  State<BeamResolveSheet> createState() => _BeamResolveSheetState();
}

class _BeamResolveSheetState extends State<BeamResolveSheet> {
  String _status = 'Preparing…';
  double? _progress; // null = indeterminate
  String? _error;
  bool _done = false;
  bool _cancelled = false;
  BeamCancellation? _attempt;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _cancelled = true;
    if (!_done) _attempt?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _attempt?.cancel();
    final cancellation = BeamCancellation();
    _attempt = cancellation;
    setState(() {
      _error = null;
      _progress = null;
      _status = 'Finding the fastest way to play…';
    });
    try {
      // Ensure prefs are loaded before any BeamConfig read. Entering the sheet
      // from the library-card replay path doesn't otherwise trigger init, and
      // BeamConfig.torrentPlayEnabled reads SharedPreferences synchronously.
      await BeamConfig.init();
      if (!mounted || _cancelled || !identical(_attempt, cancellation)) return;
      final rdReady = await BeamConfig.rdConfigured;
      if (!mounted || _cancelled || !identical(_attempt, cancellation)) return;
      final torrentOn = kTorrentPathEnabled && BeamConfig.torrentPlayEnabled;

      final res = await (widget.playService ?? BeamPlayService.instance).race(
        widget.result,
        rdEnabled: rdReady,
        torrentEnabled: torrentOn,
        season: widget.season,
        episode: widget.episode,
        storyConstraint: widget.storyConstraint,
        playbackDuration: widget.playbackDuration,
        cancellation: cancellation,
        deferLoserCancellation: widget.onPlayResolved != null,
        onProgress: (status, {progress}) => _set(status, progress: progress),
      );
      if (!mounted || _cancelled || !identical(_attempt, cancellation)) {
        res.cancel();
        return;
      }
      // The stable library/resume key is the source's info-hash (null when the
      // source had no magnet, e.g. a .torrent-only Real-Debrid grab).
      _play(res);
    } catch (e) {
      appLogger.w('Beam race failed: $e');
      if (!mounted || _cancelled || !identical(_attempt, cancellation)) return;
      _fail(_friendlyError('$e'));
    }
  }

  String _friendlyError(String raw) {
    // Turn the fail-closed torrent refusal + RD misconfig into one clear line.
    if (raw.contains('No playable path') || raw.contains('no magnet')) {
      return 'This source can\'t be played. Try another source or set up Real-Debrid.';
    }
    return raw;
  }

  void _set(String status, {double? progress}) {
    if (!mounted || _cancelled) return;
    setState(() {
      _status = status;
      _progress = progress;
    });
  }

  void _fail(String message) {
    if (!mounted || _cancelled) return;
    setState(() {
      _error = message;
      _progress = null;
    });
  }

  void _play(BeamPlayResult playback) {
    if (!mounted || _cancelled || _done) {
      playback.cancel();
      return;
    }
    _done = true;
    Navigator.of(context).pop();
    final onResolved = widget.onPlayResolved;
    if (onResolved != null) {
      unawaited(() async {
        try {
          if (!await onResolved(playback)) playback.cancel();
        } catch (error, stack) {
          playback.cancel();
          appLogger.e('Beam player handoff failed', error: error, stackTrace: stack);
        }
      }());
    } else {
      try {
        widget.onPlay!(playback.url, widget.result.title, infoHash: widget.result.infoHash, magnet: playback.magnet);
      } catch (_) {
        playback.cancel();
        rethrow;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && !_done) {
          _cancelled = true;
          _attempt?.cancel();
        }
      },
      child: Padding(
        padding: EdgeInsets.only(left: 24, right: 24, top: 20, bottom: MediaQuery.viewInsetsOf(context).bottom + 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Icon(Icons.bolt, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Starting playback', style: theme.textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.result.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            if (_error == null) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 16),
              Text(_status, style: theme.textTheme.bodyMedium),
            ] else
              _buildError(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildError(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent),
            const SizedBox(width: 8),
            Expanded(child: Text(_error!, style: theme.textTheme.bodyMedium)),
          ],
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          autofocus: true,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
          onPressed: _start,
        ),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
      ],
    );
  }
}
