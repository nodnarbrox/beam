import 'dart:async';

import '../../utils/app_logger.dart';

import 'beam_http.dart';
import 'beam_cancellation.dart';
import 'beam_buffer_wait.dart';
import 'beam_playback_duration.dart';
import 'episode_file_selector.dart';
import 'prowlarr_client.dart';
import 'realdebrid_client.dart';
import 'torrent_stream_service.dart';

/// Which leg of the race produced the playable stream.
enum BeamPlayWinner { realDebrid, torrent }

/// The outcome of a race: a directly-playable URL plus which path won and the
/// magnet that was used (so the caller can stop the torrent when the player
/// closes).
class BeamPlayResult {
  BeamPlayResult({
    required this.url,
    required this.winner,
    required this.magnet,
    this.rdTorrentId,
    this.selectedFilename,
    this.onPlaybackStarted,
    this.onCancelled,
  });

  final String url;
  final BeamPlayWinner winner;
  final String magnet;
  final String? rdTorrentId;
  final String? selectedFilename;
  String? episodePlaybackNotice(int? season) {
    if (season == null || selectedFilename == null) return null;
    final episodes = EpisodeFileSelector.episodesFor(selectedFilename!, season: season);
    if (episodes == null || episodes.length < 2) return null;
    return 'Combined episode file: S$season E${episodes.join(', E')}. These episodes play together.';
  }

  final void Function()? onPlaybackStarted;
  final void Function()? onCancelled;

  /// Commit only after the player reports its first frame. Safe to repeat.
  void commitPlayback() => onPlaybackStarted?.call();

  /// Release both paths when playback fails, is abandoned, or closes.
  void cancel() => onCancelled?.call();
}

/// Progress surfaced to the UI during a race. Each active transport retains
/// its own status; an update from one cannot hide the other transport.
typedef BeamPlayProgress = void Function(String status, {double? progress});

/// Runs Real-Debrid and the (privacy-gated) instant torrent stream AT THE SAME
/// TIME and plays whichever is ready first — the "flex-seal" play path.
///
/// SAFETY: the torrent leg goes through [TorrentStreamService.streamMagnet],
/// which self-gates via `_assertTorrentAllowed()` and THROWS before touching
/// the network unless a VPN/proxy is verified. So when privacy isn't satisfied
/// the torrent leg loses instantly (by throwing) and the race is effectively
/// Real-Debrid-only. This never weakens the fail-closed rule: it is impossible
/// to download a torrent over the user's own network here.
///
/// Real-Debrid is remote/safe and always races. If RD wins, the torrent leg is
/// stopped + its temp files wiped. If the torrent wins, the local RD resolver
/// stops polling. An existing remote RD download is retained for replay.
typedef BeamTransportResolver =
    Future<BeamPlayResult> Function(ProwlarrResult source, int? season, int? episode, BeamCancellation cancellation);

class BeamPlayService {
  BeamPlayService({
    BeamTransportResolver? realDebrid,
    BeamTransportResolver? torrent,
    TorrentStreamService? torrentStreamService,
    DateTime Function()? now,
  }) : _realDebridOverride = realDebrid,
       _torrentOverride = torrent,
       // Public injection parameter; retain private storage.
       // ignore: prefer_initializing_formals
       _torrentStreamService = torrentStreamService,
       _now = now ?? DateTime.now;
  BeamPlayService._()
    : _realDebridOverride = null,
      _torrentOverride = null,
      _torrentStreamService = null,
      _now = DateTime.now;
  final BeamTransportResolver? _realDebridOverride;
  final BeamTransportResolver? _torrentOverride;
  final TorrentStreamService? _torrentStreamService;
  final DateTime Function() _now;
  static final BeamPlayService instance = BeamPlayService._();

