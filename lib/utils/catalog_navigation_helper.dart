import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../models/catalog/catalog_item.dart';
import '../providers/catalog_sources_provider.dart';
import '../services/catalog/catalog_source.dart';
import '../screens/catalog_item_detail_screen.dart';
import '../screens/media_detail_screen.dart';
import '../services/beam/plex_public_discover.dart';
import '../services/beam/show_episode_catalog.dart';
import '../services/catalog/catalog_library_matcher.dart';

/// Explore, watchlist and related show cards open the same episode browser
/// as Search. Movies retain their catalog detail and automatic Play action.
Future<void> navigateToCatalogItem(
  BuildContext context,
  CatalogItem item, {
  ShowEpisodeCatalog? showEpisodeCatalog,
}) async {
  if (item.kind == MediaKind.show) {
    await navigateToCatalogShow(context, item, showEpisodeCatalog: showEpisodeCatalog);
    return;
  }
  await Navigator.push(context, MaterialPageRoute(builder: (_) => CatalogItemDetailScreen(item: item)));
}

/// A catalog identity is never a server identity. Prefer a verified library
/// show, otherwise let the shared browser merge the public episode catalog.
Future<void> navigateToCatalogShow(
  BuildContext context,
  CatalogItem item, {
  ShowEpisodeCatalog? showEpisodeCatalog,
}) async {
  if (item.kind != MediaKind.show) return;
  if (!context.mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
  // Push immediately: a slow lookup must not leave an unresponsive card or
  // navigate later after the user has already pressed Back.
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => _CatalogShowScreen(item: item, showEpisodeCatalog: showEpisodeCatalog),
    ),
  );
}

class _CatalogShowScreen extends StatefulWidget {
  const _CatalogShowScreen({required this.item, this.showEpisodeCatalog});
  final CatalogItem item;
  final ShowEpisodeCatalog? showEpisodeCatalog;

  @override
  State<_CatalogShowScreen> createState() => _CatalogShowScreenState();
}

class _CatalogShowScreenState extends State<_CatalogShowScreen> {
  CatalogLibraryMatcher? _matcher;
  CatalogSource? _source;
  Future<({CatalogItem item, List<MediaItem> matches})>? _matches;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final matcher = context.watch<CatalogLibraryMatcher>();
    final source = context.watch<CatalogSourcesProvider?>()?.connectedSources.firstWhereOrNull(
      (source) => source.id == widget.item.source,
    );
    if (identical(matcher, _matcher) && identical(source, _source)) return;
    _matcher = matcher;
    _source = source;
    _matches = _match(matcher, source);
  }

  Future<({CatalogItem item, List<MediaItem> matches})> _match(
    CatalogLibraryMatcher matcher,
    CatalogSource? source,
  ) async {
    var item = widget.item;
    if (source != null) {
      try {
        final detail = await source
            .fetchDetail(item, castLimit: 0, relatedLimit: 0)
            .timeout(const Duration(seconds: 3));
        final other = detail.item;
        final ids = item.ids.toJson();
        final otherIds = other.ids.toJson();
        final conflict = ids.entries.any((id) => otherIds.containsKey(id.key) && otherIds[id.key] != id.value);
        final sameIdentity =
            item.ids.allKeys.any(other.ids.allKeys.contains) ||
            (!item.ids.hasAny &&
                item.year != null &&
                item.title.trim().toLowerCase() == other.title.trim().toLowerCase() &&
                item.year == other.year);
        if (item.source == other.source && item.kind == other.kind && !conflict && sameIdentity) {
          item = item.enrichedWith(other);
        }
      } catch (_) {
        // Optional provider detail must not prevent the episode browser.
      }
    }
    if (!mounted || !identical(matcher, _matcher) || !identical(source, _source)) {
      return (item: item, matches: const <MediaItem>[]);
    }
    try {
      final matches = await matcher.match(item).timeout(const Duration(seconds: 5));
      return (item: item, matches: matches);
    } catch (_) {
      return (item: item, matches: const <MediaItem>[]);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<({CatalogItem item, List<MediaItem> matches})>(
    future: _matches,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      final item = snapshot.data?.item ?? widget.item;
      final owned = snapshot.data?.matches.firstWhereOrNull(
        (match) => match.kind == MediaKind.show && match.serverId?.isNotEmpty == true,
      );
      return MediaDetailScreen(
        key: ValueKey(owned?.globalKey ?? item.toMediaItem().id),
        metadata: owned ?? item.toMediaItem(),
        discoverItem: BeamDiscoverItem(
          title: item.title,
          year: item.year,
          kind: MediaKind.show,
          posterUrl: item.posterUrl,
          overview: item.overview,
          ratingKey: item.ids.plex,
        ),
        initialSeasonIndex: item.season?.agreedSeason,
        showEpisodeCatalog: widget.showEpisodeCatalog,
      );
    },
  );
}
