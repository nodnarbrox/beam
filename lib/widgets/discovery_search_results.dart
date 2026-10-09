import 'dart:async';

import 'package:plezy/widgets/network_artwork.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../focus/focusable_wrapper.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../profiles/active_profile_provider.dart';
import '../screens/beam/beam_detail_screen.dart';
import '../screens/youtube_playback_screen.dart';
import '../screens/youtube_account_screen.dart';
import '../screens/youtube_browse_screen.dart';
import 'youtube_channel_avatar.dart';
import 'focusable_media_card.dart';
import '../services/beam/plex_public_discover.dart';
import '../services/youtube/youtube_library.dart';
import '../services/youtube/youtube_service.dart';
import '../utils/snackbar_helper.dart';
import '../utils/app_logger.dart';

enum SearchScope {
  all('All'),
  library('Library'),
  movies('Movies'),
  tv('TV'),
  games('Games'),
  youtube('YouTube'),
  saved('Saved videos'),
  forYou('For you');

  const SearchScope(this.label);
  final String label;
  bool get includesLibrary => this == all || this == library || this == movies || this == tv;
}

/// The wider catalog and YouTube occupy the same search surface as library
/// results. Each source settles independently; library failures cannot hide it.
class DiscoverySearchResults extends StatefulWidget {
  const DiscoverySearchResults({
    super.key,
    required this.query,
    required this.scope,
    required this.libraryItems,
    required this.firstFocus,
    required this.onNavigateLeft,
    required this.onNavigateUp,
    required this.onQuery,
    this.catalog,
    this.youtubeFactory,
    this.onResultsReady,
  });
  final String query;
  final SearchScope scope;
  final List<MediaItem> libraryItems;
  final FocusNode firstFocus;
  final VoidCallback onNavigateLeft;
  final VoidCallback onNavigateUp;
  final ValueChanged<String> onQuery;
  final PlexPublicDiscover? catalog;
  final YouTubeService Function()? youtubeFactory;
  final VoidCallback? onResultsReady;

  @override
  State<DiscoverySearchResults> createState() => _DiscoverySearchResultsState();
}

