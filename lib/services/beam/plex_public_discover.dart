import 'dart:convert';

import 'package:plezy/utils/app_logger.dart';

import '../../media/media_kind.dart';
import '../../models/catalog/catalog_item.dart';
import 'beam_http.dart';

/// A poster-search result from Plex's PUBLIC Discover provider — no Plex
/// account or token required. Verified: `discover.provider.plex.tv/library/
/// search?searchProviders=discover&searchTypes=movies,tv` returns full metadata
/// (title, year, thumb/art) anonymously, and the metadata-static.plex.tv poster
/// URLs load without auth. This is what powers the Plex-style poster grid for
/// unsigned-in users.
class BeamDiscoverItem {
  BeamDiscoverItem({
    required this.title,
    required this.kind,
    this.year,
    this.posterUrl,
    this.overview,
    this.guid,
    this.ratingKey,
    this.seasonCount = 0,
  });

  final String title;
  final MediaKind kind;
  final int? year;
  final String? posterUrl;
  final String? overview;
  final String? guid;

  /// Plex Discover ratingKey — used to fetch the full detail (RT rating, cast).
  final String? ratingKey;

  /// Number of seasons (from Discover search `childCount`, anonymous — no auth).
  /// Used to build the season list when the authenticated /children endpoint
  /// 401s. 0 = unknown.
  final int seasonCount;

  /// The query handed to the indexer/resolve flow — title + year narrows it.
  String get searchQuery => year != null ? '$title $year' : title;

  /// Rendering-only catalog identity. A Discover id is never a library id.
  CatalogItem toCatalogItem({BeamDiscoverDetail? detail}) => CatalogItem(
    source: CatalogSourceId.plex,
    kind: kind,
    title: title,
    year: year,
    overview: overview,
    posterUrl: posterUrl,
    backdropUrl: detail?.artUrl,
    runtimeMinutes: detail?.durationMinutes,
    certification: detail?.contentRating,
    rating: detail?.criticRating,
    genres: detail?.genres,
    ids: CatalogItemIds(plex: guid?.split('/').last ?? ratingKey),
  );
}

/// A season of a show, from Plex Discover children. [episodeCount] drives how
/// many episodes to probe/populate (E01..E{episodeCount}).
class BeamSeason {
  BeamSeason({required this.seasonNumber, required this.episodeCount});
  final int seasonNumber;
  final int episodeCount;
}

/// One cast member on a Plex-style detail page.
class BeamCastMember {
  BeamCastMember({required this.name, this.role, this.thumbUrl});
  final String name;
  final String? role;
  final String? thumbUrl;
}

/// Full detail for the Plex-style info page (fetched by ratingKey).
class BeamDiscoverDetail {
  BeamDiscoverDetail({
    required this.item,
    this.tagline,
    this.contentRating,
    this.durationMinutes,
    this.genres = const [],
    this.directors = const [],
    this.cast = const [],
    this.artUrl,
    this.criticRating, // 0–10 (Plex `rating`)
    this.audienceRating, // 0–10 (Plex `audienceRating`)
    this.criticIsRottenTomatoes = false,
  });

  final BeamDiscoverItem item;
  final String? tagline;
  final String? contentRating;
  final int? durationMinutes;
  final List<String> genres;
  final List<String> directors;
  final List<BeamCastMember> cast;
  final String? artUrl;
  final double? criticRating;
  final double? audienceRating;
  final bool criticIsRottenTomatoes;

  /// Rotten Tomatoes-style critic percentage (Plex rating is 0–10 → 0–100%).
  int? get criticPercent => criticRating == null ? null : (criticRating! * 10).round();
  int? get audiencePercent => audienceRating == null ? null : (audienceRating! * 10).round();
}

/// Keyless client for Plex's public Discover search.
class PlexPublicDiscover {
  PlexPublicDiscover();

  static const _base = 'https://discover.provider.plex.tv';

