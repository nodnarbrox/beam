part of '../../video_player_screen.dart';

extension _VideoPlayerErrorMethods on VideoPlayerScreenState {
  String _safePlaybackErrorMessage(Object error) {
    final raw = error.toString();
    final redacted = LogRedactionManager.redact(raw);
    if (raw.contains('No client registered')) {
      return t.messages.errorLoading(error: 'Server is unavailable for the active profile');
    }
    return t.messages.errorLoading(error: redacted);
  }

  void _onPlayerError(PlayerError err) {
    appLogger.e('[Player ERROR] ${err.message}');
    if (!mounted || _isExiting.value) return;
    if (widget.directVideoUrl != null && !widget.isLive) widget.onDirectPlaybackFailed?.call();

    // Fatal, unrecoverable server-side (HTTP 500 — usually a bandwidth/transcode
    // limit rejecting the session, which is common streaming a home server
    // remotely over a VPN). Rather than dead-end on "ask the owner", silently
    // fall back to Beam and play the SAME title from a torrent/RD source. Only a
    // Plex/Jellyfin library stream can hit this (a Beam direct URL never does),
    // so the directVideoUrl guard also prevents a fallback loop. The owner-limit
    // dialog is the last resort if Beam finds nothing.
    // A transcode stall is its own cause; don't let a stale _sawServer500 flag
    // from earlier in the session divert it into the 500-specific branch.
    // (Both branches end in Beam anyway, but this keeps the path predictable:
    // a stall does one low-transcode LIBRARY retry, then RD/magnet.)
    if (err.cause != PlayerError.transcodeStall && (err.cause == PlayerError.serverHttp500 || _sawServer500)) {
      // A library title the user ALREADY HAS must not be re-hunted from
      // torrents just because the server refused this one session. The usual
      // cause on TV is the VPN hiding the LAN, so playback rides the
      // bandwidth-capped Plex relay, which 500s an original-quality stream
      // (seen on the ONN with "How the Grinch Stole Christmas"). Retry ONCE at
      // a low transcode the relay can carry; only a second 500 falls through
      // to the Beam fallback below.
      if (!_retried500WithTranscode &&
          !widget.isLive &&
          widget.directVideoUrl == null &&
          _selectedQualityPreset != TranscodeQualityPreset.p480_1_5mbps) {
        _retried500WithTranscode = true;
        _sawServer500 = false;
        appLogger.w(
          'Server HTTP 500 — retrying "${_currentMetadata.displayTitle}" '
          'at 480p/1.5Mbps transcode before any Beam fallback',
        );
        unawaited(() async {
          final outcome = await _switchPlaybackSource(newPreset: TranscodeQualityPreset.p480_1_5mbps);
          if (!mounted) return;
          if (outcome != PlaybackSourceChangeOutcome.applied && outcome != PlaybackSourceChangeOutcome.superseded) {
            appLogger.w('Transcode retry not applied ($outcome) — Beam fallback');
            _hasFatalPlaybackError = true;
            _progressTracker?.stopTracking();
            unawaited(_beamFallbackForCurrentTitle(onExhausted: _showServerLimitDialog));
          }
        }());
        return;
      }
      _hasFatalPlaybackError = true;
      _progressTracker?.stopTracking();
      if (!widget.isLive && widget.directVideoUrl == null && _currentMetadata.displayTitle.trim().isNotEmpty) {
        appLogger.w(
          'Server HTTP 500 — attempting Beam fallback for '
          '"${_currentMetadata.displayTitle}"',
        );
        unawaited(_beamFallbackForCurrentTitle(onExhausted: _showServerLimitDialog));
      } else {
        unawaited(_showServerLimitDialog());
      }
      return;
    }

    // Live TV: retry with progressively degraded stream settings
    // (mirrors Plex web client fallback chain).
    if (widget.isLive) {
      // The bounded retry operation owns errors raised while applying/opening
      // its replacement stream. Do not let the same error close the route.
      if (_live.retrying) return;
      if (_live.fallbackLevel < 2) {
        _live.fallbackLevel++;
        _live.retrying = true;
        appLogger.w('Live stream failed, retrying with fallback level ${_live.fallbackLevel}');
        unawaited(_retryLiveStream());
        return;
      }
      if (_live.retryFailed) {
        showGlobalErrorSnackBar(t.messages.liveStreamInterrupted);
        return;
      }
    }

    _hasFatalPlaybackError = true;
    _progressTracker?.stopTracking();

    // A title the user ALREADY OWNS gets one clean retry from their own server
    // before Beam is even considered. Torrenting something that is sitting in
    // the library is never the right answer to a first, possibly transient
    // failure (observed: mpv's ytdl hook failing on a plain Plex .mp4 sent
    // "12 Deadly Days" — an owned episode — straight to a torrent).
    if (!widget.isLive &&
        widget.directVideoUrl == null &&
        !_retriedLibrarySourceAfterError &&
        _currentMetadata.serverId != null) {
      _retriedLibrarySourceAfterError = true;
      appLogger.w(
        'Playback failed — retrying the LIBRARY source once for '
        '"${_currentMetadata.displayTitle}" before any Beam fallback',
      );
      _hasFatalPlaybackError = false;
      unawaited(() async {
        final outcome = await _switchPlaybackSource(newPreset: TranscodeQualityPreset.p480_1_5mbps);
        if (!mounted) return;
        if (outcome != PlaybackSourceChangeOutcome.applied && outcome != PlaybackSourceChangeOutcome.superseded) {
          appLogger.w('Library retry not applied ($outcome) — Beam fallback');
          _hasFatalPlaybackError = true;
          _progressTracker?.stopTracking();
          unawaited(_beamFallbackForCurrentTitle());
        }
      }());
      return;
    }

    // Silent Beam fallback: the title wouldn't play from the user's server
    // (unreachable, missing file, transcode failure). Instead of dead-ending on
    // an error snackbar, quietly find the best streamable source for the same
    // title and play it — the user never sees the torrent list. Skipped when the
    // stream is ALREADY a Beam direct URL (that would loop) or it's Live TV.
    if (!widget.isLive && widget.directVideoUrl == null && _currentMetadata.displayTitle.trim().isNotEmpty) {
      appLogger.w(
        'Playback failed — attempting Beam fallback for '
        '"${_currentMetadata.displayTitle}"',
      );
      unawaited(_beamFallbackForCurrentTitle());
      return;
    }

    showGlobalErrorSnackBar(
      widget.directVideoUrl != null
          ? 'This video could not be played. Try again. Details are saved in Settings > Error inbox.'
          : _redactPlayerError(_lastLogError ?? err.message),
    );
    unawaited(_handleBackButton());
  }