  /// Race the two legs for [result]. [rdEnabled] gates the RD leg (skip when no
  /// token). [torrentEnabled] gates the torrent leg (the master torrent switch
  /// / user setting); the runtime privacy gate is enforced regardless inside
  /// [TorrentStreamService]. At least one leg must be enabled.
  Future<BeamPlayResult> race(
    ProwlarrResult result, {
    required bool rdEnabled,
    required bool torrentEnabled,
    BeamPlayProgress? onProgress,
    BeamBufferWait? onBufferWait,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    BeamPlaybackDuration? playbackDuration,
    Duration? torrentStall,
    bool deferLoserCancellation = false,
    BeamCancellation? cancellation,
  }) async {
    final rdCancel = BeamCancellation();
    final torrentCancel = BeamCancellation();
    var cancelled = false;
    var committed = false;
    var reporting = true;
    BeamPlayResult? winner;
    final grab = result.grabLink;
    final magnet = result.magnetUrl;
    final statuses = <BeamPlayWinner, String>{
      if (torrentEnabled && magnet != null && magnet.startsWith('magnet:'))
        BeamPlayWinner.torrent: 'Checking connection…',
      if (rdEnabled && grab != null && grab.isNotEmpty) BeamPlayWinner.realDebrid: 'Connecting…',
    };
    final terminal = <BeamPlayWinner>{};
    void report(BeamPlayWinner leg, String status, {double? progress, bool done = false}) {
      if (!reporting || terminal.contains(leg)) return;
      if (done) terminal.add(leg);
      final percentage = leg == BeamPlayWinner.realDebrid && progress != null && progress.isFinite
          ? ' ${(progress.clamp(0.0, 1.0) * 100).round()}%'
          : '';
      statuses[leg] = '$status$percentage';
      onProgress?.call(
        statuses.entries
            .map((entry) => '${entry.key == BeamPlayWinner.realDebrid ? 'Real-Debrid' : 'InstantPlay'}: ${entry.value}')
            .join('\n'),
        // A source with two transports has no meaningful combined percent.
        progress: statuses.length == 1 && !done ? progress : null,
      );
    }

    void cancelBoth() {
      cancelled = true;
      reporting = false;
      rdCancel.cancel();
      torrentCancel.cancel();
    }

    void commit() {
      if (cancelled || committed || winner == null) return;
      committed = true;
      if (winner.winner != BeamPlayWinner.realDebrid) rdCancel.cancel();
      if (winner.winner != BeamPlayWinner.torrent) torrentCancel.cancel();
    }

    cancellation?.check();
    if (statuses.isNotEmpty) report(statuses.keys.first, statuses.values.first);
    if (cancellation != null) {
      unawaited(
        cancellation.whenCancelled.then((_) {
          cancelBoth();
        }),
      );
    }
    final legs = <Future<BeamPlayResult>>[];
    Future<BeamPlayResult> verified(Future<BeamPlayResult> operation, BeamCancellation legCancel, BeamPlayWinner leg) =>
        operation
            .then((value) {
              if (storyConstraint != null) {
                try {
                  EpisodeFileSelector.select(
                    [EpisodeFile(id: 0, path: value.selectedFilename ?? '', size: 0)],
                    season: season,
                    episode: episode,
                    storyConstraint: storyConstraint,
                  );
                } catch (_) {
                  legCancel.cancel();
                  value.cancel();
                  rethrow;
                }
              }
              report(leg, 'Ready to play', done: true);
              return value;
            })
            .catchError((Object error, StackTrace stack) {
              if (error is! BeamCancelled) {
                report(leg, _failureLabel(error), done: true);
                appLogger.w('Beam ${leg.name} leg failed', error: error, stackTrace: stack);
              }
              Error.throwWithStackTrace(error, stack);
            });
    if (rdEnabled && grab != null && grab.isNotEmpty) {
      legs.add(
        verified(
          _realDebridOverride?.call(result, season, episode, rdCancel) ??
              _rdLeg(
                grab,
                infoHash: result.infoHash,
                onProgress: (status, {progress}) => report(BeamPlayWinner.realDebrid, status, progress: progress),
                season: season,
                episode: episode,
                storyConstraint: storyConstraint,
                cancellation: rdCancel,
              ),
          rdCancel,
          BeamPlayWinner.realDebrid,
        ),
      );
    }
    if (torrentEnabled && magnet != null && magnet.startsWith('magnet:')) {
      legs.add(
        verified(
          _torrentOverride?.call(result, season, episode, torrentCancel) ??
              _torrentLeg(
                magnet,
                onProgress: (status, {progress}) => report(BeamPlayWinner.torrent, status, progress: progress),
                season: season,
                episode: episode,
                storyConstraint: storyConstraint,
                playbackDuration: playbackDuration,
                onBufferWait: onBufferWait,
                stall: torrentStall,
                cancellation: torrentCancel,
              ),
          torrentCancel,
          BeamPlayWinner.torrent,
        ),
      );
    }
    if (legs.isEmpty) throw StateError('No playable path for this source.');
    try {
      final first = firstSuccessful(legs);
      final resolved = await (cancellation?.bind(first) ?? first);
      cancellation?.check();
      winner = resolved;
      return BeamPlayResult(
        url: resolved.url,
        winner: resolved.winner,
        magnet: resolved.magnet,
        rdTorrentId: resolved.rdTorrentId,
        selectedFilename: resolved.selectedFilename,
        onPlaybackStarted: commit,
        onCancelled: cancelBoth,
      );
    } finally {
      reporting = false;
      if (winner == null) {
        cancelBoth();
      } else if (!deferLoserCancellation) {
        commit();
      }
    }
  }

