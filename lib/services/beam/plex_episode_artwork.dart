import '../../utils/external_ids.dart';
import '../../utils/json_utils.dart';
import '../plex_discover_client.dart';
import 'show_episode_catalog.dart';

/// Presentation-only episode images. Plex numbering never changes catalog
/// identities, playback coordinates, or verified numbering evidence.
class PlexEpisodeArtwork {
  PlexEpisodeArtwork(this.client, {this.timeout = const Duration(seconds: 12)});

  final PlexDiscoverClient client;
  final Duration timeout;

  Future<Map<int, String>> load({
    required ShowEpisodeCatalogResult catalog,
    String? plexShowId,
    required int seasonNumber,
  }) async {
    var active = true;
    final result = <int, String>{};
    final requested = catalog.episodes.where((episode) => episode.seasonNumber == seasonNumber).toList();
    if (requested.isEmpty || seasonNumber < 0) return const {};

    Future<List<Map<String, dynamic>>?> children(String id) async {
      final rows = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (var page = 1; page <= 4 && active; page++) {
        final response = await client.getChildren(id, page: page);
        if (!active) return null;
        for (final row in response.items) {
          final key = _key(row['ratingKey']);
          if (key == null || !seen.add(key)) return null;
          rows.add(row);
        }
        if (!response.hasMore) return rows;
        if (response.items.isEmpty) return null;
      }
      return null;
    }

    Future<void> resolve() async {
      final ids = ExternalIds(imdb: catalog.imdbId, tvdb: catalog.tvdbId);
      final supplied = _key(plexShowId);
      if (plexShowId != null && supplied == null) return;
      var expectedId = supplied;
      var show = supplied != null ? await client.getMetadata(supplied) : await client.match(ids);
      final matchedByIds = supplied == null && ids.hasAny && show != null;
      if (!active) return;
      if (show == null && supplied == null && catalog.year != null && _normalize(catalog.name).isNotEmpty) {
        final search = await client.search(catalog.name, limit: 100);
        if (!active) return;
        final candidates = <String, Map<String, dynamic>>{};
        for (final result in search) {
          final row = result.metadata;
          final id = _key(row['ratingKey']);
          if (id != null &&
              row['type'] == 'show' &&
              flexibleInt(row['year']) == catalog.year &&
              _normalize(row['title']?.toString() ?? '') == _normalize(catalog.name)) {
            candidates[id] = row;
          }
        }
        if (candidates.length != 1) return;
        expectedId = candidates.keys.single;
        show = await client.getMetadata(expectedId);
      }
      if (!active || show == null || show['type'] != 'show') return;
      final showId = _key(show['ratingKey']);
      if (showId == null || (expectedId != null && showId != expectedId)) return;
      final actualIds = ExternalIds.fromGuids(show['Guid'] is List ? show['Guid'] as List : const []);
      if (_conflicts(ids, actualIds)) return;
      final exact =
          _normalize(show['title']?.toString() ?? '') == _normalize(catalog.name) &&
          catalog.year != null &&
          flexibleInt(show['year']) == catalog.year;
      // /matches verifies the supplied external ID; supplied IDs themselves
      // still need metadata verification before traversing any children.
      if (!exact && !ids.intersects(actualIds) && !matchedByIds) return;
      final seasons = await children(showId);
      if (!active || seasons == null) return;
      final gathered = <Map<String, dynamic>>[];
      var complete = true;
      for (final number in [
        seasonNumber,
        if (seasonNumber > 1) seasonNumber - 1,
        if (seasonNumber > 0) seasonNumber + 1,
      ]) {
        if (!active) return;
        final matching = seasons
            .where(
              (row) =>
                  row['type'] == 'season' &&
                  flexibleInt(row['index']) == number &&
                  row['parentRatingKey']?.toString() == showId,
            )
            .toList();
        if (matching.length != 1) {
          if (matching.length > 1) complete = false;
          continue;
        }
        final seasonId = _key(matching.single['ratingKey'])!;
        final rows = await children(seasonId);
        if (!active) return;
        if (rows == null) {
          complete = false;
          continue;
        }
        gathered.addAll(
          rows.where(
            (row) =>
                row['type'] == 'episode' &&
                row['parentRatingKey']?.toString() == seasonId &&
                row['grandparentRatingKey']?.toString() == showId &&
                flexibleInt(row['parentIndex']) == number,
          ),
        );
        result
          ..clear()
          ..addAll(_match(requested, catalog.episodes, gathered, allowCrossNumber: false));
        if (result.length == requested.length) return;
      }
      if (complete) {
        result
          ..clear()
          ..addAll(_match(requested, catalog.episodes, gathered));
      }
    }

    try {
      await resolve().timeout(timeout);
    } catch (_) {
      // Artwork failures must never hide the catalog or interfere with Play.
    } finally {
      active = false;
    }
    return Map.unmodifiable(result);
  }

