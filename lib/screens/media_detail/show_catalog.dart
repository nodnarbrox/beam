part of '../media_detail_screen.dart';

extension _MediaDetailShowCatalog on _MediaDetailScreenState {
  PlexCatalogSource? get _currentEpisodeArtworkSource => Provider.of<CatalogSourcesProvider?>(
    context,
    listen: false,
  )?.connectedSources.whereType<PlexCatalogSource>().firstOrNull;

  MediaItem _withPlexEpisodeArtwork(MediaItem episode) {
    if (!isCatalogEpisode(episode) || !identical(_episodeArtworkSource, _currentEpisodeArtworkSource)) return episode;
    final image = _plexEpisodeImages[episode.raw?['tvmazeEpisodeId']];
    return image == null ? episode : episode.copyWith(thumbPath: image);
  }

  Future<void> _loadPlexEpisodeArtwork(MediaItem season) async {
    final catalog = _showCatalog;
    final number = season.index;
    if (!mounted || widget.isOffline || catalog == null || number == null) return;
    final source = _currentEpisodeArtworkSource;
    if (source == null) return;
    if (!identical(source, _episodeArtworkSource)) {
      _episodeArtworkSource = source;
      _plexEpisodeImages.clear();
      _episodeArtworkLoaded.clear();
    }
    final request = (source, number);
    if (_episodeArtworkLoaded.contains(number) || !_episodeArtworkPending.add(request)) return;
    final showId = _metadata.id;
    try {
      final images = await source.episodeArtwork(
        catalog: catalog,
        plexShowId: widget.discoverItem?.ratingKey,
        seasonNumber: number,
      );
      if (!mounted ||
          _metadata.id != showId ||
          !identical(_showCatalog, catalog) ||
          !identical(_currentEpisodeArtworkSource, source)) {
        return;
      }
      // Empty/error results remain retryable when this season is revisited.
      if (images.isEmpty) return;
      setStateIfMounted(() {
        _episodeArtworkLoaded.add(number);
        _plexEpisodeImages.addAll(images);
        for (final episode in catalog.episodes.where((e) => e.seasonNumber == number)) {
          _seasonEpisodePager.patchEpisode('tvmaze:episode:${episode.id}', _withPlexEpisodeArtwork);
        }
        _episodes = _episodes.map(_withPlexEpisodeArtwork).toList();
        if (_tvSelectedPlayEpisode case final episode?) _tvSelectedPlayEpisode = _withPlexEpisodeArtwork(episode);
        if (_onDeckEpisode case final episode?) _onDeckEpisode = _withPlexEpisodeArtwork(episode);
      });
    } catch (_) {
      // Optional artwork must never prevent listing or playing an episode.
    } finally {
      _episodeArtworkPending.remove(request);
    }
  }

  MediaItem? get _primaryPlayEpisode => (PlatformDetector.isTV() ? _tvSelectedPlayEpisode : null) ?? _onDeckEpisode;

  Future<ShowEpisodeCatalogResult?> _loadShowCatalog() {
    if (widget.isOffline || !_metadata.isShow) return Future.value(null);
    return _showCatalogLoad ??= (() async {
      final show = _fullMetadata ?? _metadata;
      try {
        final result = await (widget.showEpisodeCatalog ?? ShowEpisodeCatalog.instance).load(
          title: show.title ?? widget.discoverItem?.title ?? '',
          year: show.year ?? widget.discoverItem?.year,
        );
        if (mounted) {
          _showCatalog = result;
          _showCatalogFailed = result == null;
        }
        return result;
      } catch (error, stack) {
        appLogger.w('Complete episode catalog unavailable', error: error, stackTrace: stack);
        if (mounted) _showCatalogFailed = true;
        return null;
      }
    })();
  }

  List<MediaItem> _mergeCatalogEpisodes(MediaItem season, List<MediaItem> libraryEpisodes) {
    final catalog = _showCatalog;
    if (catalog == null || widget.isOffline) return libraryEpisodes;
    final merged = mergeShowCatalog(
      show: _fullMetadata ?? _metadata,
      catalog: catalog,
      librarySeasons: _seasons,
      libraryEpisodes: libraryEpisodes,
    );
    _catalogConflictedSeasons.remove(season.index);
    _catalogConflictedSeasons.addAll(merged.conflictedSeasons);
    return merged.episodes
        .where((episode) => episode.parentIndex == season.index)
        .map(_withPlexEpisodeArtwork)
        .toList();
  }

