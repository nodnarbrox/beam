import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'beam_http.dart';

part 'show_episode_numbering.dart';

class ShowEpisodeCatalogUnavailable implements Exception {
  const ShowEpisodeCatalogUnavailable(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'Episode catalog unavailable: $message';
}

class ShowCatalogEpisode {
  const ShowCatalogEpisode({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.name,
    required this.sourceUrl,
    this.airdate,
    this.airStamp,
    this.imageUrl,
    this.summary,
    this.type,
    this.runtimeMinutes,
  });
  final int id;
  final int seasonNumber;
  final int? episodeNumber;
  final String name;
  final String sourceUrl;
  final String? airdate;
  final DateTime? airStamp;
  final String? imageUrl;
  final String? summary;
  final String? type;
  final int? runtimeMinutes;
  bool get isSpecial => seasonNumber == 0 || type == 'significant_special' || type == 'insignificant_special';
}

class ShowCatalogSeason {
  const ShowCatalogSeason({
    this.id,
    required this.number,
    this.name,
    this.premiereDate,
    this.endDate,
    this.imageUrl,
    this.summary,
    this.episodes = const [],
  });
  final int? id;
  final int number;
  final String? name;
  final String? premiereDate;
  final String? endDate;
  final String? imageUrl;
  final String? summary;
  final List<ShowCatalogEpisode> episodes;
}

class ShowEpisodeCatalogResult {
  const ShowEpisodeCatalogResult({
    required this.tvmazeId,
    required this.name,
    required this.sourceUrl,
    this.premiered,
    this.imdbId,
    this.tvdbId,
    this.imageUrl,
    this.summary,
    this.seasons = const [],
    this.episodes = const [],
    this.aliases = const [],
    this.aliasesComplete = true,
    this.numberingChecked = false,
    this.numberingEvidence = const {},
  });
  final int tvmazeId;
  final String name;
  final String sourceUrl;
  final String? premiered;
  final String? imdbId;
  final int? tvdbId;
  final String? imageUrl;
  final String? summary;
  final List<ShowCatalogSeason> seasons;
  final List<ShowCatalogEpisode> episodes;
  final List<String> aliases;

  /// False means the optional AKA request failed, not that no aliases exist.
  final bool aliasesComplete;
  final bool numberingChecked;
  final Map<int, VerifiedEpisodeNumbering> numberingEvidence;

  ShowEpisodeCatalogResult withAliases(List<String> names) => ShowEpisodeCatalogResult(
    tvmazeId: tvmazeId,
    name: name,
    sourceUrl: sourceUrl,
    premiered: premiered,
    imdbId: imdbId,
    tvdbId: tvdbId,
    imageUrl: imageUrl,
    summary: summary,
    seasons: seasons,
    episodes: episodes,
    aliases: List.unmodifiable(names),
    aliasesComplete: true,
    numberingChecked: numberingChecked,
    numberingEvidence: numberingEvidence,
  );
  ShowEpisodeCatalogResult withNumbering(Map<int, VerifiedEpisodeNumbering> evidence) => ShowEpisodeCatalogResult(
    tvmazeId: tvmazeId,
    name: name,
    sourceUrl: sourceUrl,
    premiered: premiered,
    imdbId: imdbId,
    tvdbId: tvdbId,
    imageUrl: imageUrl,
    summary: summary,
    seasons: seasons,
    episodes: episodes,
    aliases: aliases,
    aliasesComplete: aliasesComplete,
    numberingChecked: true,
    numberingEvidence: Map.unmodifiable(evidence),
  );
  String get attributionName => 'TVmaze';
  int? get year => premiered == null ? null : DateTime.tryParse(premiered!)?.year;
}

/// TVmaze metadata only: a listed episode is not proof that it can be played.
/// API and attribution requirements: https://www.tvmaze.com/api
class ShowEpisodeCatalog {
  ShowEpisodeCatalog({
    Future<http.Client> Function()? clientFactory,
    DateTime Function()? now,
    this.timeout = const Duration(seconds: 20),
    this.cacheTtl = const Duration(hours: 1),
  }) : _clientFactory = clientFactory ?? BeamHttp.client,
       _now = now ?? DateTime.now;

  static final instance = ShowEpisodeCatalog();
  final Future<http.Client> Function() _clientFactory;
  final DateTime Function() _now;
  final Duration timeout;
  final Duration cacheTtl;
  final _cache = <String, (DateTime, ShowEpisodeCatalogResult?)>{};
  final _pending = <String, Future<ShowEpisodeCatalogResult?>>{};
  final _pendingAliases = <int, Future<List<String>?>>{};
  final _numberingCache = <String, (DateTime, Map<int, VerifiedEpisodeNumbering>)>{};
  final _pendingNumbering = <String, Future<Map<int, VerifiedEpisodeNumbering>?>>{};

