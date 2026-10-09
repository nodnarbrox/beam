import 'dart:async';

import '../../media/catalog_item_ref.dart';
import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../providers/multi_server_provider.dart';
import '../../utils/external_ids.dart';
import '../../utils/media_server_http_client.dart' show AbortController;
import 'beam_episode_identity.dart';

/// Resolves only real items on currently visible, online library clients.
/// A miss, unavailable server, or ambiguous identity leaves Beam fallback free
/// to continue; this service never starts playback or downloads anything.
class BeamLibraryResolver {
  BeamLibraryResolver(this.provider, {this.timeout = const Duration(seconds: 4)});

  final MultiServerProvider provider;
  final Duration timeout;

  Future<MediaItem?> resolve({
    required String title,
    int? year,
    MediaItem? metadata,
    BeamEpisodeIdentity? episode,
  }) async {
    final requestedEpisode = episode ?? (metadata == null ? null : BeamEpisodeIdentity.fromMetadata(metadata));
    if (requestedEpisode == null && metadata != null && metadata.kind != MediaKind.movie) return null;
    final requestedTitle = requestedEpisode?.showTitle ?? title;
    if (_title(requestedTitle).isEmpty) return null;
    final kind = requestedEpisode == null ? MediaKind.movie : MediaKind.show;
    final identityMetadata = metadata?.kind == kind ? metadata : null;
    final ids = identityMetadata != null ? _externalIds(identityMetadata) : _showIds(requestedEpisode?.showId);
    final plexId = identityMetadata?.catalogItem?.ids.plex;
    final plexGuid = plexId?.isNotEmpty == true
        ? 'plex://${kind == MediaKind.movie ? 'movie' : 'show'}/$plexId'
        : _showPlexGuid(requestedEpisode?.showId);
    final requestedYear = requestedEpisode == null
        ? year ?? metadata?.year
        : _showYear(year, metadata, requestedEpisode);
    final servers = provider.onlineServerIds.toSet().toList();
    final answers = await Future.wait([
      for (final server in servers)
        _fromServer(server, requestedTitle, requestedYear, kind, ids, plexGuid, requestedEpisode),
    ]);
    if (answers.any((answer) => answer.ambiguous)) return null;
    final unique = <String, MediaItem>{};
    for (final answer in answers) {
      final item = answer.item;
      if (item != null && provider.onlineServerIds.contains(item.serverId)) {
        unique['${item.backend.name}:${item.serverId}:${item.id}'] = item;
      }
    }
    if (unique.isEmpty) return null;
    final available = unique.values.toList();
    if (available.length > 1 &&
        !answers.where((answer) => answer.item != null).every((answer) => answer.verified) &&
        !_equivalent(available, year: requestedYear, ids: requestedEpisode == null ? ids : const ExternalIds())) {
      return null;
    }
    // Prefer the original connected item when equivalent library copies exist.
    for (final item in available) {
      if (metadata?.serverId == item.serverId && metadata?.id == item.id) return item;
    }
    return available.first;
  }

  Future<({MediaItem? item, bool ambiguous, bool verified})> _fromServer(
    String server,
    String title,
    int? year,
    MediaKind kind,
    ExternalIds ids,
    String? plexGuid,
    BeamEpisodeIdentity? episode,
  ) async {
    const missing = (item: null, ambiguous: false, verified: false);
    var finished = false;
    final abort = AbortController();
    bool active() => !finished && provider.onlineServerIds.contains(server);
    Future<({MediaItem? item, bool ambiguous, bool verified})> lookup() async {
      final client = provider.getClientForServer(ServerId(server));
      if (client == null || client.serverId != server || client.isOfflineMode || !active()) return missing;
      MediaItem? match;
      var verified = false;
      if (ids.hasAny || plexGuid != null) {
        match = await client.findByExternalIds(ids, kind: kind, titles: [title], year: year, plexGuid: plexGuid);
        if (!active()) return missing;
        if (match != null && (!_owned(match, client, kind) || _conflicts(ids, _externalIds(match)))) return missing;
      }
      verified = match != null;
      if (match == null) {
        final results = await client.searchItems(title, limit: 100, abort: abort);
        if (!active()) return missing;
        final candidates = <String, MediaItem>{};
        for (final item in results) {
          if (_owned(item, client, kind) &&
              _title(item.title ?? '') == _title(title) &&
              (year == null || item.year == year) &&
              !_conflicts(ids, _externalIds(item)) &&
              !(plexGuid != null && item.guid?.startsWith('plex://') == true && item.guid != plexGuid)) {
            candidates[item.id] = item;
          }
        }
        if (candidates.length > 1 && !_equivalent(candidates.values.toList(), year: year, ids: ids)) {
          return (item: null, ambiguous: true, verified: false);
        }
        if (candidates.isEmpty) return missing;
        match = candidates.values.first;
        verified = ids.hasAny && candidates.values.every((item) => ids.intersects(_externalIds(item)));
      }
      if (episode == null) return (item: match, ambiguous: false, verified: verified);
      final show = match;
      final children = await client.fetchChildren(show.id);
      if (!active()) return missing;
      final seasons = children
          .where(
            (item) =>
                _owned(item, client, MediaKind.season) && item.parentId == show.id && item.index == episode.season,
          )
          .toList();
      if (seasons.length > 1) return (item: null, ambiguous: true, verified: false);
      if (seasons.isEmpty) return missing;
      final season = seasons.single;
      final rows = await client.fetchChildren(season.id);
      if (!active()) return missing;
      final ownedEpisodes = rows
          .where(
            (item) =>
                _owned(item, client, MediaKind.episode) &&
                item.parentId == season.id &&
                item.grandparentId == show.id &&
                item.parentIndex == episode.season,
          )
          .toList();
      if (_seasonConflict(ownedEpisodes, episode)) return missing;
      final matching = ownedEpisodes
          .where((item) => item.index == episode.episode && _storyMatches(item, episode))
          .toList();
      if (matching.length > 1) return (item: null, ambiguous: true, verified: false);
      return (item: matching.singleOrNull, ambiguous: false, verified: verified);
    }

    try {
      return await lookup().timeout(timeout);
    } catch (_) {
      return missing;
    } finally {
      finished = true;
      abort.abort();
    }
  }

