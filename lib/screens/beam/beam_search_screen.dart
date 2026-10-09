import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:plezy/utils/app_logger.dart';

import '../../database/app_database.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../services/beam/release_identity.dart';
import '../../navigation/main_screen_scope.dart';
import '../../services/beam/beam_community_vpn.dart';
import '../../services/beam/beam_config.dart';
import '../../services/beam/beam_library_service.dart';
import '../../services/beam/beam_episode_identity.dart';
import '../../services/beam/beam_playback_duration.dart';
import '../../services/beam/device_capability.dart';
import '../../services/beam/indexer_search.dart';
import '../../services/beam/network_class.dart';
import '../../services/beam/prowlarr_client.dart';
import '../../services/beam/quality_profile.dart';
import '../../services/beam/release_quality.dart';
import '../../services/beam/torrent_stream_service.dart' show TorrentStreamService;
import '../../utils/platform_detector.dart';
import '../../utils/video_player_navigation.dart';
import '../video_player_screen.dart';
import 'beam_resolve_sheet.dart';

/// Category filter for the Beam search toolbar. Maps to Newznab buckets:
/// movies = 2000, TV = 5000.
enum BeamCategory { all, movies, tv }

extension on BeamCategory {
  String get label => switch (this) {
    BeamCategory.all => 'All',
    BeamCategory.movies => 'Movies',
    BeamCategory.tv => 'TV',
  };

  List<int> get ids => switch (this) {
    BeamCategory.all => const [2000, 5000],
    BeamCategory.movies => const [2000],
    BeamCategory.tv => const [5000],
  };
}

/// The main Beam UI: search public indexers, browse results with quality
/// badges + seeders, pick one, then choose Real-Debrid (instant) or a live
/// torrent stream. D-pad / focus friendly for Android TV.
///
/// Embed by pushing it as a route, e.g.:
/// `Navigator.push(context, MaterialPageRoute(builder: (_) => const BeamSearchScreen()));`
/// or drop it into a tab/body directly — it provides its own [Scaffold].
class BeamSearchScreen extends StatefulWidget {
  const BeamSearchScreen({
    super.key,
    this.appBarActions,
    this.initialQuery,
    this.beamEpisode,
    this.metadata,
    this.movieTitle,
    this.movieYear,
    this.indexer,
  });

  /// Optional trailing actions injected into the [AppBar] (e.g. a settings
  /// button when embedded as a top-level tab via [BeamHome]).
  final List<Widget>? appBarActions;

  /// When set (e.g. from the Plex-style poster picker), the screen opens with
  /// this query pre-filled and searches for its sources immediately.
  final String? initialQuery;
  final BeamEpisodeIdentity? beamEpisode;
  final MediaItem? metadata;
  final String? movieTitle;
  final int? movieYear;
  /// Allows the same automatic source lookup to be exercised without networking.
  final CombinedIndexer? indexer;

  @override
  State<BeamSearchScreen> createState() => _BeamSearchScreenState();
}

class _BeamSearchScreenState extends State<BeamSearchScreen> {
  late final CombinedIndexer _indexer = widget.indexer ?? CombinedIndexer();
  final TextEditingController _controller = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// The leftmost ("All") chip — LEFT from it escapes to the nav rail; LEFT
  /// from any other chip just moves between chips.
  final FocusNode _firstChipFocus = FocusNode(debugLabel: 'BeamSearchFirstChip');

  /// D-pad LEFT hands focus back to the navigation rail. Every other Plezy
  /// tab does this; without it this screen was a focus trap on TV.
  void _navigateToSidebar() => MainScreenFocusScope.focusSidebarOf(context);