  // A stable anonymous client identity. Plex requires these headers but not a
  // user token for discover search.
  static const _headers = {
    'Accept': 'application/json',
    'X-Plex-Product': 'Plezy',
    'X-Plex-Client-Identifier': 'mediabeam-anon',
    'X-Plex-Version': '2',
  };

  /// Searches movies + shows. [kind] null = both. Returns poster items.
  Future<List<BeamDiscoverItem>> search(
    String query, {
    MediaKind? kind,
    int limit = 40,
    bool throwOnError = false,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final searchTypes = switch (kind) {
      MediaKind.movie => 'movies',
      MediaKind.show => 'tv',
      _ => 'movies,tv',
    };

    final uri = Uri.parse('$_base/library/search').replace(
      queryParameters: {'query': q, 'searchProviders': 'discover', 'searchTypes': searchTypes, 'limit': '$limit'},
    );

    // Discover is a public internet endpoint; route it through the proxy like
    // every other outbound Beam request.
    final client = await BeamHttp.client();
    try {
      final r = await client.get(uri, headers: _headers).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) {
        appLogger.w('Plex public discover HTTP ${r.statusCode}');
        if (throwOnError) throw StateError('Catalog search returned HTTP ${r.statusCode}');
        return const [];
      }
      return _parse(r.body);
    } catch (e) {
      appLogger.w('Plex public discover failed: $e');
      if (throwOnError) rethrow;
      return const [];
    } finally {
      client.close();
    }
  }