  /// Optional broadcast-order corroboration for this exact catalog snapshot.
  Future<ShowEpisodeCatalogResult> verifyNumbering(ShowEpisodeCatalogResult catalog) =>
      _verifyCatalogNumbering(catalog);

  /// External IDs take precedence. Without IDs, both an exact title and a
  /// premiere year are required, and the match must be unique. Unknown or
  /// ambiguous identity returns null; transport/invalid-data failures throw.
  Future<ShowEpisodeCatalogResult?> load({required String title, int? year, String? imdbId, int? tvdbId}) {
    final imdb = imdbId?.trim().toLowerCase();
    if ((imdb != null && imdb.isNotEmpty && !RegExp(r'^tt\d+$').hasMatch(imdb)) || (tvdbId != null && tvdbId <= 0)) {
      return Future.value(null);
    }
    final normalizedImdb = imdb == null || imdb.isEmpty ? null : imdb;
    if (normalizedImdb == null && tvdbId == null && (_normalize(title).isEmpty || year == null)) {
      return Future.value(null);
    }
    final key = jsonEncode([_normalize(title), year, normalizedImdb, tvdbId]);
    final cached = _cache[key];
    if (cached != null && _now().isBefore(cached.$1)) {
      final result = cached.$2;
      return result != null && !result.aliasesComplete ? retryAliases(result) : Future.value(result);
    }
    return _pending.putIfAbsent(key, () => _loadAndCache(key, title, year, normalizedImdb, tvdbId));
  }

  /// Retry only the optional names for the already verified show ID. A failed
  /// retry retains all healthy metadata and may be retried on the next Play.
  Future<ShowEpisodeCatalogResult> retryAliases(ShowEpisodeCatalogResult catalog) async {
    if (catalog.aliasesComplete || catalog.tvmazeId <= 0) return catalog;
    for (final cached in _cache.values) {
      final result = cached.$2;
      if (_now().isBefore(cached.$1) && result?.tvmazeId == catalog.tvmazeId && result!.aliasesComplete) {
        return catalog.withAliases(result.aliases);
      }
    }
    final pending = _pendingAliases.putIfAbsent(catalog.tvmazeId, () => _fetchAliases(catalog.tvmazeId));
    final aliases = await pending;
    if (identical(_pendingAliases[catalog.tvmazeId], pending)) {
      unawaited(_pendingAliases.remove(catalog.tvmazeId));
    }
    if (aliases == null) return catalog;
    for (final key in _cache.keys.toList()) {
      final cached = _cache[key]!;
      if (cached.$2?.tvmazeId == catalog.tvmazeId) {
        _cache[key] = (cached.$1, cached.$2!.withAliases(aliases));
      }
    }
    return catalog.withAliases(aliases);
  }

  Future<List<String>?> _fetchAliases(int showId) async {
    http.Client? client;
    var finished = false;
    void checkActive() {
      if (finished) throw const ShowEpisodeCatalogUnavailable('Alias request expired');
    }

    Future<List<String>> fetch() async {
      final created = await _clientFactory();
      if (finished) {
        created.close();
        throw const ShowEpisodeCatalogUnavailable('Alias request expired');
      }
      client = created;
      return _aliasNames(await _get(created, '/shows/$showId/akas', const {}, checkActive));
    }

    try {
      return await fetch().timeout(const Duration(seconds: 3));
    } catch (_) {
      return null;
    } finally {
      finished = true;
      client?.close();
    }
  }

  static List<String> _aliasNames(Object? value) =>
      _list(value).map((row) => _string(row['name'])).nonNulls.toSet().toList();

  Future<ShowEpisodeCatalogResult?> _loadAndCache(String key, String title, int? year, String? imdb, int? tvdb) async {
    try {
      final result = await _fetch(title, year, imdb, tvdb);
      _cache.removeWhere((_, entry) => !_now().isBefore(entry.$1));
      if (_cache.length >= 64) _cache.remove(_cache.keys.first);
      // Negative identity matches are shorter-lived; failures never arrive here.
      final ttl = result == null && cacheTtl > const Duration(minutes: 5) ? const Duration(minutes: 5) : cacheTtl;
      _cache[key] = (_now().add(ttl), result);
      return result;
    } finally {
      // This future is returned to callers; removing it does not start work.
      unawaited(_pending.remove(key));
    }
  }