  /// Wraps [child] so LEFT escapes to the rail when [shouldEscape] says so.
  /// Returning `ignored` otherwise lets Flutter's normal traversal run.
  Widget _leftEscape({required Widget child, required bool Function() shouldEscape}) {
    return Focus(
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft && shouldEscape()) {
          _navigateToSidebar();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }

  BeamCategory _category = BeamCategory.all;
  List<ProwlarrResult> _results = const [];
  List<_ReleaseGroup> _groups = const [];
  bool _loading = false;
  bool _searched = false;
  String? _error;
  int _searchToken = 0; // guards against out-of-order async results

  @override
  void initState() {
    super.initState();
    if (widget.beamEpisode != null) _category = BeamCategory.tv;
    final seed = widget.initialQuery?.trim();
    if (seed != null && seed.isNotEmpty) {
      _controller.text = seed;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _runSearch();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchFocus.dispose();
    _firstChipFocus.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    final token = ++_searchToken;
    setState(() {
      _loading = true;
      _searched = true;
      _error = null;
    });
    try {
      // Bring up the built-in community VPN first if the user opted in, so the
      // indexer lookups below ride a non-censoring tunnel. Best-effort/no-op if
      // a VPN is already active or the option is off.
      if (BeamConfig.autoCommunityVpn) {
        await BeamCommunityVpn.instance.ensureConnectedIfEnabled();
        if (!mounted || token != _searchToken) return;
      }
      final raw = await _indexer.search(query, categories: _category.ids);
      final res = raw.where(_matchesBoundIdentity).toList();
      if (!mounted || token != _searchToken) return;
      setState(() {
        _results = res;
        _groups = _groupByTitle(res);
        _loading = false;
      });
      // Hand focus to the results so a TV remote can drive them immediately.
      // Without this the search field keeps focus (and the on-screen keyboard
      // stays over the list), leaving the D-pad unable to reach any play button.
      if (res.isNotEmpty) {
        _searchFocus.unfocus();
      }
    } catch (e) {
      appLogger.e('Beam search failed: $e');
      if (!mounted || token != _searchToken) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _onCategory(BeamCategory c) {
    if (c == _category) return;
    setState(() => _category = c);
    if (_searched) _runSearch();
  }

  void _clearSearch() {
    _searchToken++;
    _controller.clear();
    if (!mounted) return;
    setState(() {
      _results = const [];
      _groups = const [];
      _error = null;
      _loading = false;
      _searched = false;
    });
    _searchFocus.requestFocus();
  }

  /// One-tap AUTO play: pick the best source in the group that this device can
  /// decode AND the current network allows, then resolve+play it. Defaults to
  /// TORRENT stream (play-while-downloading); Real-Debrid is used only when the
  /// user has actually configured a token. Torrent stays fail-closed
  /// (proxy-required) so it never touches the user's own network unproxied.
  Future<void> _autoPlayGroup(_ReleaseGroup group) async {
    final rdReady = await BeamConfig.rdConfigured;
    if (!mounted) return;
    // The play sheet RACES Real-Debrid and the (privacy-gated) torrent stream,
    // so we don't pick a mode — we pick the best SOURCE. Rank with a
    // Sonarr/Radarr-style quality profile (custom-format scoring) rather than
    // "most seeders wins". Prefer the RD-safe profile when RD is configured
    // (RD's May-2026 filename filter rejects WEB-DL/WEBRip/AMZN/YTS/RARBG), else
    // the torrent profile (requires a magnet, weights swarm health). Cam/
    // telesync releases score out unless the user opts in.
    final allowCam = BeamConfig.allowCamReleases;
    final profile = rdReady ? realDebridProfile(allowCam: allowCam) : torrentProfile(allowCam: allowCam);
    final ranked = profile.rank(group.sources);
    final pool = ranked.isNotEmpty ? ranked : group.sources;
    final best = await _pickBestForDevice(pool);
    if (!mounted) return;
    _resolve(best);
  }

  /// Chooses the highest-quality source the device can decode AND the current
  /// connection allows (device ceiling ∩ network cap). Falls back to the
  /// group's top source if nothing clears the ceiling. Sources are best-first.
  Future<ProwlarrResult> _pickBestForDevice(List<ProwlarrResult> sources) async {
    try {
      final netClass = await NetworkClassProbe.instance.probe();
      final cap = (await DeviceCapability.probe()).cappedTo(NetworkClassProbe.capForClass(netClass));
      for (final s in sources) {
        if (cap.allows(ReleaseQuality.parse(s.title))) return s;
      }
    } catch (e) {
      appLogger.w('Beam auto-pick capability probe failed: $e');
    }
    return sources.first; // least-bad: the highest-seeded/highest-quality source
  }

  /// Plays a specific source directly (power-user path from the "Other sources
  /// & qualities" expander). No mode picker — the sheet races both paths.
  void _openResult(ProwlarrResult r) => _resolve(r);

  bool _matchesBoundIdentity(ProwlarrResult source) {
    final episode = widget.beamEpisode;
    if (episode != null) {
      final rawAliases = (widget.metadata ?? episode.metadata)?.raw?['beamShowAliases'];
      return ReleaseIdentity.matchesEpisodeSource(
        source,
        show: episode.showTitle,
        season: episode.season,
        episode: episode.episode,
        aliases: rawAliases is List
            ? rawAliases.whereType<String>().map((alias) => alias.trim()).where((alias) => alias.isNotEmpty).take(8)
            : const [],
      );
    }
    final metadata = widget.metadata;
    if (metadata?.kind == MediaKind.movie || widget.movieTitle != null) {
      return ReleaseIdentity.matchesMovie(
        source,
        title: metadata?.title ?? widget.movieTitle ?? '',
        year: metadata?.year ?? widget.movieYear,
        aliases: [if (metadata?.originalTitle != null) metadata!.originalTitle!],
      );
    }
    return true;
  }

  void _resolve(ProwlarrResult r) {
    if (!_matchesBoundIdentity(r)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('This source does not match the selected title.')));
      return;
    }
    final originRoute = ModalRoute.of(context);
    BeamResolveSheet.show(
      context,
      result: r,
      season: widget.beamEpisode?.season,
      episode: widget.beamEpisode?.episode,
      storyConstraint:
          widget.beamEpisode?.storyConstraint ??
          (widget.metadata == null ? null : BeamEpisodeIdentity.fromMetadata(widget.metadata!)?.storyConstraint),
      playbackDuration: BeamPlaybackDuration.fromMetadata(
        widget.metadata ?? widget.beamEpisode?.metadata,
        episodeQueue: widget.beamEpisode?.episodeQueue ?? const [],
      ),
      onPlayResolved: (playback) async {
        final url = playback.url;
        final playerEpisode = widget.beamEpisode?.forSelectedFile(playback.selectedFilename);
        final title = widget.beamEpisode?.displayTitle ?? widget.metadata?.title ?? r.title;
        final infoHash = r.infoHash;
        final magnet = playback.magnet;
        if (!mounted || originRoute?.isCurrent == false) return false;
        // Record the title in the local Beam library and look up its resume
        // position (keyed by info-hash) BEFORE opening the player.
        int? resumeMs;
        if (widget.beamEpisode != null || (infoHash != null && infoHash.isNotEmpty)) {
          final lib = BeamLibraryService(context.read<AppDatabase>());
          await lib.recordPlayed(
            infoHash: infoHash ?? '',
            episode: widget.beamEpisode,
            title: widget.beamEpisode?.displayTitle ?? widget.metadata?.title ?? title,
            posterUrl: widget.metadata?.thumbPath,
            magnet: magnet,
            quality: ReleaseQuality.parse(r.title).label,
            sizeBytes: r.size,
          );
          final resume = await lib.resumeFor(widget.beamEpisode?.contentKey ?? infoHash ?? '');
          resumeMs = resume?.inMilliseconds;
        }
        if (!mounted || originRoute?.isCurrent == false) return false;
        final playerClosed = Navigator.of(context).push(
          buildVideoPlayerRoute(
            builder: (_) => VideoPlayerScreen.direct(
              url: url,
              onPlaybackStarted: playback.commitPlayback,
              onPlaybackFailed: playback.cancel,
              playbackNotice: playback.episodePlaybackNotice(widget.beamEpisode?.season),
              title: title,
              beamInfoHash: infoHash,
              beamEpisode: playerEpisode,
              metadata: widget.metadata,
              beamResumeMs: resumeMs,
            ),
          ),
        );
        unawaited(
          playerClosed.whenComplete(() {
            playback.cancel();
            return TorrentStreamService.instance.stopUrl(url);
          }),
        );
        return true;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Beam'), actions: widget.appBarActions),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _controller,
              focusNode: _searchFocus,
              // Only grab focus when the user actually came here to type. When
              // the screen is opened with a pre-seeded query (from the poster
              // detail page) the results are what matters — autofocusing the
              // field there traps D-pad input in the text box and pops the
              // on-screen keyboard over the list, so the remote can't reach the
              // play buttons at all. Never autofocus on TV either: focusing a
              // TextField pops the on-screen keyboard over the whole list the
              // moment the screen opens, which reads as "the remote is dead".
              autofocus: widget.initialQuery == null && !PlatformDetector.isTV(),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _runSearch(),
              decoration: InputDecoration(
                hintText: 'Search movies & TV...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _controller,
                  builder: (context, value, _) => IconButton(
                    tooltip: value.text.isEmpty ? 'Search' : 'Clear search',
                    icon: Icon(value.text.isEmpty ? Icons.arrow_forward : Icons.clear),
                    onPressed: value.text.isEmpty ? _runSearch : _clearSearch,
                  ),
                ),
                filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            // Only the LEFTMOST chip escapes to the rail — otherwise LEFT could
            // never move between chips.
            child: _leftEscape(
              shouldEscape: () => _firstChipFocus.hasFocus,
              child: Row(
                children: [
                  for (final c in BeamCategory.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(c.label),
                        selected: _category == c,
                        focusNode: c == BeamCategory.values.first ? _firstChipFocus : null,
                        onSelected: (_) => _onCategory(c),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // The results are a single vertical column, so LEFT has no meaning
          // inside it — any LEFT goes straight to the rail.
          Expanded(
            child: _leftEscape(shouldEscape: () => true, child: _buildBody(theme)),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _StateMessage(
        icon: Icons.error_outline,
        title: 'Search failed',
        subtitle: _error,
        action: FilledButton(onPressed: _runSearch, child: const Text('Retry')),
      );
    }
    if (!_searched) {
      return const _StateMessage(
        icon: Icons.travel_explore,
        title: 'Search for something to Beam',
        subtitle: 'Find a movie or show, then stream it instantly.',
      );
    }
    if (_results.isEmpty) {
      return const _StateMessage(
        icon: Icons.search_off,
        title: 'No results',
        subtitle: 'Try a different title or spelling.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: _groups.length,
      itemBuilder: (context, i) => _GroupCard(
        group: _groups[i],
        autofocus: i == 0,
        onAutoPlay: () => _autoPlayGroup(_groups[i]),
        onPickSource: _openResult,
      ),
    );
  }
}

/// A cluster of sources for the SAME movie/episode, best source first.
class _ReleaseGroup {
  _ReleaseGroup({required this.displayTitle, required this.sources});

  /// A cleaned, human title shared by the whole cluster (year kept, quality/
  /// codec/release tokens stripped).
  final String displayTitle;

  /// All sources for this title, sorted best-first (seeders then quality).
  final List<ProwlarrResult> sources;

  /// The top source — used for the poster-less card's headline quality badge.
  ProwlarrResult get best => sources.first;

  int get totalSeeders => sources.fold(0, (sum, s) => sum + (s.seeders < 0 ? 0 : s.seeders));
}

/// Normalizes a release title to a grouping key: lowercase, drop everything
/// from the resolution/quality marker onward, collapse separators. e.g.
/// "The Matrix 1999 2160p UHD BluRay x265-GRP" -> "the matrix 1999".
String _groupKey(String title) {
  var t = title.toLowerCase();
  // Cut at the first quality/source/codec marker — everything after it is
  // release metadata, not part of the movie identity.
  final cut = RegExp(
    r'\b(2160p|1440p|1080p|720p|480p|4k|uhd|bluray|blu-ray|bdrip|brrip|'
    r'web-?dl|web-?rip|webrip|hdtv|dvdrip|dvd|remux|x264|x265|hevc|h\.?26[45]|'
    r'av1|hdr|dts|ddp?5|aac|atmos|cam|hdcam|telesync)\b',
  );
  final m = cut.firstMatch(t);
  if (m != null) t = t.substring(0, m.start);
  // Strip release separators/punctuation, collapse whitespace.
  t = t.replaceAll(RegExp(r'[._\-\(\)\[\]]+'), ' ');
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t;
}

/// A cleaned display title for the group (title-cased-ish: just the key with
/// original casing where possible). We reuse the shortest source title's prefix.
String _displayTitleFor(String key) {
  if (key.isEmpty) return 'Unknown title';
  // Capitalize each word for a tidy headline.
  return key.split(' ').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
}

/// Groups raw results by normalized title, sorts each group's sources best-first
/// (seeders desc, then quality rank desc), and orders groups by their best
/// source's seeders so the most-available movie leads.
List<_ReleaseGroup> _groupByTitle(List<ProwlarrResult> results) {
  final map = <String, List<ProwlarrResult>>{};
  for (final r in results) {
    final key = _groupKey(r.title);
    (map[key] ??= <ProwlarrResult>[]).add(r);
  }
  final groups = <_ReleaseGroup>[];
  map.forEach((key, sources) {
    sources.sort((a, b) {
      final s = b.seeders.compareTo(a.seeders);
      if (s != 0) return s;
      return ReleaseQuality.parse(b.title).rank.compareTo(ReleaseQuality.parse(a.title).rank);
    });
    groups.add(_ReleaseGroup(displayTitle: _displayTitleFor(key), sources: sources));
  });
  groups.sort((a, b) => b.best.seeders.compareTo(a.best.seeders));
  return groups;
}

/// One clean card per movie/title: headline, the best-source quality badge,
/// a big one-tap "Play best" action, and an expandable list of other sources
/// for power users.
class _GroupCard extends StatefulWidget {
  const _GroupCard({required this.group, required this.onAutoPlay, required this.onPickSource, this.autofocus = false});

  final _ReleaseGroup group;
  final VoidCallback onAutoPlay;
  final void Function(ProwlarrResult) onPickSource;
  final bool autofocus;

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final autofocus = widget.autofocus;
    final onAutoPlay = widget.onAutoPlay;
    final onPickSource = widget.onPickSource;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final best = group.best;
    final quality = ReleaseQuality.parse(best.title);
    final goodSeeds = best.seeders > 50;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      // Visible focus ring: on a TV the remote gives no pointer, so without an
      // obvious highlight the screen feels like it isn't responding to input.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: _focused ? cs.primary : Colors.transparent, width: 3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            autofocus: autofocus,
            onFocusChange: (f) => setState(() => _focused = f),
            onTap: onAutoPlay,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Row(
                children: [
                  // Poster-less: indexers carry no artwork, so use a tidy
                  // placeholder tile instead of a broken image.
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(10)),
                    child: Icon(Icons.movie_outlined, color: cs.onPrimaryContainer),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.displayTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _Badge(
                              text: 'Auto · ${quality.label}',
                              color: cs.primaryContainer,
                              textColor: cs.onPrimaryContainer,
                            ),
                            _MetaChip(
                              icon: Icons.groups,
                              text: '${best.seeders}',
                              color: goodSeeds ? Colors.green : cs.onSurfaceVariant,
                            ),
                            _MetaChip(icon: Icons.layers, text: '${group.sources.length} sources'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.play_circle_fill, size: 34, color: cs.primary),
                ],
              ),
            ),
          ),
          if (group.sources.length > 1)
            Theme(
              // Remove the divider lines ExpansionTile draws by default.
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                childrenPadding: const EdgeInsets.only(bottom: 4),
                title: Text(
                  'Other sources & qualities',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                children: [for (final s in group.sources) _ResultRow(result: s, onTap: () => onPickSource(s))],
              ),
            ),
        ],
      ),
    );
  }
}

/// A single search result row: title, quality badge, size, seeders, source.
class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.result, required this.onTap});

  final ProwlarrResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quality = ReleaseQuality.parse(result.title);
    final goodSeeds = result.seeders > 50;
    return InkWell(
      onTap: onTap,
      autofocus: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(result.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Badge(
                  text: quality.label,
                  color: theme.colorScheme.primaryContainer,
                  textColor: theme.colorScheme.onPrimaryContainer,
                ),
                _MetaChip(icon: Icons.sd_storage, text: result.sizeHuman),
                _MetaChip(
                  icon: Icons.groups,
                  text: '${result.seeders}',
                  color: goodSeeds ? Colors.green : theme.colorScheme.onSurfaceVariant,
                ),
                _MetaChip(icon: Icons.dns, text: result.indexer),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color, required this.textColor});
  final String text;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
    child: Text(
      text,
      style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.text, this.color});
  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(color: c, fontSize: 12)),
      ],
    );
  }
}

class _StateMessage extends StatelessWidget {
  const _StateMessage({required this.icon, required this.title, this.subtitle, this.action});

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 72, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}
