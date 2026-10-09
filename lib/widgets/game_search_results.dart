import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../focus/focusable_wrapper.dart';
import '../profiles/active_profile_provider.dart';
import '../screens/games/games_screen.dart';
import '../services/games/game_library.dart';
import '../utils/app_logger.dart';

/// Games settle independently of movie and video searches.
class GameSearchResults extends StatefulWidget {
  const GameSearchResults({
    super.key,
    required this.query,
    required this.firstFocus,
    required this.onNavigateLeft,
    required this.onNavigateUp,
    required this.onResultsReady,
    this.showEmptyState = false,
    this.library,
  });

  final String query;
  final FocusNode firstFocus;
  final VoidCallback onNavigateLeft, onNavigateUp, onResultsReady;
  final bool showEmptyState;
  final GameLibrary? library;

  @override
  State<GameSearchResults> createState() => _GameSearchResultsState();
}

class _GameSearchResultsState extends State<GameSearchResults> {
  GameLibrary? _library;
  String? _profile;
  Timer? _debounce;
  int _generation = 0;
  List<LibraryGame> _games = [];
  bool _loading = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final profile = context.watch<ActiveProfileProvider?>()?.activeId ?? 'local';
    if (profile == _profile) return;
    _profile = profile;
    _schedule();
  }

  @override
  void didUpdateWidget(GameSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) _schedule();
  }

  void _schedule() {
    final generation = ++_generation;
    _debounce?.cancel();
    _games = [];
    _error = null;
    _loading = widget.query.trim().isNotEmpty;
    if (_loading) _debounce = Timer(const Duration(milliseconds: 350), () => _search(generation));
  }

  Future<void> _search(int generation) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || generation != _generation) return;
      if (_library == null || _library!.profile != _profile) {
        _library?.close();
        _library = widget.library ?? GameLibrary(prefs, _profile!);
      }
      if (_library!.base.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'Set your library connection in Games settings to search games.';
        });
        return;
      }
      final result = await _library!.catalog(query: widget.query.trim());
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _games = (result['games'] as List).map((g) => LibraryGame(g as Map<String, dynamic>)).toList();
      });
      if (_games.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _generation) widget.onResultsReady();
        });
      }
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      appLogger.w('Game search could not reach the library', error: error, stackTrace: stack);
      setState(() {
        _loading = false;
        _error = 'Game search is unavailable. Check the connection in Games settings.';
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _library?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_games.isEmpty) {
      if (!widget.showEmptyState) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.all(24),
        child: _loading
            ? const LinearProgressIndicator()
            : Text(_error ?? (widget.query.trim().isEmpty ? 'Search your game collection.' : 'No matching games.')),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text('Games', style: Theme.of(context).textTheme.titleLarge),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 224,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              itemCount: _games.length,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: (context, index) {
                final game = _games[index];
                void open() => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => GameDetailScreen(library: _library!, game: game),
                  ),
                );
                return FocusableWrapper(
                  key: ValueKey('search.game.${game.id}'),
                  focusNode: index == 0 ? widget.firstFocus : null,
                  onNavigateLeft: index == 0 ? widget.onNavigateLeft : null,
                  onNavigateUp: widget.onNavigateUp,
                  onSelect: open,
                  child: GestureDetector(
                    onTap: open,
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      width: 145,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: GameArt(library: _library, path: game.cover, fit: BoxFit.contain),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            game.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            game.systemName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
