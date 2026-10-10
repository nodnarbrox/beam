import 'package:plezy/theme/lc_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../mixins/refreshable.dart';
import '../../focus/dpad_navigator.dart';
import '../../focus/key_event_utils.dart';
import '../../navigation/main_screen_scope.dart';

import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../providers/libraries_provider.dart';
import '../../services/library_query_translator.dart';
import '../../utils/provider_extensions.dart';
import '../../widgets/focusable_media_card.dart';

/// Flat, non-GPU shelf used when Flutter GPU / `flutter_scene` is unavailable
/// (older devices, GPU flag off). Same catalog, same OK-to-play behavior — it
/// just paints a scrollable grid of poster "boxes" instead of a 3D aisle, so
/// the store tab is never a dead end.
class VideoStore2DFallback extends StatefulWidget {
  const VideoStore2DFallback({super.key, required this.halloween});

  final bool halloween;

  @override
  State<VideoStore2DFallback> createState() => VideoStore2DFallbackState();
}

class VideoStore2DFallbackState extends State<VideoStore2DFallback> implements FocusableTab {
  final _contentFocus = FocusNode();
  final _firstCardFocus = FocusNode();
  bool _pendingFocus = false;

  bool get hasContentFocus => _contentFocus.hasFocus || _firstCardFocus.hasFocus;

  @override
  void focusActiveTabIfReady() {
    _pendingFocus = true;
    if (_loading) {
      _contentFocus.requestFocus();
    } else if (_shelves.isEmpty) {
      _contentFocus.requestFocus();
    } else {
      _firstCardFocus.requestFocus();
    }
  }

  @override
  void dispose() {
    _contentFocus.dispose();
    _firstCardFocus.dispose();
    super.dispose();
  }

  bool _loading = true;
  final List<_Shelf> _shelves = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final libraries = context.read<LibrariesProvider>().libraries.where((lib) {
      final k = lib.kind;
      return k == MediaKind.movie || k == MediaKind.show || k == MediaKind.unknown;
    }).toList();

    for (final library in libraries) {
      try {
        final client = context.getMediaClientForLibrary(library);
        final query = libraryQueryFromPlexMap(map: const {}, libraryKind: library.kind, offset: 0, limit: 60);
        final page = await client.fetchLibraryPagedContent(library.id, query: query, libraryKind: library.kind);
        if (page.items.isNotEmpty) {
          _shelves.add(_Shelf(name: library.title, items: page.items));
        }
      } catch (_) {
        // Server offline / not signed in for this library — skip its shelf.
      }
    }
    if (mounted) {
      setState(() => _loading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pendingFocus && _contentFocus.hasFocus) {
          focusActiveTabIfReady();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _contentFocus,
      onKeyEvent: (node, event) {
        if (event.logicalKey.isBackKey) {
          return handleBackKeyAction(event, () {
            _pendingFocus = false;
            MainScreenFocusScope.focusSidebarOf(context);
          });
        }
        if (event is KeyDownEvent && _shelves.isEmpty && event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _pendingFocus = false;
          MainScreenFocusScope.focusSidebarOf(context);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: _buildShelves(context),
    );
  }

  Widget _buildShelves(BuildContext context) {
    final bg = widget.halloween ? const Color(0xFF07080C) : LcColors.charcoal;
    const accent = LcColors.pink;

    if (_loading) {
      return ColoredBox(
        color: bg,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_shelves.isEmpty) {
      return ColoredBox(
        color: bg,
        child: const Center(
          child: Text(
            'No titles on the shelves.\nSign in to a Plex or Jellyfin server.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 18),
          ),
        ),
      );
    }

    return ColoredBox(
      color: bg,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              child: Row(
                children: [
                  Icon(Icons.videocam_rounded, color: accent, size: 30),
                  const SizedBox(width: 10),
                  Text(
                    widget.halloween ? 'BLOCKBUSTA' : 'BEAM VIDEO',
                    style: TextStyle(color: accent, fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 3),
                  ),
                ],
              ),
            ),
          ),
          for (final shelf in _shelves) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                child: Text(
                  shelf.name,
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 240,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  itemCount: shelf.items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, i) => SizedBox(
                    width: 130,
                    child: FocusableMediaCard(
                      focusNode: shelf == _shelves.first && i == 0 ? _firstCardFocus : null,
                      onNavigateLeft: i == 0 ? () => MainScreenFocusScope.focusSidebarOf(context) : null,
                      onBack: () => MainScreenFocusScope.focusSidebarOf(context),
                      item: shelf.items[i],
                      width: 130,
                      height: 195,
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

class _Shelf {
  _Shelf({required this.name, required this.items});
  final String name;
  final List<MediaItem> items;
}
