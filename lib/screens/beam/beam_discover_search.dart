import 'dart:async';

import 'package:plezy/widgets/network_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:plezy/utils/app_logger.dart';

import '../../database/app_database.dart';
import '../../media/media_kind.dart';
import '../../mixins/refreshable.dart';
import '../../navigation/main_screen_scope.dart';
import '../../utils/platform_detector.dart';
import '../../services/beam/beam_library_service.dart';
import '../../services/beam/beam_fallback.dart';
import '../../services/beam/plex_public_discover.dart';
import 'beam_detail_screen.dart';
import 'beam_search_screen.dart';

/// Plex-discovery-style search for Beam: the user searches once and sees rich
/// POSTER cards (image + title + year) from Plex's PUBLIC Discover provider —
/// NO Plex account or login required — exactly like Plex's own search. The
/// messy torrent release list is a background detail: tapping a poster hands
/// `title year` to the indexer search + resolve/play flow ([BeamSearchScreen]).
///
/// Falls back gracefully: if discovery returns nothing (offline / blocked), a
/// button routes straight to the raw indexer [BeamSearchScreen].
class BeamDiscoverSearch extends StatefulWidget {
  const BeamDiscoverSearch({super.key, this.appBarActions});

  /// Trailing [AppBar] actions injected by the host (e.g. the Beam settings
  /// button from [BeamHome]).
  final List<Widget>? appBarActions;

  @override
  State<BeamDiscoverSearch> createState() => BeamDiscoverSearchState();
}

class BeamDiscoverSearchState extends State<BeamDiscoverSearch> with FocusableTab, SearchInputFocusable {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _discover = PlexPublicDiscover();

  /// Focus target for the first poster, so the D-pad can land on RESULTS
  /// rather than always being forced into the text field (which pops the TV
  /// on-screen keyboard over the grid).
  final _firstPosterFocus = FocusNode(debugLabel: 'BeamFirstPoster');

  /// The "All" filter chip — the safe TV landing spot when there are no
  /// results, since focusing it does not raise the on-screen keyboard.
  final _firstChipFocus = FocusNode(debugLabel: 'BeamFirstChip');

  List<BeamDiscoverItem> _results = const [];
  bool _loading = false;
  String? _error;
  int _searchToken = 0;
  MediaKind? _kindFilter; // null = all
  Timer? _debounce;