  static bool _equivalent(List<MediaItem> items, {int? year, required ExternalIds ids}) {
    for (var i = 0; i < items.length; i++) {
      for (var j = i + 1; j < items.length; j++) {
        if (_conflicts(_externalIds(items[i]), _externalIds(items[j]))) return false;
      }
    }
    if (ids.hasAny && items.every((item) => ids.intersects(_externalIds(item)))) return true;
    // Every title-only candidate has already passed exact requested title/year.
    // Episode rows carry air years, so the verified parent show's year is used.
    return year != null;
  }

  static ExternalIds _showIds(String? value) {
    final match = RegExp(r'^(imdb|tmdb|tvdb):(?://)?(tt[0-9]+|[0-9]+)$').firstMatch(value ?? '');
    if (match == null) return const ExternalIds();
    final id = match.group(2)!;
    return switch (match.group(1)) {
      'imdb' when id.startsWith('tt') => ExternalIds(imdb: id),
      'tmdb' when int.tryParse(id) != null => ExternalIds(tmdb: int.parse(id)),
      'tvdb' when int.tryParse(id) != null => ExternalIds(tvdb: int.parse(id)),
      _ => const ExternalIds(),
    };
  }

  static String? _showPlexGuid(String? value) {
    if (value == null) return null;
    if (RegExp(r'^plex://show/[a-zA-Z0-9]+$').hasMatch(value)) return value;
    final match = RegExp(r'^plex:discover:([a-zA-Z0-9]+)$').firstMatch(value);
    return match == null ? null : 'plex://show/${match.group(1)}';
  }

  static bool _owned(MediaItem item, MediaServerClient client, MediaKind kind) =>
      item.kind == kind &&
      item.id.isNotEmpty &&
      item.serverId == client.serverId &&
      item.backend == client.backend &&
      item.raw?['beamCatalog'] != 'tvmaze' &&
      !item.isCatalogItem;

  static int? _showYear(int? year, MediaItem? metadata, BeamEpisodeIdentity episode) {
    if (metadata?.kind == MediaKind.show) return year ?? metadata?.year;
    final item = episode.metadata ?? metadata;
    if (item?.raw?['beamCatalog'] == 'tvmaze' || item?.serverId?.isNotEmpty != true) return year ?? episode.year;
    // Genuine server episode.year describes its air date, not its series.
    return null;
  }

  static ExternalIds _externalIds(MediaItem? item) {
    if (item == null) return const ExternalIds();
    final catalog = item.catalogItem;
    if (catalog != null && catalog.kind == item.kind) return catalog.ids.toExternalIds();
    final raw = item.raw;
    final guids = raw?['Guid'];
    final modern = guids is List ? ExternalIds.fromGuids(guids) : const ExternalIds();
    final providers = raw?['ProviderIds'];
    final jellyfin = providers is Map
        ? ExternalIds.fromJellyfinProviderIds(providers.cast<String, Object?>())
        : const ExternalIds();
    final legacy = ExternalIds.fromLegacyPlexGuid(item.guid ?? raw?['guid']);
    return ExternalIds(
      imdb: modern.imdb ?? jellyfin.imdb ?? legacy.imdb,
      tmdb: modern.tmdb ?? jellyfin.tmdb ?? legacy.tmdb,
      tvdb: modern.tvdb ?? jellyfin.tvdb ?? legacy.tvdb,
    );
  }

  static bool _conflicts(ExternalIds expected, ExternalIds actual) =>
      (expected.imdb != null && actual.imdb != null && expected.imdb != actual.imdb) ||
      (expected.tmdb != null && actual.tmdb != null && expected.tmdb != actual.tmdb) ||
      (expected.tvdb != null && actual.tvdb != null && expected.tvdb != actual.tvdb);

  static bool _storyMatches(MediaItem item, BeamEpisodeIdentity episode) {
    final requested = episode.metadata;
    if (requested?.raw?['beamCatalog'] != 'tvmaze') return true;
    if (!_meaningful(requested?.title)) return false;
    if (_meaningful(item.title)) return _title(item.title!) == _title(requested!.title!);
    return episode.storyConstraint == null; // Explicit verified broadcast numbering only.
  }

  static bool _seasonConflict(List<MediaItem> rows, BeamEpisodeIdentity episode) {
    final anchors = [if (episode.metadata != null) episode.metadata!, ...episode.episodeQueue];
    for (final expected in anchors) {
      if (expected.parentIndex != episode.season || !_meaningful(expected.title)) continue;
      for (final actual in rows.where((item) => item.index == expected.index)) {
        if (_meaningful(actual.title) && _title(actual.title!) != _title(expected.title!)) return true;
      }
    }
    return false;
  }

  static String _title(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&', ' and ')
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  static bool _meaningful(String? value) {
    final normalized = _title(value ?? '');
    return normalized.isNotEmpty && !RegExp(r'^(?:(?:episode|ep|chapter|part)\d+|s\d+e\d+)$').hasMatch(normalized);
  }
}