  /// Swaps this failed player route for a Beam auto-play of the same title.
  /// pushReplacement so Back doesn't return to the dead player. [onExhausted]
  /// runs when Beam finds nothing (defaults to snackbar + back); the HTTP-500
  /// path passes the owner-limit dialog instead.
  Future<void> _beamFallbackForCurrentTitle({VoidCallback? onExhausted}) async {
    if (!mounted) return;
    final mi = _currentMetadata;
    // For a TV episode, Beam must search "Show SxxExx", not the show name alone.
    // displayTitle already returns the show (grandparentTitle) for episodes;
    // parentIndex = season number, index = episode number.
    final isEp = mi.isEpisode && mi.parentIndex != null && mi.index != null;
    var cancelled = false;
    final ok = await BeamFallback.playByTitle(
      context,
      title: mi.displayTitle,
      year: mi.year,
      kind: mi.kind,
      metadata: mi,
      beamEpisode: isEp ? _beamIdentityForEpisode(mi) : null,
      onCancelled: () => cancelled = true,
      season: isEp ? mi.parentIndex : null,
      episode: isEp ? mi.index : null,
      replace: true,
      // This player already retried its library source. Reopening it would
      // reset that retry guard and loop instead of reaching RD/torrent sources.
      skipLibraryLookup: true,
    );
    if (!ok && !cancelled && mounted) {
      // Nothing streamable found — fall back to the caller's exhausted handler.
      if (onExhausted != null) {
        onExhausted();
      } else {
        showGlobalErrorSnackBar(_redactPlayerError(_lastLogError ?? 'Playback failed'));
        unawaited(_handleBackButton());
      }
    }
  }