  /// Local Beam library (titles streamed before) shown on the empty tab as
  /// "Continue Watching" / "Recently Played" — the Home experience.
  List<BeamLibraryEntry> _continueWatching = const [];
  List<BeamLibraryEntry> _recentlyPlayed = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLibrary());
  }

  /// (Re)load the local Beam library rows. Called on open and whenever the
  /// player closes so a just-watched title appears/updates immediately.
  Future<void> _loadLibrary() async {
    if (!mounted) return;
    try {
      final lib = BeamLibraryService(context.read<AppDatabase>());
      final recent = await lib.recentlyPlayed(limit: 20);
      final cont = recent.where((e) => e.isInProgress).take(20).toList();
      if (!mounted) return;
      setState(() {
        _recentlyPlayed = recent;
        _continueWatching = cont;
      });
    } catch (e) {
      appLogger.w('Beam library load failed: $e');
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    _firstPosterFocus.dispose();
    _firstChipFocus.dispose();
    super.dispose();
  }

  // --- Plezy focus contract -------------------------------------------------
  // main_screen calls these when the D-pad moves off the sidebar into this
  // tab. Without them the remote has nowhere to go and Beam is unreachable.

  /// Where the D-pad lands when entering the tab from the sidebar. Order of
  /// preference: first poster → filter chips → search field.
  ///
  /// The search field is LAST on TV on purpose: focusing a TextField pops the
  /// on-screen keyboard over the whole screen, so arriving on an empty Beam
  /// tab would immediately bury it under a keyboard the user never asked for.
  /// Landing on the "All" chip keeps the remote free to move around; the user
  /// opens the keyboard deliberately by navigating UP to the field.
  @override
  void focusActiveTabIfReady() {
    if (!mounted) return;
    if (_results.isNotEmpty && _firstPosterFocus.canRequestFocus) {
      _firstPosterFocus.requestFocus();
      return;
    }
    if (PlatformDetector.isTV() && _firstChipFocus.canRequestFocus) {
      _firstChipFocus.requestFocus();
      return;
    }
    _focus.requestFocus();
  }

  @override
  void focusSearchInput() {
    if (!mounted) return;
    _focus.requestFocus();
  }

  @override
  void submitSearchQuery(String query) {
    if (!mounted) return;
    final trimmed = query.trim();
    _controller.text = trimmed;
    if (trimmed.isEmpty) return;
    // The query was typed elsewhere (companion remote) — run it and land focus
    // on the results, never on the field, so the TV keyboard stays shut.
    _search();
  }

  /// D-pad LEFT from the leftmost column returns to the navigation rail —
  /// every other Plezy tab does this, and without it Beam is a focus trap.
  void _navigateToSidebar() => MainScreenFocusScope.focusSidebarOf(context);

  /// Search-as-you-type: debounce keystrokes, then query Plex Discover live so
  /// matching movies appear as the user types (never showing the prior screen).
  void _onChanged(String value) {
    _debounce?.cancel();
    final q = value.trim();
    if (q.length < 2) {
      setState(() {
        _results = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 350), _search);
  }

  Future<void> _search() async {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    final token = ++_searchToken;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Public Plex Discover — works with NO login.
      final items = await _discover.search(q, kind: _kindFilter, limit: 40);
      if (!mounted || token != _searchToken) return;
      if (items.isEmpty) {
        // Nothing from discovery (offline / blocked) — offer the raw indexer.
        setState(() {
          _results = const [];
          _error =
              'No results from discovery. Tap below to search sources '
              'directly.';
          _loading = false;
        });
        return;
      }
      setState(() {
        _results = items;
        _loading = false;
      });
      // Results landed — on TV move off the text field so the on-screen
      // keyboard closes and the D-pad drives the poster grid.
      if (PlatformDetector.isTV()) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_firstPosterFocus.canRequestFocus) {
            _firstPosterFocus.requestFocus();
          }
        });
      }
    } catch (e) {
      appLogger.w('Beam discover search failed: $e');
      if (!mounted || token != _searchToken) return;
      setState(() {
        _error = 'Search failed. Tap below to search sources directly.';
        _loading = false;
      });
    }
  }

  /// Hand a chosen title to the indexer/resolve flow. We reuse
  /// [BeamSearchScreen] pre-seeded with `title year` so it shows the
  /// grouped sources + Instant/Torrent play sheet for exactly this title.
  void _openSourcesFor(String query, BeamDiscoverItem? item) {
    final seed = item?.searchQuery ?? query;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => BeamSearchScreen(initialQuery: seed)));
  }

  /// Replay after a connected-library check, retaining the saved movie magnet
  /// and resume position when the source race is needed.
  void _playLibraryEntry(BeamLibraryEntry entry) {
    final episode = entry.episode;
    if (episode != null) {
      unawaited(
        BeamFallback.playByTitle(
          context,
          title: episode.showTitle,
          year: episode.year,
          kind: MediaKind.episode,
          season: episode.season,
          episode: episode.episode,
          beamEpisode: episode,
          metadata: episode.playerMetadata,
          onPlaybackClosed: () => unawaited(_loadLibrary()),
        ).whenComplete(_loadLibrary),
      );
      return;
    }
    // Preserve the known movie source and resume key while checking connected
    // libraries first, just like a new movie or episode Play request.
    if (entry.contentKey.startsWith('episode:')) return;
    unawaited(
      BeamFallback.playByTitle(
        context,
        title: entry.title,
        kind: MediaKind.movie,
        savedEntry: entry,
        onPlaybackClosed: () => unawaited(_loadLibrary()),
      ).whenComplete(_loadLibrary),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Beam'), actions: widget.appBarActions),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: _DpadEscape(
              onLeft: _navigateToSidebar,
              onDown: () {
                if (_results.isNotEmpty && _firstPosterFocus.canRequestFocus) {
                  _firstPosterFocus.requestFocus();
                } else if (_firstChipFocus.canRequestFocus) {
                  // No results yet — DOWN still has somewhere to go, which
                  // also dismisses the on-screen keyboard.
                  _firstChipFocus.requestFocus();
                }
              },
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                // NEVER autofocus on TV: focusing a TextField pops the on-screen
                // keyboard over the whole grid the moment the tab opens, which
                // reads as "the remote does nothing". main_screen decides where
                // focus goes via focusActiveTabIfReady().
                autofocus: !PlatformDetector.isTV(),
                textInputAction: TextInputAction.search,
                onChanged: _onChanged,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: 'Search movies & TV…',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search),
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ),
          ),
          _filterChips(theme),
          Expanded(child: _body(theme)),
        ],
      ),
    );
  }

  Widget _filterChips(ThemeData theme) {
    Widget chip(String label, MediaKind? kind, {FocusNode? focusNode}) {
      final selected = _kindFilter == kind;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          focusNode: focusNode,
          onSelected: (_) {
            setState(() => _kindFilter = kind);
            if (_results.isNotEmpty || _controller.text.isNotEmpty) _search();
          },
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      // UP reaches the search box (the only way to raise the keyboard, by
      // choice); LEFT returns to the navigation rail.
      child: _DpadEscape(
        onUp: focusSearchInput,
        onDown: () {
          if (_results.isNotEmpty && _firstPosterFocus.canRequestFocus) {
            _firstPosterFocus.requestFocus();
          }
        },
        // Only escape to the rail from the LEFTMOST chip — otherwise LEFT
        // could never move between chips.
        onLeft: () {
          if (_firstChipFocus.hasFocus) {
            _navigateToSidebar();
          } else {
            FocusScope.of(context).focusInDirection(TraversalDirection.left);
          }
        },
        child: Row(
          children: [
            chip('All', null, focusNode: _firstChipFocus),
            chip('Movies', MediaKind.movie),
            chip('TV', MediaKind.show),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.search),
                label: const Text('Search sources directly'),
                onPressed: () => _openSourcesFor(_controller.text.trim(), null),
              ),
            ],
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      // Nothing searched yet: show the local Beam library (Home experience) if
      // the user has streamed anything before, else the search prompt.
      if (_recentlyPlayed.isNotEmpty) {
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            if (_continueWatching.isNotEmpty)
              _BeamLibraryRow(title: 'Continue Watching', entries: _continueWatching, onTap: _playLibraryEntry),
            _BeamLibraryRow(title: 'Recently Played', entries: _recentlyPlayed, onTap: _playLibraryEntry),
          ],
        );
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.travel_explore, size: 64, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('Search for something to Beam', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Find a movie or show, then stream it instantly.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    // Mirror the delegate's own maths so we know which items sit in column 0
    // (LEFT there must exit to the rail) and which sit in the top row (UP
    // returns to the search box). Flutter's default focus traversal handles
    // every other direction inside the grid.
    const maxExtent = 170.0;
    const crossSpacing = 14.0;
    final gridWidth = MediaQuery.sizeOf(context).width - 32; // padding
    final columns = (gridWidth / (maxExtent + crossSpacing)).ceil().clamp(1, 100);

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxExtent,
        childAspectRatio: 0.62,
        crossAxisSpacing: crossSpacing,
        mainAxisSpacing: 18,
      ),
      itemCount: _results.length,
      itemBuilder: (context, i) => _PosterCard(
        item: _results[i],
        // The first poster carries a stable FocusNode so main_screen's
        // focusActiveTabIfReady() and the search field's D-pad DOWN both have
        // a concrete target to hand the remote to.
        focusNode: i == 0 ? _firstPosterFocus : null,
        // On phones/desktop the field is autofocused, so don't fight it; on TV
        // focus is placed explicitly once results land.
        autofocus: i == 0 && PlatformDetector.isTV(),
        // LEFT off the leftmost column goes back to the nav rail, and UP from
        // the top row returns to the search box — no dead ends.
        onNavigateLeft: (i % columns == 0) ? _navigateToSidebar : null,
        onNavigateUp: (i < columns) ? focusSearchInput : null,
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => BeamDetailScreen(item: _results[i]))),
      ),
    );
  }
}

