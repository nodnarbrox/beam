import 'dart:async';

import 'package:plezy/widgets/network_artwork.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_action_bar.dart';
import '../media_detail_screen.dart';
import '../../services/beam/show_episode_catalog.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/ids.dart';
import '../../media/media_server_client.dart';
import '../../providers/multi_server_provider.dart';
import '../../utils/media_image_helper.dart';
import '../../widgets/optimized_media_image.dart';
import '../../services/catalog/catalog_library_matcher.dart';
import '../../utils/app_logger.dart';
import '../../utils/media_navigation_helper.dart';
import '../../utils/video_player_navigation.dart';
import '../../services/beam/beam_episode_identity.dart';
import '../../services/beam/episode_source_probe.dart';
import '../../services/beam/beam_fallback.dart';
import '../../services/beam/plex_public_discover.dart';

/// Plex-style detail page for a discovered title: backdrop + poster, synopsis,
/// Rotten Tomatoes critic + audience scores, runtime/rating, cast row, and a
/// big "Stream" button that hands the title to the source search + play flow
/// (torrent-first; Real-Debrid only when configured — decided downstream).
class BeamDetailScreen extends StatefulWidget {
  const BeamDetailScreen({
    super.key,
    required this.item,
    this.discover,
    this.libraryMatcher,
    this.playLibraryItem,
    this.showEpisodeCatalog,
  });
  final BeamDiscoverItem item;
  final PlexPublicDiscover? discover;
  final CatalogLibraryMatcher? libraryMatcher;
  final ShowEpisodeCatalog? showEpisodeCatalog;
  @visibleForTesting
  final Future<void> Function(BuildContext, MediaItem)? playLibraryItem;

  @override
  State<BeamDetailScreen> createState() => _BeamDetailScreenState();
}

class _BeamDetailScreenState extends State<BeamDetailScreen> {
  late final _discover = widget.discover ?? PlexPublicDiscover();
  late final Future<List<MediaItem>> _libraryMatches;
  List<MediaItem> _matches = const [];
  CatalogLibraryMatcher? _matchedUsing;
  String? _artworkIdentity;
  bool _launching = false;
  BeamDiscoverDetail? _detail;
  bool _loading = true;

  bool get _isShow => widget.item.kind == MediaKind.show;
  String get _artworkKey => '${widget.item.toCatalogItem().identityKey}|${widget.item.title}|${widget.item.year}';

  /// Seasons for a show (empty for movies / when discover children fail).
  List<BeamSeason> _seasons = const [];
  bool _seasonsLoading = false;

  @override
  void initState() {
    super.initState();
    _libraryMatches = _matchLibrary();
    if (!_isShow) _load();
  }

  Future<List<MediaItem>> _matchLibrary() async {
    try {
      final matcher = widget.libraryMatcher ?? context.read<CatalogLibraryMatcher?>();
      _matchedUsing = matcher;
      _artworkIdentity = _artworkKey;
      final matches =
          await matcher?.match(widget.item.toCatalogItem()).timeout(const Duration(seconds: 15)) ?? const <MediaItem>[];
      // Only genuine server items may enter the normal library player.
      final playable = matches
          .where((item) => item.serverId?.isNotEmpty == true && item.kind == widget.item.kind)
          .toList();
      if (mounted) setState(() => _matches = playable);
      return playable;
    } catch (error, stack) {
      appLogger.w('Discover library lookup unavailable', error: error, stackTrace: stack);
      return const [];
    }
  }

  Future<void> _load() async {
    BeamDiscoverDetail? d;
    try {
      d = await _discover.detail(widget.item);
    } catch (error, stack) {
      appLogger.w('Discover detail unavailable', error: error, stackTrace: stack);
    }
    if (!mounted) return;
    setState(() {
      _detail = d ?? BeamDiscoverDetail(item: widget.item);
      _loading = false;
    });
    if (_isShow) unawaited(_loadSeasons());
  }

  Future<void> _loadSeasons() async {
    final rk = widget.item.ratingKey;
    if (rk == null || rk.isEmpty) return;
    setState(() => _seasonsLoading = true);
    final s = await _discover.seasons(rk, fallbackSeasonCount: widget.item.seasonCount);
    if (!mounted) return;
    setState(() {
      _seasons = s;
      _seasonsLoading = false;
    });
  }