  static Map<int, String> _match(
    List<ShowCatalogEpisode> requested,
    List<ShowCatalogEpisode> catalog,
    List<Map<String, dynamic>> rows, {
    bool allowCrossNumber = true,
  }) {
    final result = <int, String>{};
    final claims = <String, List<int>>{};
    for (final episode in requested) {
      final title = _normalize(episode.name);
      if (!_meaningful(title)) continue;
      final date = _date(episode.airdate);
      final matches = rows.where((row) {
        final rowTitle = row['title']?.toString() ?? '';
        if (!_meaningful(_normalize(rowTitle))) return false;
        final partAlias = _normalize(rowTitle) != title;
        if (partAlias && (_partTitle(episode.name) == null || _partTitle(episode.name) != _partTitle(rowTitle))) {
          return false;
        }
        final rawDate = row['originallyAvailableAt']?.toString();
        final rowDate = _date(rawDate);
        if ((episode.airdate != null && date == null) || (rawDate != null && rowDate == null)) return false;
        if (date != null && rowDate != null && date != rowDate) return false;
        if (partAlias && (date == null || rowDate != date)) return false;
        final sameNumber =
            flexibleInt(row['parentIndex']) == episode.seasonNumber &&
            flexibleInt(row['index']) == episode.episodeNumber &&
            episode.episodeNumber != null;
        if (sameNumber) return true;
        if (!allowCrossNumber || date == null || rowDate != date) return false;
        return catalog
                .where(
                  (other) =>
                      (_normalize(other.name) == title ||
                          (_partTitle(episode.name) != null && _partTitle(other.name) == _partTitle(episode.name))) &&
                      _date(other.airdate) == date,
                )
                .length ==
            1;
      }).toList();
      if (matches.length != 1) continue;
      final row = matches.single;
      final image = _image(row['thumb']);
      if (image == null) continue;
      result[episode.id] = image;
      claims.putIfAbsent(row['ratingKey'].toString(), () => []).add(episode.id);
    }
    for (final ids in claims.values.where((ids) => ids.length > 1)) {
      for (final id in ids) {
        result.remove(id);
      }
    }
    return result;
  }

  static String? _image(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasFragment ||
        uri.hasQuery ||
        !{'image.tmdb.org', 'metadata-static.plex.tv', 'images.plex.tv', 'artworks.thetvdb.com'}.contains(uri.host)) {
      return null;
    }
    return uri.toString();
  }

  static String? _key(Object? value) {
    final text = value?.toString();
    return text != null && RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(text) ? text : null;
  }

  static bool _conflicts(ExternalIds a, ExternalIds b) =>
      (a.imdb != null && b.imdb != null && a.imdb != b.imdb) || (a.tvdb != null && b.tvdb != null && a.tvdb != b.tvdb);
  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll('&amp;', '&')
      .replaceAll('&', ' and ')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  static bool _meaningful(String title) =>
      title.isNotEmpty && !RegExp(r'^(?:\d+|(?:episode|ep|part|chapter)\d+|s\d+e\d+)$').hasMatch(title);

  /// Artwork-only alias for "Reunion Part 1" / "Reunion (1)". The base
  /// title and exact part digits survive; this never joins or splits stories.
  static String? _partTitle(String value) {
    final match = RegExp(r'^(.+?)(?:\s+part\s*(\d+)|\s*\((\d+)\))\s*$', caseSensitive: false).firstMatch(value.trim());
    if (match == null) return null;
    final base = _normalize(match.group(1)!);
    if (!_meaningful(base) || {'episode', 'ep', 'part', 'chapter'}.contains(base)) return null;
    return '$base#part#${match.group(2) ?? match.group(3)}';
  }

  static String? _date(String? value) {
    if (value == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
    final date = DateTime.tryParse(value);
    return date != null && date.toIso8601String().startsWith(value) ? value : null;
  }
}
