import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;

import 'package:plezy/utils/app_logger.dart';

import '../../database/app_database.dart';
import '../../providers/multi_server_provider.dart';
import '../../focus/key_event_utils.dart';
import '../../media/media_kind.dart';
import '../../media/media_item.dart';
import 'beam_episode_identity.dart';
import 'episode_file_selector.dart';
import 'beam_library_service.dart';
import 'beam_library_resolver.dart';
import 'beam_cancellation.dart';
import 'beam_buffer_wait.dart';
import '../../widgets/beam_buffer_wait_dialog.dart';
import 'episode_source_probe.dart';
import 'beam_play_service.dart';
import 'beam_playback_duration.dart';
import '../../screens/beam/beam_search_screen.dart';
import '../../screens/video_player_screen.dart';
import '../../utils/video_player_navigation.dart';
import 'beam_community_vpn.dart';
import 'beam_config.dart';
import 'beam_http.dart';
import 'device_capability.dart';
import 'indexer_search.dart';
import 'network_class.dart';
import 'prowlarr_client.dart';
import 'quality_profile.dart';
import 'realdebrid_client.dart';
import 'release_quality.dart';
import 'release_identity.dart';
import 'torrent_stream_service.dart';

/// Silent Beam auto-play: given only a human title (+optional year), find the
/// best playable source and start it — WITHOUT ever showing the torrent list.
///
/// Checks connected libraries first, then races completed RD copies and
/// indexed sources with individual progress rows until playback starts.
///
/// Works for ANY user of the app — nothing here is server- or account-specific.
/// The raw source list still lives in the Beam tab for power users; it is never
/// shown on this path.
class BeamFallback {
  BeamFallback._();

  /// Guards against re-entrancy — a play failure mid-fallback must not spawn a
  /// second fallback for the same title.
  static bool _inFlight = false;

  @visibleForTesting
  static Future<List<ProwlarrResult>> Function(String, MediaKind)? searchOverride;
  @visibleForTesting
  static BeamPlayService? playServiceOverride;
  @visibleForTesting
  static EztvSource? episodeIndexerOverride;
  @visibleForTesting
  static Future<MediaItem?> Function(String title, int? year, MediaItem? metadata, BeamEpisodeIdentity? episode)?
  libraryLookupOverride;
  @visibleForTesting
  static Future<List<ProwlarrResult>> Function(String title, int? year, int? season, int? episode)?
  cachedSourcesOverride;
  @visibleForTesting
  static Widget Function(VideoPlayerScreen)? playerWrapper;

  /// Set when the user presses BACK on the progress overlay. The candidate loop
  /// checks it between sources so a slow/stuck resolve can be abandoned instead
  /// of holding the TV hostage until the app is killed.
  static bool _cancelRequested = false;

  /// Completed on cancel so an in-progress leg (the patient RD cache wait or
  /// a torrent buffer) aborts immediately instead of running to its timeout.
  static Completer<void>? _cancelSignal;

  static void _requestCancel() {
    _cancelRequested = true;
    final s = _cancelSignal;
    if (s != null && !s.isCompleted) s.complete();
  }

  /// Detach promptly from a stalled preparation step. Future.any keeps an error
  /// handler on the abandoned operation, so a late failure is still consumed.
  static Future<T> _untilCancelled<T>(Future<T> operation) {
    final signal = _cancelSignal!;
    return Future.any([operation, signal.future.then<T>((_) => throw const _BeamCancelled())]);
  }

  /// Per-source patience: if a torrent shows no live progress for this long we
  /// give up on it and try the next candidate. Kept short so a dead/1-seed
  /// release doesn't strand the user on a spinner.
  static const Duration _perSourceStall = Duration(seconds: 30);

