import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../exceptions/media_server_exceptions.dart';
import '../focus/focusable_text_field.dart';
import '../focus/focusable_wrapper.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../mixins/debounced_media_search.dart';
import '../mixins/mounted_set_state_mixin.dart';
import '../mixins/refreshable.dart';
import '../providers/multi_server_provider.dart';
import '../services/data_aggregation_service.dart';
import '../services/games/game_library.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';
import '../utils/snackbar_helper.dart';
import '../utils/media_server_http_client.dart';
import '../widgets/desktop_app_bar.dart';
import '../widgets/loading_indicator_box.dart';
import '../widgets/search_input_field.dart';
import '../widgets/discovery_search_results.dart';
import '../widgets/game_search_results.dart';
import '../widgets/focusable_media_card.dart';
import '../utils/focus_utils.dart';
import 'libraries/state_messages.dart';
import 'main_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.gameLibrary});
  final GameLibrary? gameLibrary;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with Refreshable, FullRefreshable, SearchInputFocusable, FocusableTab, MountedSetStateMixin, DebouncedMediaSearch {
  String? _focusResultsForQuery;
  final _tvTextInputController = TvTextInputController();
  AbortController? _activeSearchAbort;
  ({String query, SearchAggregationResult result})? _pendingSearchOutcome;
  SearchScope _scope = SearchScope.all;
  final _discoveryFocus = FocusNode(debugLabel: 'SearchDiscoveryFirstResult');
  final _gameFocus = FocusNode(debugLabel: 'SearchGameFirstResult');
  final _scopeFocus = {
    for (final scope in SearchScope.values) scope: FocusNode(debugLabel: 'SearchScope.${scope.name}'),
  };
  bool _gamesReady = false, _focusGamesWhenReady = false;
  bool _focusDiscoveryWhenReady = false;
  String _discoveryQuery = '';
  List<MediaItem> get _visibleLibraryResults => switch (_scope) {
    SearchScope.movies => searchResults.where((item) => item.kind == MediaKind.movie).toList(),
    SearchScope.tv =>
      searchResults.where((item) => item.kind == MediaKind.show || item.kind == MediaKind.episode).toList(),
    _ => searchResults,
  };

  void _updateDiscoveryQuery() {
    final query = searchController.text.trim();
    if (mounted && query != _discoveryQuery) {
      setState(() {
        _discoveryQuery = query;
        _gamesReady = false;
        _focusGamesWhenReady = false;
      });
    }
  }

  @override
  void dispose() {
    searchController.removeListener(_updateDiscoveryQuery);
    _discoveryFocus.dispose();
    _gameFocus.dispose();
    for (final node in _scopeFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    searchController.addListener(_updateDiscoveryQuery);
    FocusUtils.requestFocusAfterBuild(this, searchFocusNode);
  }

  @override
  String get searchDebugLabel => 'Search';

  @override
  Future<List<MediaItem>> performSearchQuery(String query) async {
    if (_scope == SearchScope.games) return [];
    final multiServerProvider = Provider.of<MultiServerProvider>(context, listen: false);
    if (!multiServerProvider.hasConnectedServers) {
      return [];
    }

    final abort = AbortController();
    _activeSearchAbort = abort;
    try {
      final result = await multiServerProvider.aggregationService.searchAcrossServers(query, abort: abort);
      abort.throwIfAborted();
      if (result.succeededServerIds.isEmpty && result.failedServerIds.isNotEmpty) {
        throw const _SearchUnavailableException();
      }
      if (result.succeededServerIds.isEmpty && result.cancelledServerIds.isNotEmpty) {
        throw MediaServerHttpException(
          type: MediaServerHttpErrorType.cancelled,
          message: 'Search was cancelled before any server completed',
        );
      }
      _pendingSearchOutcome = (query: query, result: result);
      return result.items;
    } finally {
      if (identical(_activeSearchAbort, abort)) _activeSearchAbort = null;
    }
  }

  @override
  void onSearchInvalidated() {
    _activeSearchAbort?.abort();
    _activeSearchAbort = null;
    _pendingSearchOutcome = null;
  }

  @override
  void onSearchError(Object error) {
    _focusResultsForQuery = null;
    _pendingSearchOutcome = null;
    final message = error is _SearchUnavailableException
        ? t.errors.searchUnavailable
        : t.errors.searchFailed(error: error);
    showErrorSnackBar(context, message);
    _focusGameResultsIfReady();
  }

  @override
  void onSearchCleared() {
    _focusResultsForQuery = null;
    _pendingSearchOutcome = null;
  }

  @override
  void onSearchCompleted(String query, List<MediaItem> results) {
    final outcome = _pendingSearchOutcome;
    _pendingSearchOutcome = null;
    if (outcome?.query == query && outcome!.result.failedServerIds.isNotEmpty) {
      showAppSnackBar(context, t.messages.searchPartialResults);
    }

    if (!_scope.includesLibrary) return;
    if (_focusResultsForQuery == null || _focusResultsForQuery != query) return;
    _focusResultsForQuery = null;
    if (results.isEmpty) {
      _focusGameResultsIfReady();
      return;
    }
    _focusGamesWhenReady = false;
    if (searchController.text.trim() != query) return; // user kept editing
    FocusUtils.requestFocusAfterBuild(this, firstResultFocusNode);
  }

  /// OSK "Search" / hardware Enter on TV additionally focuses the results
  /// when the forced search lands.
  @override
  void handleSearchSubmit() {
    final query = searchController.text.trim();
    if (query.isEmpty) return;
    _focusGamesWhenReady = _scope == SearchScope.all || _scope == SearchScope.games;
    if (_scope == SearchScope.games ||
        (_scope == SearchScope.all && _gamesReady && !isSearching && _visibleLibraryResults.isEmpty)) {
      _focusGameResultsIfReady();
      return;
    }
    if (!_scope.includesLibrary) {
      _focusDiscoveryWhenReady = true;
      _discoveryFocus.requestFocus();
      return;
    }
    if (searchResults.isEmpty || isSearching || query != lastSearchedQuery) {
      _focusResultsForQuery = query;
    }
    super.handleSearchSubmit();
  }

  @override
  void refresh() {
    if (!mounted) return;
    runSearch(searchController.text.trim());
  }

  /// Focus the search input field
  @override
  void focusSearchInput() {
    if (!mounted) return;
    searchFocusNode.requestFocus();
  }

  @override
  void focusActiveTabIfReady() {
    if (!mounted) return;
    searchFocusNode.requestFocus();
  }

  /// Apply a complete query submitted from the Plezy companion remote: set the
  /// text, dismiss any open on-screen keyboard, land focus on the input without
  /// (re)opening the OSK, and run the search now — the first result takes focus
  /// when it lands (via onSearchCompleted). The user already typed the query on
  /// their phone, so the TV keyboard must never be up afterwards.
  @override
  void submitSearchQuery(String query) {
    if (!mounted) return;
    final trimmed = query.trim();
    searchController.text = trimmed; // listener arms the debounce / resets state

    // Focusing the field normally auto-opens the OSK; a remote search must not
    // show it, and must dismiss one the TV user already had open (the phone's
    // Search chip sends tabSearch before the query arrives).
    _tvTextInputController.closeTextInput();
    if (trimmed.isEmpty) return;

    // Land focus on the (visible) input immediately so the D-pad remote is
    // never stranded on the hidden previous tab — while the search is in
    // flight, when it fails, and when it returns nothing.
    _tvTextInputController.focusInputWithoutOpening();

    // Same path as the OSK Search key: jumps straight to already-matching
    // results, or cancels the debounce and runs now; the screen override arms
    // _focusResultsForQuery so results take focus when they land.
    handleSearchSubmit();
  }

  // Public method to fully reload all content (for profile switches)
  @override
  void fullRefresh() {
    if (!mounted) return;
    appLogger.d('SearchScreen.fullRefresh() called - clearing search and reloading');
    // Clearing the field resets the search state through the text listener.
    _focusResultsForQuery = null;
    searchController.clear();
  }

  Future<void> updateItem(MediaItem source) async {
    if (!mounted) return;
    final serverId = source.serverId;
    if (serverId == null) return;

    try {
      final multiServer = context.read<MultiServerProvider>();
      final updated = await multiServer.getClientForServer(ServerId(serverId))?.fetchItem(source.id);
      if (!mounted || updated == null) return;
      final index = searchResults.indexWhere((item) => item.globalKey == source.globalKey);
      if (index == -1) return;
      setState(() {
        searchResults[index] = updated;
      });
    } catch (e) {
      appLogger.d('Search item refresh skipped for ${source.globalKey}', error: e);
    }
  }

  /// Navigate focus to the sidebar
  void _navigateToSidebar() {
    _focusGamesWhenReady = false;
    MainScreenFocusScope.focusSidebarOf(context);
  }

  void _focusGameResultsIfReady() {
    if (!_focusGamesWhenReady || !_gamesReady || !mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (_scope != SearchScope.games && (isSearching || _visibleLibraryResults.isNotEmpty)) return;
    _focusGamesWhenReady = false;
    FocusUtils.requestFocusAfterBuild(this, _gameFocus);
  }

  void _navigateDownFromSearch() {
    if ((_scope == SearchScope.all || _scope == SearchScope.games) && _gamesReady) {
      _gameFocus.requestFocus();
    } else if (_scope.includesLibrary && _visibleLibraryResults.isNotEmpty && !isSearching) {
      firstResultFocusNode.requestFocus();
    } else if (_scope == SearchScope.games) {
      _focusGamesWhenReady = true;
    } else {
      _discoveryFocus.requestFocus();
    }
  }

  void _selectScope(SearchScope scope) {
    setState(() {
      _scope = scope;
      if (scope != SearchScope.all && scope != SearchScope.games) _gamesReady = false;
      _focusGamesWhenReady = false;
    });
  }

  Widget _buildResultsList(BuildContext context) {
    final multiServer = context.watch<MultiServerProvider>();
    final showServerName = multiServer.totalServerCount > 1;
    final items = _visibleLibraryResults;
    return SliverPadding(
      padding: const EdgeInsets.all(16),
      sliver: SliverList.builder(
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return FocusableMediaCard(
            key: Key(item.globalKey),
            item: item,
            forceListMode: true,
            disableScale: true,
            focusNode: index == 0 ? firstResultFocusNode : null,
            onRefresh: updateItem,
            onListRefresh: refresh,
            onNavigateLeft: _navigateToSidebar,
            onNavigateUp: index == 0 ? focusSearchInput : null,
            showServerName: showServerName,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          primary: false,
          slivers: [
            DesktopSliverAppBar(title: Text(t.common.search), floating: true),
            SliverToBoxAdapter(
              child: SearchInputField(
                controller: searchController,
                focusNode: searchFocusNode,
                debugLabel: searchDebugLabel,
                hintText: 'Movies, TV, games, YouTube, or a video link',
                tvTextInputController: _tvTextInputController,
                onNavigateLeft: _navigateToSidebar,
                onNavigateDown: () => _scopeFocus[_scope]!.requestFocus(),
                onEditingComplete: PlatformDetector.isTV() ? handleSearchSubmit : null,
                onBack: () {
                  if (searchController.text.isNotEmpty) {
                    searchController.clear();
                  } else {
                    _navigateToSidebar();
                  }
                },
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final scope in SearchScope.values)
                      FocusableWrapper(
                        focusNode: _scopeFocus[scope],
                        onSelect: () => _selectScope(scope),
                        onNavigateUp: _tvTextInputController.focusInputWithoutOpening,
                        onNavigateDown: _navigateDownFromSearch,
                        onNavigateLeft: scope == SearchScope.all ? _navigateToSidebar : null,
                        child: ExcludeFocus(
                          child: ChoiceChip(
                            label: Text(scope.label),
                            selected: _scope == scope,
                            onSelected: (_) => _selectScope(scope),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_scope == SearchScope.all || _scope == SearchScope.games)
              SliverToBoxAdapter(
                child: GameSearchResults(
                  library: widget.gameLibrary,
                  query: _discoveryQuery,
                  firstFocus: _gameFocus,
                  showEmptyState: _scope == SearchScope.games,
                  onNavigateLeft: _navigateToSidebar,
                  onNavigateUp: _tvTextInputController.focusInputWithoutOpening,
                  onResultsReady: () {
                    _gamesReady = true;
                    _focusGameResultsIfReady();
                  },
                ),
              ),
            if (_scope.includesLibrary && isSearching)
              LoadingIndicatorBox.sliver
            else if (_scope == SearchScope.library && !hasSearched)
              SliverToBoxAdapter(
                child: StateMessageWidget(
                  message: t.search.searchYourMedia,
                  subtitle: t.search.enterTitleActorOrKeyword,
                  icon: Symbols.search_rounded,
                  iconSize: 80,
                ),
              )
            else if (_scope.includesLibrary && lastSearchFailed)
              SliverToBoxAdapter(
                child: StateMessageWidget(message: t.explore.searchFailed, icon: Symbols.error_rounded, iconSize: 80),
              )
            else if (_scope == SearchScope.library && hasSearched && _visibleLibraryResults.isEmpty)
              SliverToBoxAdapter(
                child: StateMessageWidget(
                  message: t.messages.noResultsFound,
                  subtitle: t.search.tryDifferentTerm,
                  icon: Symbols.search_off_rounded,
                  iconSize: 80,
                ),
              )
            else if (_scope.includesLibrary && _visibleLibraryResults.isNotEmpty)
              _buildResultsList(context),
            if (_scope != SearchScope.games)
              SliverToBoxAdapter(
                child: DiscoverySearchResults(
                  query: _discoveryQuery,
                  scope: _scope,
                  libraryItems: searchResults,
                  firstFocus: _discoveryFocus,
                  onResultsReady: () {
                    if (!_focusDiscoveryWhenReady || _scope.includesLibrary) return;
                    _focusDiscoveryWhenReady = false;
                    _discoveryFocus.requestFocus();
                  },
                  onNavigateLeft: _navigateToSidebar,
                  onNavigateUp: focusSearchInput,
                  onQuery: (query) {
                    setState(() => _scope = SearchScope.youtube);
                    submitSearchQuery(query);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _SearchUnavailableException implements Exception {
  const _SearchUnavailableException();
}