  static String _failureLabel(Object error) {
    if (error is RdException) {
      if (error.code == 429) return 'Rate limited';
      if (error.code == 451) return 'Source blocked by Real-Debrid';
      if (error.code == 401 || error.code == 403) return 'Account authorization failed';
    }
    if (error is TorrentProxyRequiredException) return 'VPN or proxy required';
    if (error is EpisodeSelectionException) return 'Requested episode could not be verified';
    if (error is TimeoutException) return 'Timed out';
    return 'Unavailable';
  }

  /// Retains error handlers on all legs, including failures after a winner.
  static Future<T> firstSuccessful<T>(List<Future<T>> legs) {
    if (legs.isEmpty) return Future.error(StateError('No playback legs.'));
    final result = Completer<T>();
    var pending = legs.length;
    Object? firstError;
    StackTrace? firstStack;
    for (final leg in legs) {
      leg.then(
        (value) {
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          firstError ??= error;
          firstStack ??= stack;
          if (--pending == 0 && !result.isCompleted) result.completeError(firstError!, firstStack!);
        },
      );
    }
    return result.future;
  }

  Future<BeamPlayResult> _rdLeg(
    String grab, {
    String? infoHash,
    BeamPlayProgress? onProgress,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    required BeamCancellation cancellation,
  }) async {
    final http = await BeamHttp.client();
    final rd = RealDebridClient(
      httpClient: http,
      cancellation: cancellation,
      onRequestWait: (note) => onProgress?.call(note),
    );
    try {
      final res = await rd.resolveMagnetSmart(
        grab,
        infoHash: infoHash,
        season: season,
        episode: episode,
        storyConstraint: storyConstraint,
        cancellation: cancellation,
        onProgress: (stage, {progress, note}) {
          onProgress?.call(_rdLabel(stage, note), progress: progress);
        },
      );
      cancellation.check();
      final video = res.primaryVideo;
      if (video == null) {
        throw RdException('Real-Debrid found no playable video file.');
      }
      return BeamPlayResult(
        url: video.downloadUrl,
        winner: BeamPlayWinner.realDebrid,
        magnet: grab,
        rdTorrentId: res.torrentId,
        selectedFilename: video.filename,
      );
    } finally {
      rd.close();
    }
  }