  /// Fetches the full Plex Discover detail for [ratingKey] — description,
  /// Rotten Tomatoes rating, cast, director, genres. Public, no token.
  Future<BeamDiscoverDetail?> detail(BeamDiscoverItem item) async {
    final rk = item.ratingKey;
    if (rk == null || rk.isEmpty) return null;
    final uri = Uri.parse(
      '$_base/library/metadata/$rk',
    ).replace(queryParameters: {'X-Plex-Product': 'Plezy', 'X-Plex-Client-Identifier': 'mediabeam-anon'});
    final client = await BeamHttp.client();
    try {
      final r = await client.get(uri, headers: _headers).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) {
        appLogger.w('Plex discover detail HTTP ${r.statusCode}');
        return BeamDiscoverDetail(item: item); // minimal — still show the page
      }
      final json = jsonDecode(r.body);
      final list = (json is Map) ? (json['MediaContainer'] is Map ? json['MediaContainer']['Metadata'] : null) : null;
      final meta = (list is List && list.isNotEmpty && list.first is Map) ? list.first as Map : null;
      if (meta == null) return BeamDiscoverDetail(item: item);

      final ratingImage = '${meta['ratingImage']}';
      final cast = <BeamCastMember>[];
      if (meta['Role'] is List) {
        for (final role in (meta['Role'] as List).whereType<Map>()) {
          final name = _str(role['tag']);
          if (name == null) continue;
          cast.add(BeamCastMember(name: name, role: _str(role['role']), thumbUrl: _str(role['thumb'])));
        }
      }
      List<String> tags(String key) => (meta[key] is List)
          ? [
              for (final e in (meta[key] as List).whereType<Map>())
                if (_str(e['tag']) != null) _str(e['tag'])!,
            ]
          : const [];

      return BeamDiscoverDetail(
        item: item,
        tagline: _str(meta['tagline']),
        contentRating: _str(meta['contentRating']),
        durationMinutes: meta['duration'] is int ? (meta['duration'] as int) ~/ 60000 : null,
        genres: tags('Genre'),
        directors: tags('Director'),
        cast: cast,
        artUrl: _str(meta['art']),
        criticRating: (meta['rating'] is num) ? (meta['rating'] as num).toDouble() : null,
        audienceRating: (meta['audienceRating'] is num) ? (meta['audienceRating'] as num).toDouble() : null,
        criticIsRottenTomatoes: ratingImage.contains('rottentomatoes'),
      );
    } catch (e) {
      appLogger.w('Plex discover detail failed: $e');
      return BeamDiscoverDetail(item: item);
    } finally {
      client.close();
    }
  }

  /// Fetches a show's seasons (number + episode count). Tries the Discover
  /// /children endpoint first (gives exact per-season episode counts) but that
  /// endpoint requires auth and 401s anonymously — so on any failure it falls
  /// back to generating seasons 1..[fallbackSeasonCount] with an unknown episode
  /// count (0), which the season tile then discovers by probing. This makes the
  /// episode browser work for ANY show without a Plex token.
  Future<List<BeamSeason>> seasons(String ratingKey, {int fallbackSeasonCount = 0}) async {
    final children = await _seasonsFromChildren(ratingKey);
    if (children.isNotEmpty) return children;
    if (fallbackSeasonCount > 0) {
      return [for (var i = 1; i <= fallbackSeasonCount; i++) BeamSeason(seasonNumber: i, episodeCount: 0)];
    }
    return const [];
  }

  Future<List<BeamSeason>> _seasonsFromChildren(String ratingKey) async {
    if (ratingKey.isEmpty) return const [];
    final uri = Uri.parse(
      '$_base/library/metadata/$ratingKey/children',
    ).replace(queryParameters: {'X-Plex-Product': 'Plezy', 'X-Plex-Client-Identifier': 'mediabeam-anon'});
    final client = await BeamHttp.client();
    try {
      final r = await client.get(uri, headers: _headers).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) {
        appLogger.w('Plex discover children HTTP ${r.statusCode}');
        return const [];
      }
      final json = jsonDecode(r.body);
      final list = (json is Map && json['MediaContainer'] is Map) ? json['MediaContainer']['Metadata'] : null;
      if (list is! List) return const [];
      final out = <BeamSeason>[];
      for (final s in list.whereType<Map>()) {
        if ('${s['type']}' != 'season') continue;
        final idx = s['index'];
        final seasonNum = idx is int ? idx : int.tryParse('$idx') ?? -1;
        if (seasonNum <= 0) continue; // skip specials / Season 0
        final leaf = s['leafCount'];
        final epCount = leaf is int ? leaf : int.tryParse('$leaf') ?? 0;
        out.add(BeamSeason(seasonNumber: seasonNum, episodeCount: epCount));
      }
      out.sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
      return out;
    } catch (e) {
      appLogger.w('Plex discover children failed: $e');
      return const [];
    } finally {
      client.close();
    }
  }

  List<BeamDiscoverItem> _parse(String body) {
    final out = <BeamDiscoverItem>[];
    final seen = <String>{};
    dynamic json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    final container = (json is Map) ? json['MediaContainer'] : null;
    final results = (container is Map) ? container['SearchResults'] : null;
    if (results is! List) return const [];

    for (final group in results.whereType<Map>()) {
      final inner = group['SearchResult'];
      if (inner is! List) continue;
      for (final entry in inner.whereType<Map>()) {
        final meta = entry['Metadata'];
        if (meta is! Map) continue;
        final type = '${meta['type']}';
        if (type != 'movie' && type != 'show') continue;
        final title = (meta['title'] ?? '').toString().trim();
        if (title.isEmpty) continue;
        final guid = meta['guid']?.toString();
        // De-dup by guid (same title can appear across provider groups).
        final key = guid ?? '$title|${meta['year']}';
        if (!seen.add(key)) continue;

        out.add(
          BeamDiscoverItem(
            title: title,
            kind: type == 'show' ? MediaKind.show : MediaKind.movie,
            year: (meta['year'] is int) ? meta['year'] as int : int.tryParse('${meta['year']}'),
            // thumb (poster) preferred; art (backdrop) as a fallback image.
            posterUrl: _str(meta['thumb']) ?? _str(meta['art']),
            overview: _str(meta['summary']),
            guid: guid,
            ratingKey: _str(meta['ratingKey']),
            seasonCount: (meta['childCount'] is int)
                ? meta['childCount'] as int
                : int.tryParse('${meta['childCount']}') ?? 0,
          ),
        );
      }
    }
    return out;
  }

  static String? _str(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }
}