  Future<ShowEpisodeCatalogResult?> _fetch(String title, int? year, String? imdb, int? tvdb) async {
    http.Client? client;
    var finished = false;
    void checkActive() {
      if (finished) throw const ShowEpisodeCatalogUnavailable('Request expired');
    }

    Future<ShowEpisodeCatalogResult?> fetch() async {
      final created = await _clientFactory();
      if (finished) {
        created.close();
        throw const ShowEpisodeCatalogUnavailable('Request expired');
      }
      client = created;
      Map<String, dynamic>? show;
      if (imdb != null || tvdb != null) {
        for (final query in [
          if (imdb != null) {'imdb': imdb},
          if (tvdb != null) {'thetvdb': '$tvdb'},
        ]) {
          final value = await _get(created, '/lookup/shows', query, checkActive, allowMissing: true);
          if (value == null) continue;
          final candidate = _object(value);
          final external = _externals(candidate);
          if ((imdb != null && _string(external['imdb'])?.toLowerCase() != imdb) ||
              (tvdb != null && _integer(external['thetvdb']) != tvdb)) {
            return null;
          }
          show = candidate;
          break;
        }
      } else {
        final value = await _get(created, '/search/shows', {'q': title.trim()}, checkActive);
        final matches = <int, Map<String, dynamic>>{};
        for (final row in _list(value)) {
          final candidate = _object(row['show']);
          final premiere = _date(candidate['premiered']);
          if (_normalize(_string(candidate['name']) ?? '') == _normalize(title) &&
              premiere != null &&
              DateTime.parse(premiere).year == year) {
            matches[_requiredInteger(candidate['id'], minimum: 1)] = candidate;
          }
        }
        if (matches.length == 1) show = matches.values.single;
      }
      if (show == null) return null;
      final id = _requiredInteger(show['id'], minimum: 1);
      final name = _string(show['name']);
      if (name == null) throw const FormatException('Show name missing');
      var aliasesComplete = true;
      final batches = await Future.wait([
        _get(created, '/shows/$id/seasons', const {}, checkActive),
        _get(created, '/shows/$id/episodes', const {'specials': '1'}, checkActive),
        // Aliases belong to this already verified show ID; never infer a
        // franchise prefix from a release title. Optional lookup failure must
        // not discard a healthy episode catalog.
        _get(
          created,
          '/shows/$id/akas',
          const {},
          checkActive,
        ).then(_aliasNames).timeout(const Duration(seconds: 3)).catchError((Object _) {
          aliasesComplete = false;
          return <String>[];
        }),
      ]);
      checkActive();
      final episodes = <ShowCatalogEpisode>[];
      final episodeIds = <int>{};
      for (final row in _list(batches[1])) {
        final episodeId = _requiredInteger(row['id'], minimum: 1);
        if (!episodeIds.add(episodeId)) throw const FormatException('Duplicate episode ID');
        episodes.add(
          ShowCatalogEpisode(
            id: episodeId,
            seasonNumber: _requiredInteger(row['season'], minimum: 0),
            episodeNumber: _integer(row['number']),
            name: _string(row['name']) ?? '',
            sourceUrl: _sourceUrl(row['url'], 'episodes', episodeId),
            airdate: _date(row['airdate']),
            airStamp: _string(row['airstamp']) == null ? null : DateTime.tryParse(row['airstamp'] as String),
            imageUrl: _image(row['image']),
            summary: _summary(row['summary']),
            type: _string(row['type']),
            runtimeMinutes: _integer(row['runtime']),
          ),
        );
      }
      final seasonRows = <int, Map<String, dynamic>>{};
      for (final row in _list(batches[0])) {
        final number = _requiredInteger(row['number'], minimum: 0);
        if (seasonRows.containsKey(number)) throw const FormatException('Duplicate season number');
        seasonRows[number] = row;
      }
      // Preserve a season explicitly reported by an episode even if the seasons
      // endpoint has not caught up. Never invent episode numbers or counts.
      for (final episode in episodes) {
        seasonRows.putIfAbsent(episode.seasonNumber, () => {'number': episode.seasonNumber});
      }
      final numbers = seasonRows.keys.toList()..sort();
      final seasons = numbers.map((number) {
        final row = seasonRows[number]!;
        return ShowCatalogSeason(
          id: _integer(row['id']),
          number: number,
          name: _string(row['name']),
          premiereDate: _date(row['premiereDate']),
          endDate: _date(row['endDate']),
          imageUrl: _image(row['image']),
          summary: _summary(row['summary']),
          episodes: List.unmodifiable(episodes.where((episode) => episode.seasonNumber == number)),
        );
      }).toList();
      final external = _externals(show);
      return ShowEpisodeCatalogResult(
        tvmazeId: id,
        name: name,
        sourceUrl: _sourceUrl(show['url'], 'shows', id),
        premiered: _date(show['premiered']),
        imdbId: _string(external['imdb']),
        tvdbId: _integer(external['thetvdb']),
        imageUrl: _image(show['image']),
        summary: _summary(show['summary']),
        seasons: List.unmodifiable(seasons),
        episodes: List.unmodifiable(episodes),
        aliases: List.unmodifiable(batches[2] as List<String>),
        aliasesComplete: aliasesComplete,
      );
    }

    try {
      return await fetch().timeout(timeout);
    } on ShowEpisodeCatalogUnavailable {
      rethrow;
    } on TimeoutException {
      throw const ShowEpisodeCatalogUnavailable('Request timed out');
    } catch (_) {
      throw const ShowEpisodeCatalogUnavailable('Could not read episode metadata');
    } finally {
      finished = true;
      client?.close();
    }
  }