class _DiscoverySearchResultsState extends State<DiscoverySearchResults> {
  late final _catalog = widget.catalog ?? PlexPublicDiscover();
  YouTubeService _youtube = YouTubeService();
  YouTubeLibrary? _library;
  String? _profileId;
  Timer? _debounce;
  int _generation = 0;
  List<BeamDiscoverItem> _titles = [];
  List<YouTubeVideo> _videos = [];
  List<YouTubeChannel> _channels = [];
  String? _channelError;
  bool _restoreVideoFocus = false;
  bool _catalogLoading = false;
  bool _youtubeLoading = false;
  String? _catalogError;
  String? _youtubeError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final profileId = context.watch<ActiveProfileProvider?>()?.activeId ?? 'local';
    if (profileId == _profileId) return;
    _profileId = profileId;
    _library = null;
    _schedule();
    unawaited(_loadLibrary(profileId));
  }

  Future<void> _loadLibrary(String profileId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || _profileId != profileId) return;
      setState(() {
        _library = YouTubeLibrary(prefs, profileId);
        if (widget.query.isEmpty || widget.scope == SearchScope.saved || widget.scope == SearchScope.forYou) {
          _schedule();
        }
      });
    } catch (error, stack) {
      appLogger.w('YouTube saved videos could not be loaded', error: error, stackTrace: stack);
      if (mounted && _profileId == profileId) showErrorSnackBar(context, 'Saved videos could not be loaded.');
    }
  }

  @override
  void didUpdateWidget(DiscoverySearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query || oldWidget.scope != widget.scope) _schedule();
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _youtube.close();
    super.dispose();
  }

  void _schedule() {
    final generation = ++_generation;
    _debounce?.cancel();
    _youtube.close();
    _youtube = widget.youtubeFactory?.call() ?? YouTubeService();
    _titles = [];
    _videos = [];
    _channels = [];
    _channelError = null;
    _catalogError = null;
    _youtubeError = null;
    final scope = widget.scope;
    final personal = scope == SearchScope.saved || scope == SearchScope.forYou;
    _catalogLoading =
        widget.query.isNotEmpty && !personal && scope != SearchScope.youtube && scope != SearchScope.library;
    _youtubeLoading = scope != SearchScope.library && scope != SearchScope.movies && scope != SearchScope.tv;
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted || generation != _generation) return;
      if (_catalogLoading) unawaited(_searchCatalog(generation));
      if (_youtubeLoading) unawaited(_searchYouTube(generation));
    });
  }

  void _resultsReady(int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
      if (_titles.isEmpty && _videos.isEmpty && _channels.isEmpty) return;
      if (_restoreVideoFocus) {
        _restoreVideoFocus = false;
        widget.firstFocus.requestFocus();
      }
      widget.onResultsReady?.call();
    });
  }

  Future<void> _searchCatalog(int generation) async {
    try {
      final titles = await _catalog
          .search(
            widget.query,
            throwOnError: true,
            kind: widget.scope == SearchScope.movies
                ? MediaKind.movie
                : widget.scope == SearchScope.tv
                ? MediaKind.show
                : null,
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted || generation != _generation) return;
      setState(() {
        _titles = titles;
        _catalogLoading = false;
      });
      _resultsReady(generation);
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      appLogger.w('Catalog search failed', error: error, stackTrace: stack);
      setState(() {
        _catalogLoading = false;
        _catalogError = 'Movie and TV search is unavailable. Try again.';
      });
    }
  }

  Future<void> _searchYouTube(int generation) async {
    try {
      final query = widget.query;
      final scope = widget.scope;
      final library = _library;
      List<YouTubeVideo> videos;
      if (scope == SearchScope.saved) {
        videos = library?.saved ?? [];
      } else if (scope == SearchScope.forYou) {
        final seeds = library?.recommendationSeeds ?? [];
        final service = _youtube;
        var failures = 0;
        final groups = await Future.wait(
          seeds.map((seed) async {
            try {
              return await service.related(seed);
            } catch (error, stack) {
              failures++;
              if (mounted && generation == _generation) {
                appLogger.w('YouTube recommendations failed', error: error, stackTrace: stack);
              }
              return <YouTubeVideo>[];
            }
          }),
        );
        if (seeds.isNotEmpty && failures == seeds.length) throw StateError('Recommendations unavailable');
        videos = YouTubeLibrary.rankRecommendations(groups, {
          ...?library?.saved.map((v) => v.id),
          ...?library?.recent.map((v) => v.id),
          ...?library?.liked.map((v) => v.id),
        });
      } else if (query.isEmpty) {
        final seen = <String>{};
        videos = [...?library?.saved, ...?library?.recent].where((v) => seen.add(v.id)).take(20).toList();
      } else {
        final service = _youtube;
        Object? videoFailure;
        final results = await Future.wait<Object>([
          service.search(query).catchError((Object error, StackTrace stack) {
            videoFailure = error;
            if (mounted && generation == _generation) {
              appLogger.w('YouTube video search failed', error: error, stackTrace: stack);
            }
            return <YouTubeVideo>[];
          }),
          service.searchChannels(query).catchError((Object error, StackTrace stack) {
            if (mounted && generation == _generation) {
              appLogger.w('YouTube channel search failed', error: error, stackTrace: stack);
              _channelError = 'Channel search is unavailable. Try again.';
            }
            return <YouTubeChannel>[];
          }),
        ]);
        if (!mounted || generation != _generation) return;
        videos = results[0] as List<YouTubeVideo>;
        _channels = results[1] as List<YouTubeChannel>;
        if (videoFailure != null) _youtubeError = 'Video search is unavailable. Try again.';
      }
      if ((scope == SearchScope.saved || scope == SearchScope.forYou) && query.isNotEmpty) {
        final term = query.toLowerCase();
        videos = videos.where((v) => '${v.title} ${v.author}'.toLowerCase().contains(term)).toList();
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _videos = videos;
        _youtubeLoading = false;
      });
      _resultsReady(generation);
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      appLogger.w('YouTube search failed', error: error, stackTrace: stack);
      setState(() {
        _youtubeLoading = false;
        _youtubeError = 'YouTube is unavailable right now. Try again.';
      });
    }
  }

  Future<void> _play(YouTubeVideo video) async {
    // A route-scoped resolver makes Back cancel the request, without letting a
    // late result unexpectedly push a player over a different screen/profile.
    final library = _library;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => YouTubePlaybackScreen(video: video, library: library, youtubeFactory: widget.youtubeFactory),
      ),
    );
    if (!mounted) return;
    if (widget.query.isEmpty) {
      _restoreVideoFocus = true;
      setState(_schedule);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) widget.firstFocus.requestFocus();
      });
    }
  }

  Future<void> _openChannel(YouTubeChannel channel) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            YouTubeBrowseScreen(query: channel.url, title: channel.title, youtubeFactory: widget.youtubeFactory),
      ),
    );
    if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) widget.firstFocus.requestFocus();
  }

  Future<void> _openAccount() async {
    final library = _library;
    if (library == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => YouTubeAccountScreen(
          preferences: library.preferences,
          profileId: library.profileId,
          onPlay: _play,
          onChannel: (id) => widget.onQuery('https://www.youtube.com/channel/$id'),
        ),
      ),
    );
    if (mounted) setState(_schedule);
  }

  Future<void> _openTitle(BeamDiscoverItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BeamDetailScreen(item: item, discover: _catalog),
      ),
    );
  }

  Widget _heading(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(label, style: Theme.of(context).textTheme.titleLarge),
  );

  Widget _message(String message, {bool retry = false}) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        Expanded(child: Text(message)),
        if (retry) TextButton(onPressed: () => setState(_schedule), child: const Text('Retry')),
      ],
    ),
  );

  Widget _image(String? url, {bool poster = false}) => SizedBox(
    width: poster ? 54 : 128,
    height: 72,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: url == null
          ? const Icon(Icons.movie_outlined)
          : NetworkArtwork(
              imageUrl: url,
              fit: BoxFit.cover,
              memCacheWidth: poster ? 108 : 256,
              errorBuilder: (_, _, _) => const Icon(Icons.movie_outlined),
            ),
    ),
  );

  Widget _row({
    required String title,
    required String subtitle,
    required Widget leading,
    required VoidCallback onTap,
    required bool first,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: FocusableWrapper(
        focusNode: first ? widget.firstFocus : null,
        onSelect: onTap,
        onNavigateLeft: widget.onNavigateLeft,
        onNavigateUp: first ? widget.onNavigateUp : null,
        borderRadius: 10,
        autoScroll: true,
        scrollAlignment: .4,
        semanticLabel: '$title, $subtitle',
        child: ExcludeFocus(
          child: ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            tileColor: Theme.of(context).colorScheme.surfaceContainerLow,
            contentPadding: const EdgeInsets.all(10),
            leading: leading,
            minVerticalPadding: 10,
            title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: trailing,
            onTap: onTap,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.scope == SearchScope.library) return const SizedBox.shrink();
    // Library copies keep their existing play path. Don't offer a duplicate
    // stream for an owned title with the same name, year and media kind.
    String identity(String title, int? year, MediaKind kind) => '${title.trim().toLowerCase()}|$year|${kind.name}';
    final owned = widget.libraryItems.map((v) => identity(v.title ?? '', v.year, v.kind)).toSet();
    final titles = _titles.where((v) => !owned.contains(identity(v.title, v.year, v.kind))).toList();
    final showCatalog =
        widget.query.isNotEmpty && const {SearchScope.all, SearchScope.movies, SearchScope.tv}.contains(widget.scope);
    final showYouTube = const {
      SearchScope.all,
      SearchScope.youtube,
      SearchScope.saved,
      SearchScope.forYou,
    }.contains(widget.scope);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showCatalog) ...[
          _heading('Movies & TV'),
          if (_catalogLoading) const LinearProgressIndicator(),
          if (_catalogError != null) _message(_catalogError!, retry: true),
          if (!_catalogLoading && _catalogError == null && titles.isEmpty) _message('No additional titles found.'),
          for (var i = 0; i < titles.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FocusableMediaCard(
                key: ValueKey('discover:${titles[i].toCatalogItem().identityKey}'),
                item: titles[i].toCatalogItem().toMediaItem(),
                forceListMode: true,
                disableScale: true,
                focusNode: i == 0 ? widget.firstFocus : null,
                onNavigateLeft: widget.onNavigateLeft,
                onNavigateUp: i == 0 ? widget.onNavigateUp : null,
                onTap: () => unawaited(_openTitle(titles[i])),
                onLongPress: () {},
              ),
            ),
        ],
        if (showYouTube) ...[
          Row(
            children: [
              Expanded(
                child: _heading(switch (widget.scope) {
                  SearchScope.saved => 'Saved videos',
                  SearchScope.forYou => 'For you',
                  _ => widget.query.isEmpty ? 'Your YouTube videos' : 'YouTube',
                }),
              ),
              TextButton.icon(
                onPressed: _library == null ? null : _openAccount,
                icon: const Icon(Icons.account_circle_outlined),
                label: const Text('Your YouTube'),
              ),
              const SizedBox(width: 16),
            ],
          ),
          if (_youtubeLoading) const LinearProgressIndicator(),
          if (_youtubeError != null) _message(_youtubeError!, retry: true),
          if (_channelError != null) _message(_channelError!, retry: true),
          if (_channels.isNotEmpty) ...[
            _heading('Channels'),
            for (var i = 0; i < _channels.length; i++)
              _row(
                title: _channels[i].title,
                subtitle: _channels[i].description.isEmpty ? 'YouTube channel' : _channels[i].description,
                leading: YouTubeChannelAvatar(title: _channels[i].title, url: _channels[i].avatarUrl),
                first: titles.isEmpty && i == 0,
                onTap: () => _openChannel(_channels[i]),
                trailing: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Text('View channel'), SizedBox(width: 8), Icon(Icons.chevron_right)],
                ),
              ),
            if (_videos.isNotEmpty) _heading('Videos'),
          ],
          if (!_youtubeLoading &&
              _youtubeError == null &&
              _channelError == null &&
              _videos.isEmpty &&
              _channels.isEmpty)
            _message(
              widget.scope == SearchScope.forYou
                  ? 'Play videos or connect your YouTube account to find more you may like.'
                  : widget.scope == SearchScope.saved
                  ? 'Your previously saved videos appear here. Select a video to play it.'
                  : widget.query.isEmpty
                  ? 'Search YouTube, paste a video or public playlist link, or enter a channel @handle.'
                  : 'No YouTube videos or channels found.',
            ),
          for (var i = 0; i < _videos.length; i++)
            _row(
              title: _videos[i].title,
              subtitle: _videos[i].author,
              leading: _image(_videos[i].thumbnail),
              first: titles.isEmpty && _channels.isEmpty && i == 0,
              onTap: () => _play(_videos[i]),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.play_circle_fill, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  const Text('Play'),
                ],
              ),
            ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}
