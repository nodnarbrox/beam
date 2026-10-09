import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../focus/focusable_wrapper.dart';
import '../../focus/focusable_text_field.dart';
import '../../focus/key_event_utils.dart';
import '../../mixins/refreshable.dart';
import '../../navigation/main_screen_scope.dart';
import '../../profiles/active_profile_provider.dart';
import '../../services/games/game_library.dart';
import '../../utils/app_logger.dart';

const _ink = Color(0xff101018);

class GamesScreen extends StatefulWidget {
  const GamesScreen({super.key, this.library});
  final GameLibrary? library;
  @override
  State<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends State<GamesScreen> with FocusableTab, Refreshable {
  GameLibrary? _library;
  List<Map<String, dynamic>> _systems = [];
  List<LibraryGame> _games = [];
  String _collection = '', _query = '';
  int _total = 0, _generation = 0;
  bool _loading = true;
  String? _error;
  LibraryGame? _spotlight;
  final _first = FocusNode(debugLabel: 'games.collections');
  final _searchFocus = FocusNode(debugLabel: 'games.search');
  final _firstResult = FocusNode(debugLabel: 'games.firstResult');
  final _resultsAnchor = GlobalKey();
  final _tvSearch = TvTextInputController();
  final _search = TextEditingController();
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final profile = context.read<ActiveProfileProvider?>()?.activeId ?? 'local';
    if (_library == null || _library!.profile != profile && widget.library == null) unawaited(_init(profile));
  }

