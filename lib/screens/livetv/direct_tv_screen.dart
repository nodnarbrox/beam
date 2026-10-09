import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../focus/focusable_text_field.dart';
import '../../mixins/refreshable.dart';
import '../../navigation/main_screen_scope.dart';
import '../../services/direct_tv_service.dart';
import '../../utils/video_player_navigation.dart';
import '../video_player_screen.dart';
import 'live_tv_screen.dart';

/// Direct playback uses the shared TV tuner, independent of Plex sign-in.
class DirectTvScreen extends StatefulWidget {
  final bool hasServerGuide;
  final DirectTvService Function(String)? serviceFactory;
  final Future<void> Function(BuildContext, DirectTvChannel)? playChannel;

  const DirectTvScreen({super.key, this.hasServerGuide = false, this.serviceFactory, this.playChannel});

  @override
  State<DirectTvScreen> createState() => _DirectTvScreenState();
}

class _DirectTvScreenState extends State<DirectTvScreen> with FocusableTab, Refreshable, SearchInputFocusable {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _firstChannel = FocusNode(debugLabel: 'directTv.firstChannel');
  final _tvSearch = TvTextInputController();
  DirectTvService? _service;
  SharedPreferences? _prefs;
  DirectTvLineup? _lineup;
  String _address = DirectTvService.defaultAddress;
  String? _error;
  bool _loading = true;
  bool _majorOnly = false;
  bool _favoritesOnly = false;
  bool _opening = false;
  Set<String> _favorites = {};
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void focusActiveTabIfReady() => _searchFocus.requestFocus();
  @override
  void focusSearchInput() => _searchFocus.requestFocus();
  @override
  void submitSearchQuery(String query) => setState(() => _search.text = query);
  @override
  void refresh() => _load();

  void _focusResults() {
    _tvSearch.closeTextInput();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _firstChannel.context != null) _firstChannel.requestFocus();
    });
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || generation != _generation) return;
      _prefs = prefs;
      _address = prefs.getString('direct_tv_address') ?? DirectTvService.defaultAddress;
      if (_address.trim().isEmpty) {
        setState(() {
          _lineup = null;
          _loading = false;
          _error = 'Add your TV service address in Settings to load channels.';
        });
        return;
      }
      _favorites = (prefs.getStringList('direct_tv_favorites:$_address') ?? []).toSet();
      _service?.close();
      final service = widget.serviceFactory?.call(_address) ?? DirectTvService(_address);
      _service = service;
      final lineup = await service.load();
      if (!mounted || generation != _generation) return;
      setState(() {
        _lineup = lineup;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = 'Could not load Live TV. Check the TV service address and your network, then retry.';
      });
    }
  }

  Future<void> _configure() async {
    final controller = TextEditingController(text: _address);
    String? validation;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('TV service'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Use the same TV service as Plex. Plezy plays its channels directly.'),
                const SizedBox(height: 16),
                FocusableTextField(
                  controller: controller,
                  autofocus: true,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: 'Service address', errorText: validation),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                try {
                  final address = DirectTvService.parseAddress(controller.text).toString();
                  Navigator.pop(context, address);
                } on FormatException catch (e) {
                  update(() => validation = e.message);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    // The dialog's text field may still be animating out when the future ends.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (result == null || !mounted) return;
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setString('direct_tv_address', result);
    if (mounted) await _load();
  }

  Future<void> _favorite(DirectTvChannel channel) async {
    setState(() {
      if (!_favorites.remove(channel.number)) _favorites.add(channel.number);
    });
    await _prefs?.setStringList('direct_tv_favorites:$_address', _favorites.toList());
  }

  Future<void> _play(DirectTvChannel channel) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      if (widget.playChannel != null) {
        await widget.playChannel!(context, channel);
      } else {
        await Navigator.of(context).push(
          buildVideoPlayerRoute(
            builder: (_) =>
                VideoPlayerScreen.direct(url: channel.stream.toString(), title: channel.name, directStreamIsLive: true),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    ++_generation;
    _service?.close();
    _search.dispose();
    _searchFocus.dispose();
    _firstChannel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lineup = _lineup;
    final query = _search.text.trim().toLowerCase();
    final channels = (lineup?.channels ?? <DirectTvChannel>[])
        .where(
          (channel) =>
              (!_majorOnly || lineup!.majorNetworks.contains(channel.number)) &&
              (!_favoritesOnly || _favorites.contains(channel.number)) &&
              (query.isEmpty || channel.name.toLowerCase().contains(query) || channel.number.contains(query)),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live TV'),
        actions: [
          if (widget.hasServerGuide)
            TextButton(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const LiveTvScreen())),
              child: const Text('Plex / Jellyfin guide'),
            ),
          IconButton(tooltip: 'Refresh channels', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
          IconButton(tooltip: 'TV service settings', onPressed: _configure, icon: const Icon(Icons.settings)),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            FocusableTextField(
              controller: _search,
              focusNode: _searchFocus,
              tvTextInputController: _tvSearch,
              tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
              textInputAction: TextInputAction.search,
              onNavigateDown: _focusResults,
              onEditingComplete: _focusResults,
              onNavigateLeft: () => MainScreenFocusScope.focusSidebarOf(context),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Search channels', prefixIcon: Icon(Icons.search)),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (lineup?.majorNetworks.isNotEmpty ?? false)
                  FilterChip(
                    label: const Text('Major networks'),
                    selected: _majorOnly,
                    onSelected: (v) => setState(() => _majorOnly = v),
                  ),
                FilterChip(
                  label: const Text('Favorites'),
                  selected: _favoritesOnly,
                  onSelected: (v) => setState(() => _favoritesOnly = v),
                ),
                Text('${channels.length} channels · Direct playback'),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: _address.trim().isEmpty ? _configure : _load,
                            child: Text(_address.trim().isEmpty ? 'Add TV service' : 'Retry'),
                          ),
                        ],
                      ),
                    )
                  : channels.isEmpty
                  ? const Center(child: Text('No matching channels.'))
                  : ListView.builder(
                      itemCount: channels.length,
                      itemBuilder: (context, index) {
                        final channel = channels[index];
                        return ListTile(
                          focusNode: index == 0 ? _firstChannel : null,
                          leading: SizedBox(width: 48, child: Text(channel.number)),
                          title: Text(channel.name),
                          onTap: _opening ? null : () => _play(channel),
                          trailing: IconButton(
                            tooltip: _favorites.contains(channel.number) ? 'Remove favorite' : 'Add favorite',
                            icon: Icon(_favorites.contains(channel.number) ? Icons.star : Icons.star_border),
                            onPressed: () => _favorite(channel),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