  Future<BeamPlayResult> _torrentLeg(
    String magnet, {
    BeamPlayProgress? onProgress,
    BeamBufferWait? onBufferWait,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    BeamPlaybackDuration? playbackDuration,
    Duration? stall,
    required BeamCancellation cancellation,
  }) async {
    // Buffer telemetry exists only after metadata and startStream. Starting
    // this clock earlier would cancel healthy metadata discovery and prevent
    // the engine's bounded UDP-to-TCP fallback from ever running.
    var lastBuffer = 0.0;
    var lastTotalDone = 0;
    var preparationFinished = false;
    final stalled = Completer<BeamPlayResult>();
    Timer? watchdog;
    Timer? slowWatchdog;
    Timer? preparationWatchdog;
    final bufferWait = onBufferWait == null
        ? null
        : BeamBufferWaitController(
            onWait: onBufferWait,
            cancellation: cancellation,
            targetBufferSeconds: TorrentStreamService.initialBufferSeconds,
            now: _now,
          );
    void failPreparation(String message, Duration timeout) {
      if (stalled.isCompleted) return;
      stalled.completeError(TimeoutException(message, timeout));
      cancellation.cancel();
    }

    late void Function(BeamBufferWaitReason, String, Duration) requestWait;
    void resetBufferWatchdog() {
      // Native status callbacks remain attached during playback. Once the URL
      // is handed off, only player failure/close owns cancellation; later buffer
      // telemetry must never resurrect a preparation timer.
      if (stall == null || preparationFinished) return;
      watchdog?.cancel();
      final consent = bufferWait?.remainingConsent ?? Duration.zero;
      final budget = consent > stall ? consent : stall;
      watchdog = Timer(budget, () => requestWait(BeamBufferWaitReason.stalled, 'torrent buffer stalled', budget));
    }

    // Final bound for setup awaits that precede the engine's own deadlines.
    // Allows its 90s UDP + 240s TCP + 120s buffer budgets, plus setup time.
    const preparationLimit = Duration(minutes: 9);
    void resetPreparationWatchdog() {
      preparationWatchdog?.cancel();
      final consent = (bufferWait?.remainingConsent ?? Duration.zero) + const Duration(minutes: 1);
      final budget = consent > preparationLimit ? consent : preparationLimit;
      preparationWatchdog = Timer(budget, () {
        // Once a verified file is buffering, an unanswered wait choice owns
        // this decision too. Setup without a usable file keeps its hard bound.
        if (bufferWait?.selectedFilename != null) {
          requestWait(BeamBufferWaitReason.initialDeadline, 'torrent preparation wait declined', budget);
        } else {
          failPreparation('torrent preparation timed out', budget);
        }
      });
    }

    resetPreparationWatchdog();
    requestWait = (reason, message, timeout) {
      if (preparationFinished || cancellation.isCancelled) return;
      if (bufferWait == null) {
        failPreparation(message, timeout);
        return;
      }
      unawaited(
        bufferWait.request(reason).then((accepted) {
          if (preparationFinished || cancellation.isCancelled) return;
          if (!accepted) {
            failPreparation(message, timeout);
          }
        }),
      );
    };
    bufferWait?.onContinued = () {
      if (preparationFinished || cancellation.isCancelled) return;
      resetBufferWatchdog();
      resetPreparationWatchdog();
    };
    String? selectedFilename;
    final streamFuture = (_torrentStreamService ?? TorrentStreamService.instance)
        .streamMagnet(
          magnet,
          onPreparationStatus: (status) => onProgress?.call(status),
          season: season,
          episode: episode,
          storyConstraint: storyConstraint,
          playbackDuration: playbackDuration,
          bufferWait: bufferWait,
          cancellation: cancellation,
          onFileSelected: (filename) {
            selectedFilename = filename;
            bufferWait?.start(filename);
            if (bufferWait != null) {
              slowWatchdog = Timer(
                const Duration(seconds: 30),
                () => requestWait(
                  BeamBufferWaitReason.slow,
                  'torrent buffering was cancelled',
                  const Duration(seconds: 30),
                ),
              );
            }
            // The first verified piece can take longer than the idle budget.
            // Native initial-buffer preparation remains bounded at 120s;
            // start the shorter idle clock only once measurable progress exists.
          },
          onStatus: (s) {
            bufferWait?.observe(s.bufferSeconds);
            var advanced = false;
            if (s.bufferSeconds > lastBuffer) {
              lastBuffer = s.bufferSeconds;
              advanced = true;
            }
            // Pieces can arrive before they form a contiguous playable head.
            // Verified byte growth counts; a positive reported rate alone does
            // not. Keep high-water marks so stale/decreasing snapshots cannot
            // repeatedly extend a dead source's preparation window.
            if (s.totalDone > lastTotalDone) {
              lastTotalDone = s.totalDone;
              advanced = true;
            }
            if (advanced) resetBufferWatchdog();
            final pct = s.progress.clamp(0.0, 1.0);
            final rateMb = (s.downloadRate / (1024 * 1024)).toStringAsFixed(1);
            onProgress?.call(
              'Torrent  ${(pct * 100).toStringAsFixed(0)}%  ·  ${s.numSeeds} seeds  ·  $rateMb MB/s',
              progress: pct == 0 ? null : pct,
            );
          },
        )
        .then(
          (url) => BeamPlayResult(
            url: url,
            winner: BeamPlayWinner.torrent,
            magnet: magnet,
            selectedFilename: selectedFilename,
          ),
        );
    try {
      return await cancellation.bind(Future.any([streamFuture, stalled.future]));
    } finally {
      preparationFinished = true;
      watchdog?.cancel();
      preparationWatchdog?.cancel();
      slowWatchdog?.cancel();
      bufferWait?.dispose();
    }
  }

  String _rdLabel(RdStage stage, String? note) {
    switch (stage) {
      case RdStage.addingMagnet:
        return 'Adding to Real-Debrid…';
      case RdStage.selectingFiles:
        return 'Selecting files…';
      case RdStage.waitingCache:
        return note == null ? 'Real-Debrid caching…' : 'Waiting for Real-Debrid…';
      case RdStage.downloading:
        return note == 'compressing' || note == 'uploading'
            ? 'Preparing video on Real-Debrid\u2026'
            : 'Downloading on Real-Debrid\u2026';
      case RdStage.unrestricting:
        return 'Unlocking stream…';
      case RdStage.ready:
        return 'Ready.';
    }
  }
}