  Future<void> _init(String profile) async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _library?.close();
    _library = widget.library ?? GameLibrary(prefs, profile);
    await _load();
  }

  @override
  void dispose() {
    _generation++;
    _library?.close();
    _first.dispose();
    _searchFocus.dispose();
    _firstResult.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  void focusActiveTabIfReady() {
    _first.requestFocus();
  }

  @override
  void refresh() {
    unawaited(_load());
  }

  Future<void> _load({bool more = false}) async {
    final library = _library;
    if (library == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_systems.isEmpty && _collection != 'recent' && _collection != 'favorites') {
        _systems = (await library.get('systems'))['systems'].cast<Map<String, dynamic>>();
      }
      List<LibraryGame> games;
      int total;
      if (_collection == 'recent' || _collection == 'favorites') {
        games = library.saved(_collection).where((g) => g.title.toLowerCase().contains(_query.toLowerCase())).toList();
        total = games.length;
      } else {
        final data = await library.catalog(system: _collection, query: _query, offset: more ? _games.length : 0);
        games = (data['games'] as List).map((g) => LibraryGame(g as Map<String, dynamic>)).toList();
        total = data['total'] as int;
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _games = more ? [..._games, ...games] : games;
        _total = total;
        if (!more) _spotlight = games.where((g) => g.cover != null).firstOrNull ?? games.firstOrNull;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = 'The game library could not be reached. Check its connection in Games settings.');
        appLogger.w('Games catalog could not be loaded.');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  void _select(String id) {
    setState(() {
      _collection = id;
      _query = '';
      _search.clear();
    });
    unawaited(_load());
  }

  Future<void> _open(LibraryGame game) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GameDetailScreen(library: _library!, game: game),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _submitSearch() async {
    _tvSearch.closeTextInput();
    final query = _search.text.trim();
    if (_query != query || _loading) {
      _query = query;
      await _load();
    }
    if (!mounted || !_searchFocus.hasFocus || _search.text.trim() != query) return;
    if (_games.isEmpty || _error != null) {
      _first.requestFocus();
      return;
    }
    final anchor = _resultsAnchor.currentContext;
    if (anchor != null && anchor.mounted) {
      await Scrollable.ensureVisible(anchor, alignment: .1, duration: const Duration(milliseconds: 200));
    }
    if (mounted && _searchFocus.hasFocus && ModalRoute.of(context)?.isCurrent == true) {
      _firstResult.requestFocus();
    }
  }

  void _leaveSearch() {
    _tvSearch.closeTextInput();
    MainScreenFocusScope.focusSidebarOf(context);
  }

  Widget _art(String? path, {BoxFit fit = BoxFit.cover}) => GameArt(library: _library, path: path, fit: fit);
  @override
  Widget build(BuildContext context) {
    final pink = Theme.of(context).colorScheme.primary;
    final game = _spotlight;
    return Focus(
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (ModalRoute.of(context)?.isCurrent != true) return KeyEventResult.ignored;
        return handleBackKeyAction(event, _leaveSearch);
      },
      child: ColoredBox(
        color: _ink,
        child: Stack(
          children: [
            Positioned.fill(child: Opacity(opacity: .4, child: _art(game?.background))),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [_ink.withValues(alpha: .35), _ink, _ink],
                  ),
                ),
              ),
            ),
            ListView(
              padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
              children: [
                Row(
                  children: [
                    Icon(Icons.sports_esports, color: pink, size: 28),
                    const SizedBox(width: 12),
                    Text(
                      'Games',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () async {
                        try {
                          await GameLibrary.channel.invokeMethod<void>('launchRainbow');
                        } on PlatformException catch (error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error.message ?? 'Rainbow Overdrive could not start.')),
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.sports_motorsports),
                      label: const Text('Rainbow Overdrive 3D'),
                    ),
                    IconButton(
                      tooltip: 'Favorite Rainbow Overdrive 3D',
                      icon: Icon(_library?.isFavorite(GameLibrary.rainbow3d) == true
                          ? Icons.favorite : Icons.favorite_border),
                      onPressed: _library == null ? null : () async {
                        await _library!.favorite(GameLibrary.rainbow3d);
                        if (!mounted) return;
                        await _load();
                      },
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        if (_library == null) return;
                        await Navigator.of(
                          context,
                        ).push(MaterialPageRoute<void>(builder: (_) => GamesSettingsScreen(library: _library!)));
                        if (mounted) {
                          _systems = [];
                          await _load();
                        }
                      },
                      icon: const Icon(Icons.tune),
                      label: const Text('Game settings'),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                SizedBox(
                  height: 188,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'YOUR NEXT ADVENTURE',
                              style: TextStyle(
                                color: pink,
                                fontSize: 11,
                                letterSpacing: 2.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              game?.title ?? 'A whole world of play.',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 32, height: 1.05, fontWeight: FontWeight.w900),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              game == null
                                  ? 'Your consoles. Your collection. Right here.'
                                  : '${game.systemName}  •  ${game.data['genre']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(height: 15),
                            if (game != null)
                              FilledButton.icon(
                                onPressed: () => _open(game),
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Explore game'),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 28),
                      SizedBox(width: 210, child: _art(game?.cover, fit: BoxFit.contain)),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Choose your collection',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 106,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(4),
                    itemCount: _systems.length + 3,
                    separatorBuilder: (_, _) => const SizedBox(width: 14),
                    itemBuilder: (context, index) {
                      final item = index < 3
                          ? <String, dynamic>{
                              'id': ['', 'recent', 'favorites'][index],
                              'title': ['All games', 'Recently played', 'Favorites'][index],
                            }
                          : _systems[index - 3];
                      final selected = _collection == item['id'];
                      return FocusableWrapper(
                        key: ValueKey('games.collection.${item['id']}'),
                        focusNode: index == 0 ? _first : null,
                        autoScroll: index != 0,
                        onSelect: () => _select(item['id'] as String),
                        onNavigateLeft: index == 0 ? () => MainScreenFocusScope.focusSidebarOf(context) : null,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _select(item['id'] as String),
                          child: SizedBox(
                            width: 180,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (item['background'] != null) _art(item['background'] as String),
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topRight,
                                        end: Alignment.bottomLeft,
                                        colors: [
                                          pink.withValues(alpha: selected ? .6 : .1),
                                          const Color(0xff202034),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(13),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        if (index < 3)
                                          Icon(
                                            [Icons.apps, Icons.history, Icons.favorite][index],
                                            color: selected ? pink : Colors.white70,
                                            size: 23,
                                          ),
                                        const Spacer(),
                                        Text(
                                          item['title'] as String,
                                          maxLines: 2,
                                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                                        ),
                                        if (item['count'] != null)
                                          Text(
                                            '${item['count']} games',
                                            style: const TextStyle(fontSize: 11, color: Colors.white60),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _query.isEmpty ? 'In your collection' : 'Search results',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Text('$_total games', style: const TextStyle(color: Colors.white54)),
                    const SizedBox(width: 20),
                    SizedBox(
                      width: 260,
                      child: FocusableTextField(
                        controller: _search,
                        focusNode: _searchFocus,
                        tvTextInputController: _tvSearch,
                        tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
                        textInputAction: TextInputAction.search,
                        onNavigateDown: () => unawaited(_submitSearch()),
                        onNavigateUp: _first.requestFocus,
                        onNavigateLeft: _leaveSearch,
                        decoration: const InputDecoration(
                          hintText: 'Find a game',
                          prefixIcon: Icon(Icons.search),
                          isDense: true,
                        ),
                        onEditingComplete: () => unawaited(_submitSearch()),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                if (_loading) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Text(_error!),
                        TextButton(onPressed: refresh, child: const Text('Try again')),
                      ],
                    ),
                  ),
                if (!_loading && _error == null && _games.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(30),
                    child: Text('No games here yet. Choose a console or try another search.'),
                  ),
                LayoutBuilder(
                  key: _resultsAnchor,
                  builder: (context, constraints) {
                    final columns = (constraints.maxWidth / 155).floor().clamp(2, 7);
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _games.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 22,
                        crossAxisSpacing: 18,
                        childAspectRatio: .68,
                      ),
                      itemBuilder: (_, index) {
                        final g = _games[index];
                        return FocusableWrapper(
                          key: ValueKey(g.id),
                          focusNode: index == 0 ? _firstResult : null,
                          onSelect: () => _open(g),
                          onNavigateUp: index < columns ? _tvSearch.focusInputWithoutOpening : null,
                          onFocusChange: (focused) {
                            if (focused) setState(() => _spotlight = g);
                          },
                          onNavigateLeft: index % columns == 0
                              ? () => MainScreenFocusScope.focusSidebarOf(context)
                              : null,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _open(g),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xff22222e),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: _art(g.cover, fit: BoxFit.contain),
                                  ),
                                ),
                                const SizedBox(height: 9),
                                Text(
                                  g.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                                ),
                                Text(
                                  g.systemName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
                if (_games.length < _total)
                  Padding(
                    padding: const EdgeInsets.all(22),
                    child: OutlinedButton(
                      onPressed: _loading ? null : () => _load(more: true),
                      child: const Text('Show more games'),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class GameArt extends StatelessWidget {
  const GameArt({super.key, required this.library, required this.path, this.fit = BoxFit.cover});
  final GameLibrary? library;
  final String? path;
  final BoxFit fit;
  @override
  Widget build(BuildContext context) {
    const fallback = Center(child: Icon(Icons.sports_esports_outlined, size: 54, color: Colors.white24));
    if (path == null || library == null) return fallback;
    return Image.network(
      library!.imageUrl(path!),
      headers: library!.headers,
      fit: fit,
      cacheWidth: 720,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

class GameDetailScreen extends StatefulWidget {
  const GameDetailScreen({super.key, required this.library, required this.game});
  final GameLibrary library;
  final LibraryGame game;
  @override
  State<GameDetailScreen> createState() => _GameDetailScreenState();
}

class _GameDetailScreenState extends State<GameDetailScreen> {
  final _playFocus = FocusNode(debugLabel: 'game.play');
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playFocus.requestFocus();
    });
  }

  bool _busy = false;
  String _status = '';
  double? _progress;
  String? _error;
  Future<void> _play(bool resume) async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Preparing game';
      _progress = null;
    });
    try {
      await widget.library.play(
        widget.game,
        resume: resume,
        progress: (status, progress) {
          if (mounted) {
            setState(() {
              _status = status;
              _progress = progress;
            });
          }
        },
      );
    } on GameCancelled {
      /* Back cancels preparation without an error. */
    } catch (error) {
      appLogger.w('Game could not start', error: error);
      if (mounted) setState(() => _error = error is PlatformException ? error.message : error.toString());
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _playFocus.requestFocus();
        });
      }
    }
  }

  @override
  void dispose() {
    if (_busy) widget.library.cancel();
    _playFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.game;
    return Focus(
      autofocus: true,
      skipTraversal: true,
      onKeyEvent: (_, event) => handleBackKeyNavigation(context, event),
      child: Scaffold(
        backgroundColor: _ink,
        appBar: AppBar(title: Text(g.systemName), backgroundColor: Colors.transparent),
        body: Stack(
          children: [
            Positioned.fill(
              child: Opacity(
                opacity: .18,
                child: GameArt(library: widget.library, path: g.background),
              ),
            ),
            SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: MediaQuery.sizeOf(context).width * .27,
                    height: 340,
                    child: GameArt(library: widget.library, path: g.cover, fit: BoxFit.contain),
                  ),
                  const SizedBox(width: 36),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          g.title,
                          style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          [
                            g.data['year'],
                            g.data['genre'],
                            if ((g.data['players'] as String? ?? '').isNotEmpty) '${g.data['players']} players',
                          ].where((v) => v != null && v != '').join('  •  '),
                          style: TextStyle(color: Theme.of(context).colorScheme.primary),
                        ),
                        const SizedBox(height: 24),
                        if (_busy) ...[
                          Text(_status),
                          const SizedBox(height: 12),
                          LinearProgressIndicator(value: _progress),
                          TextButton(autofocus: true, onPressed: widget.library.cancel, child: const Text('Cancel')),
                        ] else
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              FocusableWrapper(
                                focusNode: _playFocus,
                                onSelect: () => _play(true),
                                child: ExcludeFocus(
                                  child: FilledButton.icon(
                                    onPressed: () => _play(true),
                                    icon: const Icon(Icons.play_arrow),
                                    label: const Text('Play / Resume'),
                                  ),
                                ),
                              ),
                              FocusableWrapper(
                                onSelect: () => _play(false),
                                child: ExcludeFocus(
                                  child: OutlinedButton(
                                    onPressed: () => _play(false),
                                    child: const Text('Start fresh'),
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Favorite',
                                onPressed: () async {
                                  await widget.library.favorite(g);
                                  if (mounted) setState(() {});
                                },
                                icon: Icon(widget.library.isFavorite(g) ? Icons.favorite : Icons.favorite_border),
                              ),
                            ],
                          ),
                        if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_error!)),
                        const SizedBox(height: 24),
                        Text(
                          g.data['description'] as String? ?? '',
                          style: const TextStyle(color: Colors.white70, height: 1.5),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Connect a Bluetooth or USB controller to play. Press Back for the game menu. Progress saves when you return to Games.',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GamesSettingsScreen extends StatefulWidget {
  const GamesSettingsScreen({super.key, required this.library});
  final GameLibrary library;
  @override
  State<GamesSettingsScreen> createState() => _GamesSettingsScreenState();
}

class _GamesSettingsScreenState extends State<GamesSettingsScreen> {
  late final _url = TextEditingController(text: widget.library.base);
  late final _token = TextEditingController(text: widget.library.token);
  late int _cache = widget.library.cacheMB;
  late String _shader = widget.library.shader;
  String? _message;
  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      setState(() => _message = 'Enter the library address, such as http://192.0.2.10:8768');
      return;
    }
    final prefs = widget.library.prefs;
    await prefs.setString('games.url', _url.text.trim());
    await prefs.setString('games.token', _token.text.trim());
    await prefs.setInt('games.cacheMB', _cache);
    await prefs.setString('games.shader', _shader);
    try {
      final result = await widget.library.get('systems');
      if (mounted) setState(() => _message = 'Connected · ${result['games']} games. Settings saved.');
    } catch (_) {
      if (mounted) setState(() => _message = 'Settings saved. The library is not reachable yet.');
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    skipTraversal: true,
    onKeyEvent: (_, event) => handleBackKeyNavigation(context, event),
    child: Scaffold(
      appBar: AppBar(title: const Text('Game settings')),
      body: ListView(
        padding: const EdgeInsets.all(28),
        children: [
          const Text('Your library', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            decoration: const InputDecoration(labelText: 'Library address'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _token,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Library access key'),
          ),
          const SizedBox(height: 24),
          const Text('Picture'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            children: [
              for (final item in {'sharp': 'Sharp pixels', 'crt': 'CRT television', 'smooth': 'Smooth'}.entries)
                ChoiceChip(
                  label: Text(item.value),
                  selected: _shader == item.key,
                  onSelected: (_) => setState(() => _shader = item.key),
                ),
            ],
          ),
          const SizedBox(height: 24),
          const Text('Game cache limit'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            children: [
              for (final mb in [256, 512, 1024, 2048, 4096, 8192])
                ChoiceChip(
                  label: Text(mb < 1024 ? '$mb MB' : '${mb ~/ 1024} GB'),
                  selected: mb == _cache,
                  onSelected: (_) => setState(() => _cache = mb),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Games download as you play. Older cached games make room automatically. Your saves stay on the ONN and sync to your library when it is available.',
          ),
          const SizedBox(height: 24),
          const Text('Controllers', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'Pair a Bluetooth controller in Android TV Settings → Remotes & accessories, or plug in a USB controller. A/B/X/Y, shoulders, sticks, Start and Select use the standard Android layout. Back opens the pause and save menu.',
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: _save, child: const Text('Save and test connection')),
          if (_message != null) Padding(padding: const EdgeInsets.all(16), child: Text(_message!)),
        ],
      ),
    ),
  );
}