  static Future<Object?> _get(
    http.Client client,
    String path,
    Map<String, String> query,
    void Function() checkActive, {
    bool allowMissing = false,
  }) async {
    var uri = Uri.https('api.tvmaze.com', path, query.isEmpty ? null : query);
    for (var redirect = 0; redirect < 3; redirect++) {
      checkActive();
      final response = await client.get(
        uri,
        headers: const {'Accept': 'application/json', 'User-Agent': 'Plezy/episode-catalog'},
      );
      checkActive();
      if (response.statusCode == 404 && allowMissing) return null;
      if (response.statusCode == 301 || response.statusCode == 302) {
        final target = response.headers['location'];
        final next = target == null ? null : uri.resolve(target);
        if (next == null ||
            next.scheme != 'https' ||
            next.host != 'api.tvmaze.com' ||
            !RegExp(r'^/shows/\d+$').hasMatch(next.path)) {
          throw const ShowEpisodeCatalogUnavailable('Invalid show lookup redirect');
        }
        uri = next;
        continue;
      }
      if (response.statusCode != 200) {
        throw ShowEpisodeCatalogUnavailable(
          'TVmaze returned HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
      return jsonDecode(response.body);
    }
    throw const ShowEpisodeCatalogUnavailable('Too many show lookup redirects');
  }

  static Map<String, dynamic> _object(Object? value) {
    if (value is! Map<String, dynamic>) throw const FormatException('Expected an object');
    return value;
  }

  static List<Map<String, dynamic>> _list(Object? value) {
    if (value is! List) throw const FormatException('Expected a list');
    return value.map(_object).toList();
  }

  static Map<String, dynamic> _externals(Map<String, dynamic> value) =>
      value['externals'] == null ? {} : _object(value['externals']);
  static int? _integer(Object? value) {
    if (value == null) return null;
    if (value is! int || value < 0) throw const FormatException('Invalid integer');
    return value;
  }

  static int _requiredInteger(Object? value, {required int minimum}) {
    final number = _integer(value);
    if (number == null || number < minimum) throw const FormatException('Required integer missing');
    return number;
  }

  static String? _string(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;
  static String? _date(Object? value) {
    final text = _string(value);
    return text != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text) && DateTime.tryParse(text) != null
        ? text
        : null;
  }

  static String? _image(Object? value) {
    if (value == null) return null;
    final image = _object(value);
    return _string(image['original']) ?? _string(image['medium']);
  }

  static String _sourceUrl(Object? value, String type, int id) {
    final uri = Uri.tryParse(_string(value) ?? '');
    return uri != null && uri.scheme == 'https' && (uri.host == 'www.tvmaze.com' || uri.host == 'tvmaze.com')
        ? uri.toString()
        : 'https://www.tvmaze.com/$type/$id';
  }

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp("['\u2018\u2019]"), '')
      .replaceAll('&', ' and ')
      .replaceAll(RegExp(r'[\s._:;,!?/\\()\[\]{}+\-\u2013\u2014]+'), ' ')
      .trim();
  static String? _summary(Object? value) {
    var text = _string(value);
    if (text == null) return null;
    text = text.replaceAll(RegExp(r'</p\s*>|<br\s*/?>', caseSensitive: false), '\n').replaceAll(RegExp(r'<[^>]*>'), '');
    const entities = {
      '&amp;': '&',
      '&quot;': '"',
      '&#39;': "'",
      '&apos;': "'",
      '&lt;': '<',
      '&gt;': '>',
      '&nbsp;': ' ',
    };
    for (final entry in entities.entries) {
      text = text!.replaceAll(entry.key, entry.value);
    }
    return text!.trim().isEmpty ? null : text.trim();
  }
}