  /// Play a specific episode via Beam (no torrent list shown).
  void _streamEpisode(int season, int episode, List<int> foundEpisodes) {
    final item = widget.item;
    final showId =
        item.guid ??
        (item.ratingKey == null
            ? BeamEpisodeIdentity.titleShowId(item.title, item.year)
            : 'plex:discover:${item.ratingKey}');
    final queue = [
      for (final s in _seasons)
        for (final e
            in s.episodeCount > 0
                ? List.generate(s.episodeCount, (i) => i + 1)
                : (s.seasonNumber == season ? foundEpisodes : <int>[]))
          BeamEpisodeIdentity(
            showId: showId,
            showTitle: item.title,
            season: s.seasonNumber,
            episode: e,
            year: item.year,
          ).playerMetadata,
    ];
    final identity = BeamEpisodeIdentity(
      showId: showId,
      showTitle: item.title,
      season: season,
      episode: episode,
      year: item.year,
      episodeQueue: queue,
    );
    unawaited(
      BeamFallback.playByTitle(
        context,
        title: widget.item.title,
        year: widget.item.year,
        kind: MediaKind.episode,
        season: season,
        episode: episode,
        beamEpisode: identity,
      ),
    );
  }

  /// One-tap silent play: find the best source for this title and start it,
  /// WITHOUT ever showing the torrent list. Falls back to the manual source
  /// picker only if nothing auto-resolves (handled inside BeamFallback).
  Future<void> _stream() async {
    if (_launching) return;
    setState(() => _launching = true);
    try {
      final matches = await _libraryMatches;
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
      if (matches.isNotEmpty) {
        final item = matches.first;
        if (widget.playLibraryItem case final play?) {
          await play(context, item);
        } else if (item.kind == MediaKind.movie) {
          await navigateToVideoPlayer(context, metadata: item);
        } else {
          await navigateToMediaItemDetails(context, item);
        }
        return;
      }
      await BeamFallback.playByTitle(
        context,
        title: widget.item.title,
        year: widget.item.year,
        kind: widget.item.kind,
        metadata: widget.item.toCatalogItem(detail: _detail).toMediaItem(),
      );
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isShow) {
      return FutureBuilder<List<MediaItem>>(
        future: _libraryMatches,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          final matches = snapshot.data ?? const <MediaItem>[];
          return MediaDetailScreen(
            key: ValueKey(matches.isEmpty ? widget.item.guid ?? widget.item.title : matches.first.globalKey),
            metadata: matches.isEmpty ? widget.item.toCatalogItem().toMediaItem() : matches.first,
            discoverItem: widget.item,
            discover: _discover,
            showEpisodeCatalog: widget.showEpisodeCatalog,
          );
        },
      );
    }
    final theme = Theme.of(context);
    final item = widget.item;
    final d = _detail;
    final matcher = widget.libraryMatcher ?? context.watch<CatalogLibraryMatcher?>();
    final servers = context.watch<MultiServerProvider?>();
    MediaItem? libraryArtwork;
    MediaServerClient? artworkClient;
    if (identical(matcher, _matchedUsing) && _artworkIdentity == _artworkKey && servers != null) {
      for (final match in _matches) {
        final id = match.serverId;
        if (id == null || !servers.onlineServerIds.contains(id)) continue;
        final client = servers.getClientForServer(ServerId(id));
        if (client == null || client.isOfflineMode) continue;
        libraryArtwork = match;
        artworkClient = client;
        break;
      }
    }

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 300,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background: _backdrop(theme, d?.artUrl ?? item.posterUrl, libraryArtwork, artworkClient),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _headerRow(theme, item, d, libraryArtwork, artworkClient),
                  const SizedBox(height: 16),
                  // Movies get one-tap Stream; shows get a season/episode
                  // browser (episodes are gated on findability below).
                  if (!_isShow || _matches.isNotEmpty) _streamButton(theme),
                  const SizedBox(height: 20),
                  if (_isShow) ...[_seasonsSection(theme), const SizedBox(height: 20)],
                  if (_loading)
                    const Center(
                      child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
                    )
                  else ...[
                    if (d?.tagline != null && d!.tagline!.isNotEmpty) ...[
                      Text(
                        d.tagline!,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (item.overview != null && item.overview!.isNotEmpty)
                      Text(item.overview!, style: theme.textTheme.bodyLarge?.copyWith(height: 1.4)),
                    const SizedBox(height: 24),
                    if (d != null && d.cast.isNotEmpty) _castRow(theme, d),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _seasonsSection(ThemeData theme) {
    if (_seasonsLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_seasons.isEmpty) {
      // A verified library show already has its Play action in the header.
      // Do not add a second action (and competing autofocus) below it.
      if (_matches.isNotEmpty) return const SizedBox.shrink();
      // No season data (or discover children unavailable) — offer a plain
      // Stream so the show is never a dead end; it searches the series.
      return _streamButton(theme);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Episodes', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        for (final s in _seasons) _SeasonTile(show: widget.item.title, season: s, onPlay: _streamEpisode),
      ],
    );
  }

  Widget _artwork({
    required ThemeData theme,
    required String? fallbackUrl,
    required String? libraryPath,
    required MediaServerClient? client,
    ImageType type = ImageType.poster,
    double? width,
    double? height,
  }) {
    Widget fallback() => fallbackUrl?.isNotEmpty == true
        ? NetworkArtwork(
            imageUrl: fallbackUrl!,
            width: width,
            height: height,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(color: theme.colorScheme.surfaceContainerHighest),
          )
        : Container(color: theme.colorScheme.surfaceContainerHighest);
    if (client == null || libraryPath?.isNotEmpty != true) return fallback();
    return OptimizedMediaImage(
      client: client,
      imagePath: libraryPath,
      imageType: type,
      width: width,
      height: height,
      fit: BoxFit.cover,
      errorWidget: (_, _, _) => fallback(),
    );
  }

  Widget _backdrop(ThemeData theme, String? url, MediaItem? library, MediaServerClient? client) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _artwork(theme: theme, fallbackUrl: url, libraryPath: library?.artPath, client: client, type: ImageType.art),
        // Scrim so title text stays readable.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black87],
            ),
          ),
        ),
      ],
    );
  }

  Widget _headerRow(
    ThemeData theme,
    BeamDiscoverItem item,
    BeamDiscoverDetail? d,
    MediaItem? library,
    MediaServerClient? client,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 100,
            height: 150,
            child: _artwork(
              theme: theme,
              fallbackUrl: item.posterUrl,
              libraryPath: library?.thumbPath,
              client: client,
              width: 100,
              height: 150,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${item.title}${item.year != null ? ' (${item.year})' : ''}',
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (d?.contentRating != null) _pill(theme, d!.contentRating!),
                  if (d?.durationMinutes != null) Text('${d!.durationMinutes} min', style: theme.textTheme.bodyMedium),
                  if (item.kind == MediaKind.show) Text('TV', style: theme.textTheme.bodyMedium),
                ],
              ),
              const SizedBox(height: 10),
              _ratings(theme, d),
              if (d != null && d.genres.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  d.genres.take(3).join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              if (d != null && d.directors.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Dir: ${d.directors.take(2).join(', ')}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _ratings(ThemeData theme, BeamDiscoverDetail? d) {
    if (d == null) return const SizedBox.shrink();
    final chips = <Widget>[];
    if (d.criticPercent != null) {
      chips.add(
        _ratingChip(
          theme,
          icon: d.criticIsRottenTomatoes ? '🍅' : '★',
          label: '${d.criticPercent}%',
          sub: d.criticIsRottenTomatoes ? 'Critics' : 'Rating',
        ),
      );
    }
    if (d.audiencePercent != null) {
      chips.add(_ratingChip(theme, icon: '🍿', label: '${d.audiencePercent}%', sub: 'Audience'));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 16, children: chips);
  }

  Widget _ratingChip(ThemeData theme, {required String icon, required String label, required String sub}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(icon, style: const TextStyle(fontSize: 20)),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            Text(sub, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ],
    );
  }

  Widget _pill(ThemeData theme, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      border: Border.all(color: theme.colorScheme.outline),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(text, style: theme.textTheme.labelMedium),
  );

  Widget _streamButton(ThemeData theme) {
    return FocusableActionBar(
      onBack: () => Navigator.of(context).maybePop(),
      actions: [
        FocusableAction(
          autofocus: true,
          debugLabel: 'discover_detail_play',
          tooltip: 'Play',
          onPressed: _launching ? null : () => unawaited(_stream()),
          child: TextButton.icon(
            onPressed: _launching ? null : () => unawaited(_stream()),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(_launching ? 'Opening…' : 'Play'),
          ),
        ),
      ],
    );
  }

  Widget _castRow(ThemeData theme, BeamDiscoverDetail d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Cast', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: d.cast.length.clamp(0, 20),
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final c = d.cast[i];
              return SizedBox(
                width: 84,
                child: Column(
                  children: [
                    ClipOval(
                      child: SizedBox(
                        width: 72,
                        height: 72,
                        child: c.thumbUrl != null
                            ? NetworkArtwork(
                                imageUrl: c.thumbUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (context, url, error) => _avatarFallback(theme),
                              )
                            : _avatarFallback(theme),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      c.name,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    if (c.role != null)
                      Text(
                        c.role!,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _avatarFallback(ThemeData theme) => Container(
    color: theme.colorScheme.surfaceContainerHighest,
    child: Icon(Icons.person, color: theme.colorScheme.onSurfaceVariant),
  );
}

/// Known episode counts come from metadata. Search results are source hints;
/// a season pack never establishes how many episodes a show contains.
class _SeasonTile extends StatefulWidget {
  const _SeasonTile({required this.show, required this.season, required this.onPlay});

  final String show;
  final BeamSeason season;
  final void Function(int season, int episode, List<int> foundEpisodes) onPlay;

  @override
  State<_SeasonTile> createState() => _SeasonTileState();
}

class _SeasonTileState extends State<_SeasonTile> {
  bool _probed = false;
  bool _probing = false;
  List<int> _found = const [];

  final _availability = <int, EpisodeSourceAvailability>{};

  Future<void> _probe() async {
    if (_probed || _probing || widget.season.episodeCount <= 0) return;
    setState(() => _probing = true);
    final total = widget.season.episodeCount;
    const batch = 4;
    for (var start = 1; start <= total; start += batch) {
      final end = (start + batch - 1).clamp(1, total);
      final results = await Future.wait([
        for (var ep = start; ep <= end; ep++)
          BeamFallback.episodeSourceAvailability(
            show: widget.show,
            season: widget.season.seasonNumber,
            episode: ep,
          ).then((status) => (ep, status)),
      ]);
      if (!mounted) return;
      setState(() {
        for (final result in results) {
          _availability[result.$1] = result.$2;
        }
        _found = _availability.keys.toList()..sort();
      });
    }
    if (!mounted) return;
    setState(() {
      _probed = true;
      _probing = false;
    });
  }

  Future<void> _chooseEpisode() async {
    int? episode;
    final formKey = GlobalKey<FormState>();
    final chosen = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Choose episode'),
        content: Form(
          key: formKey,
          child: TextFormField(
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Episode number'),
            validator: (value) => (int.tryParse(value ?? '') ?? 0) > 0 ? null : 'Enter an episode number',
            onSaved: (value) => episode = int.parse(value!),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                formKey.currentState!.save();
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('Stream'),
          ),
        ],
      ),
    );
    if (chosen == true && mounted) widget.onPlay(widget.season.seasonNumber, episode!, [episode!]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: Text('Season ${widget.season.seasonNumber}'),
        subtitle: widget.season.episodeCount > 0
            ? Text(
                '${widget.season.episodeCount} episodes',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              )
            : null,
        onExpansionChanged: (open) {
          if (open) unawaited(_probe());
        },
        children: [
          if (widget.season.episodeCount <= 0)
            ListTile(
              title: const Text('Choose episode'),
              subtitle: const Text('Episode list unavailable'),
              leading: const Icon(Icons.play_circle_outline),
              onTap: _chooseEpisode,
            ),
          if (_probing && _found.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('Checking which episodes can stream…'),
                ],
              ),
            )
          else if (_probed && _found.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('No streamable episodes found for this season.')),
          for (final ep in _found)
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: Text('Episode $ep'),
              subtitle: Text(switch (_availability[ep]) {
                EpisodeSourceAvailability.candidate => 'Source found; episode verified when played',
                EpisodeSourceAvailability.unavailable => 'No source found',
                _ => 'Source check unavailable',
              }),
              onTap: () => widget.onPlay(widget.season.seasonNumber, ep, List.of(_found)),
            ),
          if (_probing && _found.isNotEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            ),
        ],
      ),
    );
  }
}