  Future<LibraryPage<MediaItem>> _fetchCatalogSeasonPage(MediaServerClient? client, MediaItem season) async {
    if (isCatalogSeason(season)) {
      final episodes = _mergeCatalogEpisodes(season, const []);
      return LibraryPage(items: episodes, totalCount: episodes.length);
    }
    if (client == null) return const LibraryPage(items: [], totalCount: 0);
    final page = await fetchSeasonEpisodePage(
      client,
      show: _metadata,
      season: season,
      start: 0,
      size: _MediaDetailScreenState._episodesPageSize,
    );
    // Keep server pagination intact. Add missing catalog rows only once all
    // server rows in this season have arrived, so unseen pages cannot collide.
    if (page.items.length < page.totalCount) return page;
    final episodes = _mergeCatalogEpisodes(season, page.items);
    return LibraryPage(items: episodes, totalCount: episodes.length);
  }

  void _applyCatalogSupplement() {
    final catalog = _showCatalog;
    if (catalog == null || !mounted || widget.isOffline) return;
    final selectedId = _selectedSeasonIndex >= 0 && _selectedSeasonIndex < _seasons.length
        ? _seasons[_selectedSeasonIndex].id
        : null;
    final seasons = mergeShowCatalog(
      show: _fullMetadata ?? _metadata,
      catalog: catalog,
      librarySeasons: _seasons,
    ).seasons;
    _updateSeasonTabFocusNodes(seasons.length);
    setStateIfMounted(() {
      _seasons = seasons;
      final previousIndex = seasons.indexWhere((season) => season.id == selectedId);
      _selectedSeasonIndex = previousIndex >= 0 ? previousIndex : _findOnDeckSeasonIndex(seasons);
      _showEpisodesDirectly = false;
      _seasonsLoadFailed = false;
      _hasLoadedSeasons = true;
      for (final season in seasons) {
        final cached = _seasonEpisodePager.stateFor(season.id);
        if (_seasonEpisodePager.hasState(season.id) &&
            !cached.isInitialLoading &&
            !cached.initialLoadFailed &&
            !cached.hasMore) {
          final merged = _mergeCatalogEpisodes(season, cached.items);
          _seasonEpisodePager.completeFirstPage(season.id, merged, merged.length);
        }
      }
      _episodes = seasons.isEmpty ? [] : List.of(_selectedSeasonEpisodeState.items);
    });
    if (seasons.isNotEmpty) {
      unawaited(
        _fetchSeasonEpisodes(_selectedSeasonIndex).then((_) {
          if (mounted) _ensureFallbackOnDeckEpisode();
        }),
      );
    }
  }

  bool _catalogEpisodeIsFuture(MediaItem episode) {
    if (!isCatalogEpisode(episode)) return false;
    final date = DateTime.tryParse(episode.raw?['catalogAirStamp'] as String? ?? episode.originallyAvailableAt ?? '');
    return date != null && date.isAfter(DateTime.now());
  }

  MediaItem _withCurrentShowAliases(MediaItem episode) {
    final catalog = _showCatalog;
    if (catalog == null || !isCatalogEpisode(episode) || episode.raw?['tvmazeShowId'] != catalog.tvmazeId) {
      return episode;
    }
    final evidence = catalog.numberingEvidence[episode.raw?['tvmazeEpisodeId']];
    final raw = {...?episode.raw}..remove('beamNumberingEvidence');
    if (catalog.aliasesComplete) raw['beamShowAliases'] = catalog.aliases;
    if (evidence != null) raw['beamNumberingEvidence'] = evidence.toRaw();
    return episode.copyWith(raw: raw);
  }