/// Wraps a child so specific D-pad directions escape to a caller-supplied
/// target instead of dead-ending. Returning [KeyEventResult.ignored] when no
/// handler is supplied lets Flutter's normal directional traversal run.
class _DpadEscape extends StatelessWidget {
  const _DpadEscape({required this.child, this.onLeft, this.onDown, this.onUp});

  final Widget child;
  final VoidCallback? onLeft;
  final VoidCallback? onDown;
  final VoidCallback? onUp;

  @override
  Widget build(BuildContext context) {
    return Focus(
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final cb = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowLeft => onLeft,
          LogicalKeyboardKey.arrowDown => onDown,
          LogicalKeyboardKey.arrowUp => onUp,
          _ => null,
        };
        if (cb == null) return KeyEventResult.ignored;
        cb();
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}

class _PosterCard extends StatefulWidget {
  const _PosterCard({
    required this.item,
    required this.onTap,
    this.autofocus = false,
    this.focusNode,
    this.onNavigateLeft,
    this.onNavigateUp,
  });
  final BeamDiscoverItem item;
  final VoidCallback onTap;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onNavigateUp;

  @override
  State<_PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<_PosterCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.item;
    // A TV remote needs a VISIBLE focus indicator — without the ring you can't
    // tell which poster is selected, which reads as "the controls don't work".
    return _DpadEscape(
      onLeft: widget.onNavigateLeft,
      onUp: widget.onNavigateUp,
      child: InkWell(
        onTap: widget.onTap,
        autofocus: widget.autofocus,
        focusNode: widget.focusNode,
        onFocusChange: (f) => setState(() => _focused = f),
        focusColor: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _focused ? theme.colorScheme.primary : Colors.transparent, width: 3),
          ),
          padding: const EdgeInsets.all(2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: item.posterUrl != null
                      ? NetworkArtwork(
                          imageUrl: item.posterUrl!,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          placeholder: (context, url) => Container(color: theme.colorScheme.surfaceContainerHighest),
                          errorBuilder: (context, url, error) => _posterFallback(theme),
                        )
                      : _posterFallback(theme),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (item.year != null)
                Text(
                  '${item.year}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _posterFallback(ThemeData theme) => Container(
    color: theme.colorScheme.surfaceContainerHighest,
    alignment: Alignment.center,
    child: Icon(
      widget.item.kind == MediaKind.show ? Icons.tv_rounded : Icons.movie_rounded,
      size: 40,
      color: theme.colorScheme.onSurfaceVariant,
    ),
  );
}

/// A horizontal shelf of Beam library entries (Continue Watching / Recently
/// Played), rendered on the empty Beam tab as its Home experience.
class _BeamLibraryRow extends StatelessWidget {
  const _BeamLibraryRow({required this.title, required this.entries, required this.onTap});