  void _onPlayerLog(PlayerLog log) {
    if (!_sawServer500 && VideoPlayerScreenState._server500Pattern.hasMatch(log.text)) {
      _sawServer500 = true;
    }

    // Transcode segment-stall detection. A dead Plex transcode session 404s
    // its HLS segments forever without ever raising a PlayerError, so the
    // player hangs on "loading". Count consecutive failures; a successful
    // segment open clears the counter. Once we cross the threshold within the
    // window, synthesize a fatal error so playback has somewhere to go — the
    // RD + magnet instant-play bandaid — exactly like any other failure.
    _detectSegmentStall(log.text);

    if (log.level == PlayerLogLevel.error || log.level == PlayerLogLevel.fatal) {
      appLogger.e('[Player LOG ERROR] [${log.prefix}] ${log.text}');
      _lastLogError = _redactPlayerError(log.text.trim());
    }
  }

  /// Watches ffmpeg/HLS log lines for a run of segment failures that indicates
  /// the transcode session has died. On trip, routes into the standard
  /// library-retry -> Beam (RD + magnet race) fallback via [_onPlayerError].
  void _detectSegmentStall(String text) {
    if (_hasFatalPlaybackError || _sawSegmentStall) return;
    // A Beam direct URL isn't an HLS transcode and must never re-enter Beam.
    if (widget.directVideoUrl != null || widget.isLive) return;

    if (VideoPlayerScreenState._segmentOpenPattern.hasMatch(text)) {
      // Session is producing segments again — not stalled.
      _consecutiveSegmentFailures = 0;
      _firstSegmentFailureAt = null;
      return;
    }
    if (!VideoPlayerScreenState._segmentFailPattern.hasMatch(text)) return;

    final now = DateTime.now();
    _firstSegmentFailureAt ??= now;
    _consecutiveSegmentFailures++;

    final spanned = now.difference(_firstSegmentFailureAt!);
    if (_consecutiveSegmentFailures >= VideoPlayerScreenState._segmentStallFailureThreshold &&
        spanned >= VideoPlayerScreenState._segmentStallWindow) {
      _sawSegmentStall = true;
      appLogger.w(
        'Transcode segment stall: $_consecutiveSegmentFailures '
        'segment failures over ${spanned.inSeconds}s for '
        '"${_currentMetadata.displayTitle}" — treating as fatal, routing to '
        'library retry / Beam fallback',
      );
      if (!mounted || _isExiting.value) return;
      // Feed the existing failure pipeline. This cause is NOT serverHttp500,
      // so it skips the 500 branch and takes the generic library-retry-then-
      // Beam branch (owned titles retry once first; a Beam direct URL is
      // already excluded above), so the RD/magnet bandaid always fires.
      _onPlayerError(
        const PlayerError('Transcode session stalled (segments unavailable)', cause: PlayerError.transcodeStall),
      );
    }
  }

  String _redactPlayerError(String message) =>
      LogRedactionManager.redact(message).replaceAll(RegExp(r'https?://\S+'), '[stream]');

  Future<void> _showServerLimitDialog() async {
    if (!mounted) return;
    await showServerLimitDialog(context);
    if (mounted) unawaited(_handleBackButton());
  }

  /// Handle notification when native player switched from ExoPlayer to MPV
  Future<void> _onBackendSwitched() async {
    _playerBackendLabel = 'mpv';
    _recordLifecycleState('backend_switched', action: 'mpv_fallback');

    _toastController.show(
      Symbols.swap_horiz_rounded,
      t.messages.switchingToCompatiblePlayer,
      duration: const Duration(seconds: 2),
    );

    await _trackManager?.onBackendSwitched();
  }
}