  Future<void> _playDetailEpisode(MediaItem episode) async {
    final catalogEpisode = isCatalogEpisode(episode);
    if (!catalogEpisode && (widget.isOffline || _showCatalog == null)) {
      await navigateToVideoPlayerWithRefresh(
        context,
        metadata: episode,
        isOffline: widget.isOffline,
        onRefresh: () => unawaited(_refreshItemInPlace(episode)),
      );
      return;
    }
    if (_catalogEpisodeIsFuture(episode)) {
      showAppSnackBar(context, 'This episode has not aired yet.');
      return;
    }
    final catalog = _showCatalog;
    if (catalogEpisode && catalog != null && !catalog.aliasesComplete) {
      final originRoute = ModalRoute.of(context);
      final refreshed = await (widget.showEpisodeCatalog ?? ShowEpisodeCatalog.instance).retryAliases(catalog);
      if (!mounted || !(originRoute?.isCurrent ?? false)) return;
      // Retry is keyed by the already verified ID, never a new fuzzy lookup.
      if (refreshed.tvmazeId == catalog.tvmazeId) _showCatalog = refreshed;
    }
    final currentCatalog = _showCatalog;
    if (catalogEpisode && currentCatalog != null && !currentCatalog.numberingChecked) {
      final originRoute = ModalRoute.of(context);
      final verified = await (widget.showEpisodeCatalog ?? ShowEpisodeCatalog.instance).verifyNumbering(currentCatalog);
      if (!mounted || !(originRoute?.isCurrent ?? false)) return;
      if (verified.tvmazeId == currentCatalog.tvmazeId) _showCatalog = verified;
    }
    episode = _withCurrentShowAliases(episode);
    final identity = BeamEpisodeIdentity.fromMetadata(episode);
    if (identity == null) {
      if (!catalogEpisode) {
        await navigateToVideoPlayerWithRefresh(
          context,
          metadata: episode,
          isOffline: widget.isOffline,
          onRefresh: () => unawaited(_refreshItemInPlace(episode)),
        );
        return;
      }
      showErrorSnackBar(context, 'The episode number could not be verified.');
      return;
    }
    // Only already merged, compatible season lists enter next-episode playback.
    final byEpisode = <String, MediaItem>{};
    for (final season in _seasons) {
      for (final item in _seasonEpisodePager.stateFor(season.id).items) {
        final key = catalogEpisodeKey(item);
        if (key == null || _catalogEpisodeIsFuture(item)) continue;
        if (!byEpisode.containsKey(key) || (byEpisode[key]!.serverId == null && item.serverId != null)) {
          byEpisode[key] = _withCurrentShowAliases(item);
        }
      }
    }
    final queued = BeamEpisodeIdentity(
      showId: identity.showId,
      showTitle: identity.showTitle,
      season: identity.season,
      episode: identity.episode,
      year: (_fullMetadata ?? _metadata).year ?? identity.year,
      metadata: episode,
      episodeQueue: byEpisode.values.toList(),
    );
    if (!catalogEpisode) {
      // Preserve normal server playback, saved versions and refresh while
      // carrying the merged queue so missing catalog episodes are not skipped.
      await navigateToVideoPlayerWithRefresh(
        context,
        metadata: episode,
        beamEpisode: queued,
        isOffline: widget.isOffline,
        onRefresh: () => unawaited(_refreshItemInPlace(episode)),
      );
      return;
    }
    if (widget.playCatalogEpisode case final play?) {
      await play(context, queued);
      return;
    }
    await BeamFallback.playByTitle(
      context,
      title: queued.showTitle,
      year: queued.year,
      kind: MediaKind.episode,
      season: queued.season,
      episode: queued.episode,
      beamEpisode: queued,
      metadata: episode,
    );
  }

  Widget _catalogAttribution() {
    final catalog = _showCatalog;
    if (catalog == null && !_showCatalogFailed) return const SizedBox.shrink();
    final failed = _showCatalogFailed;
    return TextButton(
      key: const ValueKey('show_episode_catalog_attribution'),
      style: TextButton.styleFrom(foregroundColor: Colors.white70, backgroundColor: Colors.black54),
      onPressed: () async {
        if (failed) {
          _showCatalogLoad = null;
          _showCatalogFailed = false;
          await _loadSeasons();
          return;
        }
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Episode information'),
            content: Text(
              'Episode information from TVmaze. Listed episodes are checked for a playable source when selected.'
              '${_catalogConflictedSeasons.isEmpty ? '' : '\nSome library episode numbers differ from the catalog. Those seasons retain their library listing.'}',
            ),
            actions: [
              TextButton(onPressed: () => launchUrl(Uri.parse(catalog!.sourceUrl)), child: const Text('TVmaze')),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            ],
          ),
        );
      },
      child: Text(failed ? 'Episode list unavailable · Retry' : 'Episode information: TVmaze'),
    );
  }
}