  /// Auto-plays [title] ([year] disambiguates same-name titles). Returns true
  /// when playback was started, false when nothing could be resolved (caller
  /// may then show its own error). [replace] uses pushReplacement so a failed
  /// player route is swapped out rather than stacked under the new one.
  ///
  /// For a TV EPISODE, pass [title] = the SHOW name plus [season] + [episode]
  /// (1-based). The query becomes "Show SxxExx" so the indexers return that
  /// specific episode's torrents rather than the whole series.
  /// [skipLibraryLookup] is for recovery from an already-failed library player;
  /// ordinary Play requests always check the library. [savedEntry] retains a
  /// movie history entry's known magnet and resume point during that check.
  static Future<bool> playByTitle(
    BuildContext context, {
    required String title,
    int? year,
    MediaKind kind = MediaKind.movie,
    int? season,
    int? episode,
    bool replace = false,
    BeamEpisodeIdentity? beamEpisode,
    MediaItem? metadata,
    VoidCallback? onCancelled,
    bool skipLibraryLookup = false,
    BeamLibraryEntry? savedEntry,
    VoidCallback? onPlaybackClosed,
  }) async {
    beamEpisode ??= metadata == null ? null : BeamEpisodeIdentity.fromMetadata(metadata);
    if (beamEpisode == null && metadata == null && season != null && episode != null && season >= 0 && episode > 0) {
      beamEpisode = BeamEpisodeIdentity(
        showId: BeamEpisodeIdentity.titleShowId(title, year),
        showTitle: title,
        season: season,
        episode: episode,
        year: year,
      );
    }
    final tvRequest =
        kind == MediaKind.show ||
        kind == MediaKind.episode ||
        metadata?.kind == MediaKind.episode ||
        season != null ||
        episode != null;
    if (tvRequest && beamEpisode == null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('Choose an episode with a known season and episode number.')));
      return false;
    }
    if (beamEpisode != null) {
      title = beamEpisode.showTitle;
      season = beamEpisode.season;
      episode = beamEpisode.episode;
    }
    if (_inFlight) return false;
    _inFlight = true;
    _cancelRequested = false;
    _cancelSignal = Completer<void>();
    final episodeLookupFinished = Completer<void>();
    final isEpisode = season != null && episode != null;
    year ??= beamEpisode?.year ?? metadata?.year;
    final query = isEpisode ? _buildEpisodeQuery(title, season, episode) : _buildQuery(title, year);
    final displayLabel = isEpisode ? '$title  S${_pad(season)}E${_pad(episode)}' : title;
    final navigator = Navigator.of(context);
    final originRoute = ModalRoute.of(context);
    final progress = _ProgressSink(_Progress.searching(displayLabel));
    final overlay = _ProgressOverlay.insert(
      context,
      progress.listenable,
      waitOffer: progress.waitOffer,
      onKeepBuffering: () => progress.answerWait(true),
      // BACK on the overlay abandons the resolve instead of trapping the TV.
      onCancel: () {
        _requestCancel();
        progress.answerWait(false);
        appLogger.i('Beam fallback cancelled by user');
      },
    );
    BeamPlayResult? resolvedPlayback;
    var handedOff = false;
    try {
      if (!skipLibraryLookup) {
        progress.set(_Progress(title: displayLabel, headline: 'Checking your library…'));
        MediaItem? libraryItem;
        try {
          final lookup = libraryLookupOverride;
          final servers = lookup == null ? context.read<MultiServerProvider?>() : null;
          libraryItem = await _untilCancelled(
            (lookup != null
                    ? lookup(title, year, metadata, beamEpisode)
                    : servers == null
                    ? Future<MediaItem?>.value()
                    : BeamLibraryResolver(
                        servers,
                      ).resolve(title: title, year: year, metadata: metadata, episode: beamEpisode))
                .timeout(const Duration(seconds: 5)),
          );
        } on _BeamCancelled {
          rethrow;
        } catch (error, stack) {
          appLogger.w('Library lookup unavailable; continuing source race', error: error, stackTrace: stack);
        }
        if (_cancelRequested || !context.mounted || originRoute?.isCurrent == false) return false;
        if (libraryItem != null) {
          final version = await _untilCancelled(resolveSavedMediaVersionFor(libraryItem));
          if (_cancelRequested || !context.mounted || originRoute?.isCurrent == false) return false;
          overlay.remove();
          final route = buildVideoPlayerRoute(
            builder: (_) {
              final player = VideoPlayerScreen(
                metadata: libraryItem!,
                // Keep catalog story evidence even when the library supplies
                // the actual player metadata; a later server failure still
                // must resolve the original requested story.
                beamEpisode: beamEpisode,
                selectedMediaIndex: version?.index ?? 0,
                selectedMediaSourceId: version?.sourceId,
                preferredVersionSignature: version?.signature,
              );
              return playerWrapper?.call(player) ?? player;
            },
          );
          // Return as soon as the route is pushed. The library player's error
          // fallback must be able to acquire the source-race guard immediately.
          final closed = replace ? navigator.pushReplacement(route) : navigator.push(route);
          unawaited(closed.then((_) => onPlaybackClosed?.call()));
          handedOff = true;
          return true;
        }
        progress.set(_Progress.searching(displayLabel));
      }
      // This path can be entered from a Plex catalog/player failure before the
      // user has ever opened Beam settings. Initialize preferences here so a
      // Play press cannot fail before source search begins.
      await _untilCancelled(BeamConfig.init());
      // If the user opted into the built-in community VPN, bring it up before
      // searching so indexers/trackers reach through a non-censoring tunnel.
      // Best-effort (never blocks the search); no-op if a VPN is already up.
      if (BeamConfig.autoCommunityVpn) {
        progress.set(_Progress.searching('Connecting VPN…'));
        await _untilCancelled(BeamCommunityVpn.instance.ensureConnectedIfEnabled(cancelled: _cancelSignal!.future));
      }
      final rdReady = await _untilCancelled(BeamConfig.rdConfigured);
      final torrentReady = kTorrentPathEnabled && BeamConfig.torrentPlayEnabled;
      // Episodes live in the TV category; a movie/unknown searches both.
      // For an episode we ALSO pull season packs (much better seeded) and merge
      // them in — the pack is played back to the right file by SxxExx matching.
      final rawAliases = (metadata ?? beamEpisode?.metadata)?.raw?['beamShowAliases'];
      final aliases = [
        if (isEpisode && rawAliases is List)
          ...rawAliases.whereType<String>().map((alias) => alias.trim()).where((alias) => alias.isNotEmpty).take(8),
        if (metadata?.originalTitle != null && !isEpisode) metadata!.originalTitle!,
      ];
      Object? indexerError;
      // Legacy movie history has no year/IDs. Keep its exact saved magnet;
      // title-only searches could replace it with a remake and reuse its resume.
      final storedMovieOnly = savedEntry != null && !isEpisode && year == null;
      final indexed = storedMovieOnly
          ? Future.value(<ProwlarrResult>[])
          : (isEpisode
                    ? _searchEpisodeAndPacks(title, season, episode, year: year, aliases: aliases)
                    : _searchCandidates(query, kind))
                .catchError((Object error) {
                  indexerError = error;
                  return <ProwlarrResult>[];
                });
      final cached = rdReady && !storedMovieOnly
          ? _completedRdCandidates(title: title, year: year, season: season, episode: episode, aliases: aliases)
          : Future.value(<ProwlarrResult>[]);
      final storyConstraint =
          beamEpisode?.storyConstraint ??
          (metadata == null ? null : BeamEpisodeIdentity.fromMetadata(metadata)?.storyConstraint);
      final playbackDuration = BeamPlaybackDuration.fromMetadata(
        metadata ?? beamEpisode?.metadata,
        episodeQueue: beamEpisode?.episodeQueue ?? const [],
      );
      // Search and completed-account results join one race as soon as each is
      // available. Neither lookup or a slow cached copy holds up the other.
      final indexedBatch = indexed.then((rawResults) {
        final matching = isEpisode
            ? rawResults
            : rawResults
                  .where(
                    (source) => ReleaseIdentity.matchesMovie(
                      source,
                      title: title,
                      year: year,
                      aliases: [if (metadata?.originalTitle != null) metadata!.originalTitle!],
                    ),
                  )
                  .toList();
        return _rankCandidates(
          matching,
          rdReady: rdReady,
          includeTorrentCandidates: torrentReady,
          preserveOrder: isEpisode,
        );
      });
      // One verified-ID search per episode attempt, independent of every
      // text/pack query. A slow provider cannot delay a usable text result.
      final imdb = beamEpisode?.verifiedShowImdbId;
      final Future<List<ProwlarrResult>>? episodeIndexed = isEpisode && imdb != null
          ? (episodeIndexerOverride ?? EztvSource())
                .searchEpisode(
                  imdbId: imdb,
                  show: _cleanShow(title),
                  season: season,
                  episode: episode,
                  aliases: aliases,
                  cancelled: Future.any([_cancelSignal!.future, episodeLookupFinished.future]),
                )
                .then(
                  (sources) => _rankCandidates(
                    sources,
                    rdReady: rdReady,
                    includeTorrentCandidates: torrentReady,
                    preserveOrder: true,
                  ),
                )
                .catchError((Object error) {
                  appLogger.w('Verified-ID episode search unavailable', error: error);
                  return <ProwlarrResult>[];
                })
          : null;
      final resolved = await _raceCandidates(
        [
          if (savedEntry != null && !isEpisode && savedEntry.magnet.isNotEmpty)
            ProwlarrResult(
              title: savedEntry.title,
              indexer: 'library',
              size: savedEntry.item.sizeBytes,
              seeders: 0,
              leechers: 0,
              magnetUrl: savedEntry.magnet,
              downloadUrl: null,
              infoUrl: null,
              categories: const [],
              publishDate: null,
            ),
        ],
        progress,
        candidateBatches: [cached.then((sources) => sources.take(4).toList()), indexedBatch, ?episodeIndexed],
        rdReady: rdReady,
        torrentReady: torrentReady,
        maxAttempts: 8,
        allowUnknownSwarm: true,
        season: season,
        episode: episode,
        storyConstraint: storyConstraint,
        playbackDuration: playbackDuration,
      );
      if (resolved == null && indexerError != null && !_cancelRequested) throw indexerError!;

      resolvedPlayback = resolved?.$1;
      overlay.remove();
      // A deliberate BACK-cancel must not be followed by the "couldn't find a
      // source" snackbar — the user chose to stop, nothing failed.
      if (_cancelRequested) return false;
      if (resolved == null) {
        if (context.mounted) {
          _offerManual(
            context,
            query,
            beamEpisode: beamEpisode,
            metadata: metadata,
            movieTitle: isEpisode ? null : title,
            movieYear: year,
          );
        }
        return false;
      }
      if (!context.mounted) return false;
      final (playback, winner) = resolved;
      final playUrl = playback.url;
      final playerEpisode = beamEpisode?.forSelectedFile(playback.selectedFilename);
      final playbackNotice = playback.episodePlaybackNotice(isEpisode ? season : null);
      // Release names identify transports, not the movie the user selected.
      final playTitle = beamEpisode?.displayTitle ?? metadata?.title ?? title;
      // Record the played title in the local Beam library and look up its resume
      // position (keyed by info-hash) so it appears on Beam home and resumes.
      final infoHash = winner.infoHash;
      int? resumeMs;
      if ((beamEpisode != null || (infoHash != null && infoHash.isNotEmpty)) && context.mounted) {
        try {
          final lib = BeamLibraryService(context.read<AppDatabase>());
          await lib.recordPlayed(
            infoHash: infoHash ?? '',
            episode: beamEpisode,
            title: playTitle,
            posterUrl: metadata?.thumbPath ?? savedEntry?.posterUrl,
            magnet: winner.magnetUrl ?? winner.grabLink ?? '',
            quality: savedEntry != null && infoHash == savedEntry.infoHash
                ? savedEntry.quality ?? ReleaseQuality.parse(winner.title).label
                : ReleaseQuality.parse(winner.title).label,
            sizeBytes: winner.size,
          );
          resumeMs = (await lib.resumeFor(
            beamEpisode?.contentKey ?? savedEntry?.infoHash ?? infoHash!,
          ))?.inMilliseconds;
        } catch (e) {
          appLogger.w('Beam library record failed (non-fatal): $e');
        }
      }
      if (_cancelRequested || !context.mounted || originRoute?.isCurrent == false) return false;
      final route = buildVideoPlayerRoute(
        builder: (_) {
          final player = VideoPlayerScreen.direct(
            url: playUrl,
            onPlaybackStarted: playback.commitPlayback,
            onPlaybackFailed: playback.cancel,
            playbackNotice: playbackNotice,
            title: playTitle,
            beamInfoHash: infoHash,
            beamResumeMs: resumeMs,
            beamEpisode: playerEpisode,
            metadata: metadata,
          );
          return playerWrapper?.call(player) ?? player;
        },
      );
      late final Future<Object?> playerClosed;
      if (replace) {
        playerClosed = navigator.pushReplacement(route);
      } else {
        playerClosed = navigator.push(route);
      }
      handedOff = true;
      unawaited(
        playerClosed.whenComplete(() {
          playback.cancel();
          onPlaybackClosed?.call();
          return TorrentStreamService.instance.stopUrl(playUrl);
        }),
      );
      return true;
    } on _BeamCancelled {
      return false;
    } catch (e, st) {
      appLogger.e('Beam fallback failed for "$query"', error: e, stackTrace: st);
      overlay.remove();
      return false;
    } finally {
      if (!episodeLookupFinished.isCompleted) episodeLookupFinished.complete();
      overlay.remove();
      // Close BEFORE disposing so any late torrent status callbacks (the engine
      // keeps calling onStatus for the life of a now-playing torrent) become
      // no-ops instead of writing to a disposed notifier.
      progress.close();
      if (!handedOff && resolvedPlayback != null) {
        resolvedPlayback.cancel();
        unawaited(TorrentStreamService.instance.stopUrl(resolvedPlayback.url));
      }
      _inFlight = false;
      if (_cancelRequested) onCancelled?.call();
    }
  }

  /// Used by the direct player's next/previous controls; retain content
  /// identity while replacing the route with a freshly resolved episode.
  static Future<bool> playEpisode(
    BuildContext context, {
    required BeamEpisodeIdentity current,
    required MediaItem target,
    VoidCallback? onCancelled,
  }) async {
    if (target.serverId?.trim().isNotEmpty == true) {
      if (!context.mounted) return false;
      final origin = ModalRoute.of(context);
      if (origin?.isCurrent == false) return false;
      final navigator = Navigator.of(context);
      final version = await resolveSavedMediaVersionFor(target);
      if (!context.mounted || origin?.isCurrent == false) {
        onCancelled?.call();
        return false;
      }
      // A mixed catalog queue can reach an owned episode. Hand it to the
      // ordinary server player while retaining missing catalog episodes in
      // its explicit queue for the following autoplay transition.
      // Replacing the Beam route also completes its existing stream/race
      // cleanup callback; do not leave the old direct player underneath.
      final route = buildVideoPlayerRoute(
        builder: (_) {
          final player = VideoPlayerScreen(
            metadata: target,
            beamEpisode: current.forEpisode(target),
            selectedMediaIndex: version?.index ?? 0,
            selectedMediaSourceId: version?.sourceId,
            preferredVersionSignature: version?.signature,
          );
          return playerWrapper?.call(player) ?? player;
        },
      );
      unawaited(navigator.pushReplacement(route));
      return true;
    }
    final next = current.forEpisode(target);
    return playByTitle(context, title: next.showTitle, beamEpisode: next, replace: true, onCancelled: onCancelled);
  }

  static Future<List<ProwlarrResult>> _completedRdCandidates({
    required String title,
    int? year,
    int? season,
    int? episode,
    Iterable<String> aliases = const [],
  }) async {
    final override = cachedSourcesOverride;
    final signal = _cancelSignal!;
    http.Client? lookupClient;
    var abandoned = false;
    final lookupCancellation = BeamCancellation();
    Future<List<ProwlarrResult>> lookup() async {
      if (override != null) return override(title, year, season, episode);
      final client = await BeamHttp.client();
      lookupClient = client;
      if (abandoned || signal.isCompleted) {
        client.close();
        throw const _BeamCancelled();
      }
      return RealDebridClient(
        httpClient: client,
        cancellation: lookupCancellation,
      ).completedCandidates(title: title, year: year, season: season, episode: episode, aliases: aliases);
    }

    try {
      final candidates = await _untilCancelled(lookup().timeout(const Duration(seconds: 5)));
      return candidates
          .where(
            (source) => season == null && episode == null
                ? ReleaseIdentity.matchesMovie(source, title: title, year: year, aliases: aliases)
                : season != null &&
                      episode != null &&
                      ReleaseIdentity.matchesEpisodeSource(
                        source,
                        show: title,
                        season: season,
                        episode: episode,
                        aliases: aliases,
                      ),
          )
          .toList();
    } on _BeamCancelled {
      rethrow;
    } catch (error) {
      appLogger.w('RD completed-copy lookup unavailable; continuing indexer search: $error');
      return const [];
    } finally {
      abandoned = true;
      lookupCancellation.cancel();
      lookupClient?.close();
    }
  }

  static String _buildQuery(String title, int? year) {
    final t = title.trim();
    if (year != null && year > 1900 && !t.contains('$year')) {
      return '$t $year';
    }
    return t;
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');

  /// "Show S01E05" — the scene-standard episode query almost every TV release
  /// group and indexer keys on. Strips any trailing year from the show name so
  /// "The Office (2005) S01E05" doesn't over-constrain the match.
  static String _buildEpisodeQuery(String show, int season, int episode) {
    final s = show.trim().replaceAll(RegExp(r'\s*\(\d{4}\)\s*$'), '').trim();
    return '$s S${_pad(season)}E${_pad(episode)}';
  }

  static String _cleanShow(String show) => show.trim().replaceAll(RegExp(r'\s*\(\d{4}\)\s*$'), '').trim();

  /// Searches for the single episode AND its season pack, merging results with
  /// PACKS FIRST. Season packs are typically far better seeded than a lone
  /// episode, and the player selects the right file inside the pack by SxxExx —
  /// so "grab the pack, play this episode" is the more reliable path.
  static Future<List<ProwlarrResult>> _searchEpisodeAndPacks(
    String show,
    int season,
    int episode, {
    int? year,
    Iterable<String> aliases = const [],
  }) async {
    final clean = _cleanShow(show);
    final queries = EpisodeSourceProbe.queries(clean, season, episode, year: year);
    var failures = 0;
    final batches = await Future.wait(
      queries.map((q) async {
        try {
          return await _searchCandidates(q, MediaKind.episode);
        } catch (_) {
          failures++;
          return <ProwlarrResult>[];
        }
      }),
    );
    if (failures == queries.length) throw IndexerUnavailableException('Episode source search is unavailable.');
    // De-dup by magnet/title; classify each as pack vs single episode.
    final seen = <String>{};
    final packs = <ProwlarrResult>[];
    final singles = <ProwlarrResult>[];
    for (final list in batches) {
      for (final r in list) {
        final sourceKind = ReleaseIdentity.episodeSourceKind(
          r,
          show: clean,
          season: season,
          episode: episode,
          aliases: aliases,
        );
        if (sourceKind == null) continue;
        final key = r.infoHash ?? r.magnetUrl ?? r.title;
        if (!seen.add(key)) continue;
        (sourceKind == EpisodeReleaseKind.episode ? singles : packs).add(r);
      }
    }
    // Packs first (better seeded); rank each group by seeders.
    packs.sort((a, b) => b.seeders.compareTo(a.seeders));
    singles.sort((a, b) => b.seeders.compareTo(a.seeders));
    return [...packs, ...singles];
  }

  static final _episodeProbe = EpisodeSourceProbe((query) => _searchCandidates(query, MediaKind.episode));

  static Future<EpisodeSourceAvailability> episodeSourceAvailability({
    required String show,
    required int season,
    required int episode,
  }) => _episodeProbe.check(_cleanShow(show), season, episode);

  /// Indexer results are candidates only; actual pack contents are verified at
  /// resolution. An outage must not silently hide episodes from the catalogue.
  static Future<bool> episodeHasSource({required String show, required int season, required int episode}) async =>
      await _episodeProbe.check(_cleanShow(show), season, episode) != EpisodeSourceAvailability.unavailable;

  static Future<List<ProwlarrResult>> _searchCandidates(String query, MediaKind kind) {
    final cats = kind == MediaKind.show || kind == MediaKind.episode ? const [5000] : const [2000];
    return searchOverride?.call(query, kind) ?? CombinedIndexer().search(query, categories: cats);
  }

  /// Rank + device/network cap, returning an ORDERED candidate list
  /// (best first) so a dead top pick can fall through to the next. For the
  /// torrent path, only seeded magnets are kept (a 0-seed release can never
  /// stream) and ties break toward more seeders — the fix for "just loading".
  static Future<List<ProwlarrResult>> _rankCandidates(
    List<ProwlarrResult> results, {
    required bool rdReady,
    bool preserveOrder = false,
    bool includeTorrentCandidates = false,
  }) async {
    if (results.isEmpty) return const [];

    // Episodes come in already ordered PACKS-FIRST from _searchEpisodeAndPacks.
    // Keep that order — just drop unstreamable entries. Do NOT run the movie
    // stream-score re-rank, which penalizes a pack's (large) total size even
    // though we only stream one episode's file out of it.
    if (preserveOrder) {
      if (rdReady) {
        return results.where((r) => r.grabLink?.isNotEmpty ?? false).toList();
      }
      return results.where((r) => r.hasMagnet && r.seeders > 0).toList();
    }

    final allowCam = BeamConfig.allowCamReleases;
    final profile = rdReady ? realDebridProfile(allowCam: allowCam) : torrentProfile(allowCam: allowCam);
    var ranked = profile.rank(results);
    // A release rejected by the RD ranking may still work through its torrent
    // leg. Keep both profiles in the single concurrent selection.
    if (rdReady && includeTorrentCandidates) {
      ranked = {...ranked, ...torrentProfile(allowCam: allowCam).rank(results)}.toList();
    }
    if (ranked.isEmpty) ranked = results;

    if (!rdReady) {
      // Torrent: a source with no magnet or no seeders will never buffer. Drop
      // them, and within the quality ranking prefer better-seeded releases so
      // auto-play lands on something that actually streams.
      ranked = ranked.where((r) => r.hasMagnet && r.seeders > 0).toList();
    } else {
      ranked = ranked.where((r) => r.grabLink?.isNotEmpty ?? false).toList();
    }

    return _orderByDeviceThenSeeds(ranked);
  }

  /// Start the selected sources together. Both transports race per source;
  /// source losers remain owned until the first actual playback frame.
  static Future<(BeamPlayResult, ProwlarrResult)?> _raceCandidates(
    List<ProwlarrResult> candidates,
    _ProgressSink progress, {
    Iterable<Future<List<ProwlarrResult>>> candidateBatches = const [],
    required bool rdReady,
    required bool torrentReady,
    required int maxAttempts,
    bool allowUnknownSwarm = false,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    BeamPlaybackDuration? playbackDuration,
  }) {
    if (_cancelRequested) return Future.value(null);
    final statuses = <ProwlarrResult, String>{};
    final failed = <ProwlarrResult>{};
    void publish() {
      final active = statuses.length - failed.length;
      progress.set(
        _Progress(
          title: 'The first ready source will open automatically.',
          headline: 'Trying $active sources at the same time',
          sourceStatuses: statuses.entries.indexed
              .where((entry) => !failed.contains(entry.$2.key))
              .map((entry) => 'Source ${entry.$1 + 1}: ${entry.$2.value}')
              .toList(),
        ),
      );
    }

    return raceCandidateSources(
      candidates,
      candidateBatches: candidateBatches,
      service: playServiceOverride ?? BeamPlayService.instance,
      rdReady: rdReady,
      torrentReady: torrentReady,
      maxAttempts: maxAttempts,
      maxTotalAttempts: maxAttempts * 3,
      allowUnknownSwarm: allowUnknownSwarm,
      season: season,
      episode: episode,
      storyConstraint: storyConstraint,
      playbackDuration: playbackDuration,
      cancelled: _cancelSignal?.future,
      onBufferWait: progress.requestWait,
      onAttempt: (source, index) {
        statuses[source] = 'Connecting?';
        publish();
      },
      onProgress: (source, status, fraction) {
        statuses[source] = status;
        publish();
      },
      onFailed: (source) {
        failed.add(source);
        statuses[source] = 'Unavailable';
        publish();
      },
    );
  }

  /// Start up to [maxAttempts] sources together. Failed sources free a slot for
  /// queued alternatives, within [maxTotalAttempts]'s lifetime budget.
  @visibleForTesting
  static Future<(BeamPlayResult, ProwlarrResult)?> raceCandidateSources(
    List<ProwlarrResult> candidates, {
    Iterable<Future<List<ProwlarrResult>>> candidateBatches = const [],
    required BeamPlayService service,
    required bool rdReady,
    required bool torrentReady,
    required int maxAttempts,
    int? maxTotalAttempts,
    bool allowUnknownSwarm = false,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    BeamPlaybackDuration? playbackDuration,
    Future<void>? cancelled,
    BeamBufferWait? onBufferWait,
    void Function(ProwlarrResult, int)? onAttempt,
    void Function(ProwlarrResult, String, double?)? onProgress,
    void Function(ProwlarrResult)? onFailed,
  }) {
    final batches = candidateBatches.toList();
    final outcome = Completer<(BeamPlayResult, ProwlarrResult)?>();
    final tokens = <int, BeamCancellation>{};
    final resolved = <int, BeamPlayResult>{};
    final seen = <String>{};
    final queued = <ProwlarrResult>[];
    final totalLimit = maxTotalAttempts ?? maxAttempts;
    if (maxAttempts <= 0 || totalLimit <= 0) return Future.value(null);
    var pendingBatches = batches.length;
    var pending = 0;
    var stopped = false;
    var committed = false;
    int? winnerIndex;

    void finishIfEmpty() {
      if (!outcome.isCompleted && pending == 0 && pendingBatches == 0) outcome.complete(null);
    }

    void cancelAll() {
      if (stopped) return;
      stopped = true;
      queued.clear();
      for (final token in tokens.values) {
        token.cancel();
      }
      for (final result in resolved.values) {
        result.cancel();
      }
      if (!outcome.isCompleted) outcome.complete(null);
    }

    void commit() {
      if (stopped || committed || winnerIndex == null) return;
      committed = true;
      for (final entry in tokens.entries) {
        if (entry.key != winnerIndex) entry.value.cancel();
      }
      for (final entry in resolved.entries) {
        if (entry.key != winnerIndex) entry.value.cancel();
      }
      resolved[winnerIndex]!.commitPlayback();
    }

    void launchBatch(List<ProwlarrResult> sources) {
      if (stopped || outcome.isCompleted) return;
      // A later provider gets a chance in the next free slot, instead of being
      // buried behind every unused variant from the first search response.
      final available = <ProwlarrResult>[];
      final queuedIdentities = <String>{...seen};
      for (final source in [...sources, ...queued]) {
        if (available.length >= totalLimit - tokens.length) break;
        final torrentLeg = torrentReady && source.hasMagnet && (source.seeders > 0 || allowUnknownSwarm);
        final rdLeg = rdReady && (source.grabLink?.isNotEmpty ?? false);
        if (!rdLeg && !torrentLeg) continue;
        final identity = source.infoHash ?? source.grabLink ?? '${source.title}|${source.size}';
        if (queuedIdentities.add(identity)) available.add(source);
      }
      queued
        ..clear()
        ..addAll(available);
      while (pending < maxAttempts && tokens.length < totalLimit && queued.isNotEmpty) {
        if (stopped || outcome.isCompleted) break;
        final source = queued.removeAt(0);
        final torrentLeg = torrentReady && source.hasMagnet && (source.seeders > 0 || allowUnknownSwarm);
        final rdLeg = rdReady && (source.grabLink?.isNotEmpty ?? false);
        seen.add(source.infoHash ?? source.grabLink ?? '${source.title}|${source.size}');
        final index = tokens.length;
        final token = BeamCancellation();
        tokens[index] = token;
        pending++;
        onAttempt?.call(source, index);
        final operation = Future<BeamPlayResult>.sync(
          () => service.race(
            source,
            rdEnabled: rdLeg,
            torrentEnabled: torrentLeg,
            season: season,
            episode: episode,
            storyConstraint: storyConstraint,
            playbackDuration: playbackDuration,
            torrentStall: _perSourceStall,
            onBufferWait: onBufferWait,
            deferLoserCancellation: true,
            cancellation: token,
            onProgress: (status, {progress}) {
              if (!stopped && !outcome.isCompleted && !token.isCancelled) onProgress?.call(source, status, progress);
            },
          ),
        );
        unawaited(
          operation.then<void>(
            (result) {
              pending--;
              resolved[index] = result;
              if (stopped || committed) {
                token.cancel();
                result.cancel();
                return;
              }
              if (outcome.isCompleted) return;
              winnerIndex = index;
              queued.clear();
              outcome.complete((
                BeamPlayResult(
                  url: result.url,
                  winner: result.winner,
                  magnet: result.magnet,
                  rdTorrentId: result.rdTorrentId,
                  selectedFilename: result.selectedFilename,
                  onPlaybackStarted: commit,
                  onCancelled: cancelAll,
                ),
                source,
              ));
            },
            onError: (Object error, StackTrace stack) {
              pending--;
              token.cancel();
              if (stopped || outcome.isCompleted) return;
              onFailed?.call(source);
              appLogger.w('Beam source ${index + 1} failed all enabled playback paths: $error');
              launchBatch(const []);
            },
          ),
        );
      }
      finishIfEmpty();
    }

    if (cancelled != null) unawaited(cancelled.then((_) => cancelAll()));
    // Install handlers before launching: even a late failure after handoff is
    // owned, and no late batch may restart a completed/cancelled race.
    for (final batch in batches) {
      unawaited(
        batch.then<void>(
          (sources) {
            pendingBatches--;
            launchBatch(sources);
          },
          onError: (Object error, StackTrace stack) {
            pendingBatches--;
            if (!stopped && !outcome.isCompleted) {
              appLogger.w('Beam source lookup failed', error: error, stackTrace: stack);
              finishIfEmpty();
            }
          },
        ),
      );
    }
    launchBatch(candidates);
    return outcome.future;
  }

  /// Keep sources the device can decode / network allows first, then order by
  /// seeders within that. Sources the device can't decode go last (still usable
  /// as a last resort).
  static Future<List<ProwlarrResult>> _orderByDeviceThenSeeds(List<ProwlarrResult> sources) async {
    try {
      final netClass = await NetworkClassProbe.instance.probe();
      final cap = (await DeviceCapability.probe()).cappedTo(NetworkClassProbe.capForClass(netClass));
      final playable = <ProwlarrResult>[];
      final rest = <ProwlarrResult>[];
      for (final s in sources) {
        (cap.allows(ReleaseQuality.parse(s.title)) ? playable : rest).add(s);
      }
      // Order for SMOOTH STREAMING, not just raw seeders. A 12GB 1080p file with
      // 900 seeds still rebuffers over a constrained VPN/swarm because its
      // bitrate outruns the sustained download rate, while a well-seeded 720p /
      // smaller 1080p plays through. So score = seeders (health) with a penalty
      // for very large files (high bitrate). Same-title candidates share runtime,
      // so file size is a good bitrate proxy. High quality still leads when it
      // has the seeds to sustain it; a lighter release only wins when the heavy
      // one couldn't keep up anyway.
      playable.sort((a, b) => _streamScore(b).compareTo(_streamScore(a)));
      rest.sort((a, b) => b.seeders.compareTo(a.seeders));
      return [...playable, ...rest];
    } catch (e) {
      appLogger.w('Beam fallback capability probe failed: $e');
      final copy = [...sources]..sort((a, b) => b.seeders.compareTo(a.seeders));
      return copy;
    }
  }

  /// Streamability score: swarm health minus a bitrate (file-size) penalty, so
  /// the pick is one that can actually sustain playback rather than the biggest/
  /// most-seeded file. Seeders dominate up to a point; beyond ~8GB the size
  /// penalty grows so a lighter, still-well-seeded release is preferred.
  static double _streamScore(ProwlarrResult r) {
    final seeds = r.seeders < 0 ? 0 : r.seeders;
    // Diminishing returns on seeders past ~60 (enough for a full pipe).
    final health = seeds <= 60 ? seeds.toDouble() : 60 + (seeds - 60) * 0.1;
    final gib = r.size > 0 ? r.size / (1024 * 1024 * 1024) : 0.0;
    // No penalty up to 8GiB, then -6 per extra GiB (a 15GiB file loses ~42).
    final sizePenalty = gib <= 8 ? 0.0 : (gib - 8) * 6.0;
    return health - sizePenalty;
  }

  /// Nothing auto-resolved — offer the manual Beam search (the only place the
  /// source list ever appears) so the user isn't dead-ended.
  static void _offerManual(
    BuildContext context,
    String query, {
    BeamEpisodeIdentity? beamEpisode,
    MediaItem? metadata,
    String? movieTitle,
    int? movieYear,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: const Text('Couldn\'t find a source to stream automatically.'),
        action: SnackBarAction(
          label: 'Choose source',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => BeamSearchScreen(
                initialQuery: query,
                beamEpisode: beamEpisode,
                metadata: metadata,
                movieTitle: movieTitle,
                movieYear: movieYear,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thrown into an in-flight resolve leg when the user cancels from the overlay.
class _BeamCancelled implements Exception {
  const _BeamCancelled();
  @override
  String toString() => 'Beam resolve cancelled by user';
}

/// Immutable snapshot of the auto-play progress, rendered by [_ProgressOverlay].
class _Progress {
  const _Progress({required this.title, required this.headline, this.sourceStatuses = const []});

  final String title;
  final String headline;
  final List<String> sourceStatuses;

  factory _Progress.searching(String title) => _Progress(title: title, headline: 'Finding best source…');
}

/// Owns the progress [ValueNotifier] with a close latch. The torrent engine
/// keeps invoking onStatus for the life of a now-playing torrent, so writes must
/// survive being called AFTER we've handed off and torn down — once [close]d,
/// [set] is a no-op and the notifier is disposed exactly once.
class _ProgressSink {
  _ProgressSink(_Progress initial) : _notifier = ValueNotifier<_Progress>(initial);

  final ValueNotifier<_Progress> _notifier;
  bool _closed = false;
  final waitOffer = ValueNotifier<BeamBufferWaitOffer?>(null);
  final _waiters = <BeamBufferWaitOffer, Completer<bool>>{};
  final _deferredOffers = <BeamBufferWaitOffer>{};
  bool _consentActive = false;
  Timer? _waitReminder;

  Future<bool> requestWait(BeamBufferWaitOffer offer) {
    // A ready URL can hand off while a different source is still preparing.
    // Keep that source alive until its normal ownership/cancellation completes.
    if (_closed) return offer.done.then((_) => true);
    final answer = Completer<bool>();
    _waiters[offer] = answer;
    _refreshWaitOffer();
    unawaited(
      offer.done.then((_) {
        _waiters.remove(offer);
        _deferredOffers.remove(offer);
        if (!answer.isCompleted) answer.complete(true);
        if (!_closed) _refreshWaitOffer();
      }),
    );
    return answer.future;
  }

  void _refreshWaitOffer() {
    if (_waiters.isNotEmpty && _consentActive) {
      // One Keep choice covers the active race. A hedged source must not ask
      // the same question again a few seconds into the accepted wait.
      _deferredOffers.addAll(_waiters.keys);
      waitOffer.value = null;
      return;
    }
    BeamBufferWaitOffer? best;
    for (final offer in _waiters.keys) {
      if (best == null ||
          (offer.estimatedWait != null && (best.estimatedWait == null || offer.estimatedWait! < best.estimatedWait!))) {
        best = offer;
      }
    }
    // A deferred offer's original estimate is stale; do not present it as a
    // fresh countdown when the agreed wait ends.
    waitOffer.value = best != null && _deferredOffers.contains(best)
        ? BeamBufferWaitOffer(
            bufferSeconds: best.bufferSeconds,
            targetBufferSeconds: best.targetBufferSeconds,
            elapsed: best.elapsed,
            reason: best.reason,
            selectedFilename: best.selectedFilename,
            done: best.done,
          )
        : best;
  }

  void answerWait(bool keepBuffering) {
    _waitReminder?.cancel();
    if (keepBuffering && !_closed) {
      const minimum = Duration(minutes: 2);
      final estimate = waitOffer.value?.estimatedWait;
      final measured = estimate == null ? minimum : estimate + const Duration(seconds: 30);
      _consentActive = true;
      _waitReminder = Timer(measured > minimum ? measured : minimum, () {
        _consentActive = false;
        if (!_closed) _refreshWaitOffer();
      });
    } else {
      _consentActive = false;
    }
    _deferredOffers.clear();
    final pending = _waiters.values.toList();
    _waiters.clear();
    if (!_closed) waitOffer.value = null;
    for (final answer in pending) {
      if (!answer.isCompleted) answer.complete(keepBuffering);
    }
  }

  ValueListenable<_Progress> get listenable => _notifier;

  void set(_Progress p) {
    if (_closed) return;
    _notifier.value = p;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _waitReminder?.cancel();
    _notifier.dispose();
    waitOffer.dispose();
  }
}

/// A persistent full-screen progress card shown for the whole resolve — search,
/// connect, and buffer — so there's always a visible percentage (or a live
/// seeds/speed line) rather than a blank spinner. Inserted into the root
/// [Overlay] so it survives route changes underneath it.
class _ProgressOverlay {
  _ProgressOverlay._(this._entry, this._focusNode);

  final OverlayEntry _entry;
  final FocusNode _focusNode;

  /// Whatever owned focus before the overlay took it, restored on dismiss so
  /// the page underneath doesn't come back with unowned focus (which would
  /// swallow the next D-pad press).
  FocusNode? _previousFocus;
  bool _removed = false;
  LocalHistoryEntry? _backEntry;

  static _ProgressOverlay insert(
    BuildContext context,
    ValueListenable<_Progress> progress, {
    required ValueListenable<BeamBufferWaitOffer?> waitOffer,
    required VoidCallback onKeepBuffering,
    VoidCallback? onCancel,
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    late final _ProgressOverlay handle;
    // A raw OverlayEntry has no focus and no key handling, so on a TV the
    // remote was dead while this covered the screen — BACK went to the
    // Navigator and popped the page UNDER the overlay while the overlay stayed
    // (seen on the ONN). An `autofocus` inside an OverlayEntry never wins
    // primary focus either, so we own a node and request focus explicitly.
    final focusNode = FocusNode(debugLabel: 'BeamProgressOverlay');
    final entry = OverlayEntry(
      builder: (ctx) {
        final theme = Theme.of(ctx);
        // Keep Stack parent data outside the semantics render object from Focus.
        return Positioned.fill(
          child: Focus(
            focusNode: focusNode,
            onKeyEvent: (node, event) => handleBackKeyAction(event, () {
              onCancel?.call();
              handle.remove();
            }),
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.78),
              child: Center(
                child: ValueListenableBuilder<_Progress>(
                  valueListenable: progress,
                  builder: (context, p, _) {
                    return ValueListenableBuilder<BeamBufferWaitOffer?>(
                      valueListenable: waitOffer,
                      builder: (context, offer, _) {
                        if (offer != null) {
                          return BeamBufferWaitDialog(
                            offer: offer,
                            onKeepBuffering: () {
                              onKeepBuffering();
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (!handle._removed) focusNode.requestFocus();
                              });
                            },
                            onCancel: () {
                              onCancel?.call();
                              handle.remove();
                            },
                          );
                        }
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(width: 72, height: 72, child: CircularProgressIndicator(strokeWidth: 4)),
                            const SizedBox(height: 22),
                            Text(
                              p.headline,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleMedium?.copyWith(color: Colors.white),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              p.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
                            ),
                            if (p.sourceStatuses.isNotEmpty) ...[
                              const SizedBox(height: 14),
                              SizedBox(
                                width: 680,
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxHeight: 240),
                                  child: SingleChildScrollView(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        for (final status in p.sourceStatuses)
                                          Padding(
                                            padding: const EdgeInsets.symmetric(vertical: 3),
                                            child: Text(
                                              status,
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 18),
                            Text(
                              'Press BACK to cancel',
                              style: theme.textTheme.labelMedium?.copyWith(color: Colors.white38),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    handle = _ProgressOverlay._(entry, focusNode);
    // Android system Back may bypass Flutter key events. Consume it on the
    // existing route so a covered detail page cannot pop under this overlay.
    final route = ModalRoute.of(context);
    if (route != null) {
      handle._backEntry = LocalHistoryEntry(
        onRemove: () {
          if (handle._removed) return;
          onCancel?.call();
          handle.remove();
        },
      );
      route.addLocalHistoryEntry(handle._backEntry!);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (handle._removed) return;
      handle._previousFocus = FocusManager.instance.primaryFocus;
      focusNode.requestFocus();
    });
    return handle;
  }

  void remove() {
    if (_removed) return;
    _removed = true;
    _backEntry?.remove();
    _backEntry = null;
    _entry.remove();
    final prev = _previousFocus;
    if (prev != null && prev.canRequestFocus) prev.requestFocus();
    _focusNode.dispose();
  }
}