  final String title;
  final List<BeamLibraryEntry> entries;
  final void Function(BeamLibraryEntry) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(title, style: theme.textTheme.titleMedium),
        ),
        SizedBox(
          height: 176,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) =>
                _BeamLibraryCard(entry: entries[i], autofocus: false, onTap: () => onTap(entries[i])),
          ),
        ),
      ],
    );
  }
}

/// One tappable library card: poster (or placeholder), title, and a thin
/// progress bar showing where the user left off.
class _BeamLibraryCard extends StatefulWidget {
  const _BeamLibraryCard({required this.entry, required this.onTap, this.autofocus = false});

  final BeamLibraryEntry entry;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  State<_BeamLibraryCard> createState() => _BeamLibraryCardState();
}

class _BeamLibraryCardState extends State<_BeamLibraryCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entry = widget.entry;
    final poster = entry.posterUrl;
    return SizedBox(
      width: 118,
      child: InkWell(
        autofocus: widget.autofocus,
        onFocusChange: (f) => setState(() => _focused = f),
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 118,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _focused ? cs.primary : Colors.transparent, width: 3),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (poster != null && poster.isNotEmpty)
                    NetworkArtwork(
                      imageUrl: poster,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Icon(Icons.movie_outlined, color: cs.onSurfaceVariant),
                    )
                  else
                    Center(child: Icon(Icons.movie_outlined, size: 34, color: cs.onSurfaceVariant)),
                  if (entry.fraction > 0)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: LinearProgressIndicator(
                        value: entry.fraction,
                        minHeight: 4,
                        backgroundColor: Colors.black38,
                      ),
                    ),
                  const Center(child: Icon(Icons.play_circle_fill, size: 34, color: Colors.white70)),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
