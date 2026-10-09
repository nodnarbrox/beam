import 'package:flutter/material.dart';

import '../focus/key_event_utils.dart';
import '../widgets/discovery_search_results.dart';
import '../services/youtube/youtube_service.dart';
import '../services/youtube/youtube_library.dart';
import '../profiles/active_profile_provider.dart';
import '../utils/app_logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

/// Uses the same integrated search and player as the main Search tab.
class YouTubeBrowseScreen extends StatefulWidget {
  const YouTubeBrowseScreen({super.key, this.query = '', this.title = 'YouTube', this.youtubeFactory});
  final String query;
  final String title;
  final YouTubeService Function()? youtubeFactory;

  @override
  State<YouTubeBrowseScreen> createState() => _YouTubeBrowseScreenState();
}

class _YouTubeBrowseScreenState extends State<YouTubeBrowseScreen> {
  late final _text = TextEditingController(text: widget.query);
  final _searchFocus = FocusNode();
  final _resultsFocus = FocusNode();
  late String _query = widget.query;
  late bool _focusWhenReady = widget.query.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_query.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resultsFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _searchFocus.dispose();
    _resultsFocus.dispose();
    super.dispose();
  }

  void _search(String query) {
    _text.text = query;
    _focusWhenReady = true;
    setState(() => _query = query);
    _resultsFocus.requestFocus();
    unawaited(_recordChannel(query));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_recordChannel(_query));
  }

  Future<void> _recordChannel(String query) async {
    final uri = Uri.tryParse(query);
    if (uri == null ||
        uri.host != 'www.youtube.com' ||
        uri.pathSegments.length < 2 ||
        uri.pathSegments.first != 'channel') {
      return;
    }
    final profile = context.read<ActiveProfileProvider?>()?.activeId ?? 'local';
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      await YouTubeLibrary(prefs, profile).recordChannelViewed(uri.pathSegments[1]);
    } catch (error, stack) {
      appLogger.w('YouTube channel history could not be saved', error: error, stackTrace: stack);
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: widget.query.isNotEmpty,
    skipTraversal: true,
    onKeyEvent: (_, event) => handleBackKeyNavigation(context, event),
    child: Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _text,
              focusNode: _searchFocus,
              autofocus: widget.query.isEmpty,
              textInputAction: TextInputAction.search,
              onSubmitted: _search,
              decoration: InputDecoration(
                hintText: 'Search videos, channels or playlists',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(onPressed: () => _search(_text.text), icon: const Icon(Icons.arrow_forward)),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: DiscoverySearchResults(
                query: _query,
                scope: SearchScope.youtube,
                libraryItems: const [],
                firstFocus: _resultsFocus,
                youtubeFactory: widget.youtubeFactory,
                onResultsReady: () {
                  if (!_focusWhenReady) return;
                  _focusWhenReady = false;
                  _resultsFocus.requestFocus();
                },
                onNavigateLeft: _searchFocus.requestFocus,
                onNavigateUp: _searchFocus.requestFocus,
                onQuery: _search,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
