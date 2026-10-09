part of 'show_episode_catalog.dart';

/// Evidence that a complete season maps one-to-one to an explicit broadcast
/// premiere order. This corroborates numbering, not the contents of a torrent.
class VerifiedEpisodeNumbering {
  const VerifiedEpisodeNumbering({
    required this.showId,
    required this.episodeId,
    required this.season,
    required this.episode,
    required this.title,
    required this.alternateListId,
  });
  final int showId;
  final int episodeId;
  final int season;
  final int episode;
  final String title;
  final int alternateListId;

  Map<String, Object> toRaw() => {
    'authority': 'tvmaze-broadcast-bijection-v1',
    'showId': showId,
    'episodeId': episodeId,
    'season': season,
    'episode': episode,
    'title': title,
    'alternateListId': alternateListId,
    'source': 'https://api.tvmaze.com/alternatelists/$alternateListId/alternateepisodes',
  };
}

extension _ShowEpisodeNumbering on ShowEpisodeCatalog {
  Future<ShowEpisodeCatalogResult> _verifyCatalogNumbering(ShowEpisodeCatalogResult catalog) async {
    if (catalog.numberingChecked || catalog.tvmazeId <= 0 || catalog.episodes.isEmpty) return catalog;
    final key = jsonEncode([
      catalog.tvmazeId,
      for (final e in catalog.episodes) [e.id, e.seasonNumber, e.episodeNumber, e.name, e.type],
    ]);
    final cached = _numberingCache[key];
    if (cached != null && _now().isBefore(cached.$1)) return catalog.withNumbering(cached.$2);
    final pending = _pendingNumbering.putIfAbsent(key, () => _fetchNumbering(catalog));
    final evidence = await pending;
    if (identical(_pendingNumbering[key], pending)) unawaited(_pendingNumbering.remove(key));
    // Network failures are not a completed negative proof: next Play may retry.
    if (evidence == null) return catalog;
    _numberingCache.removeWhere((_, entry) => !_now().isBefore(entry.$1));
    if (_numberingCache.length >= 64) _numberingCache.remove(_numberingCache.keys.first);
    _numberingCache[key] = (_now().add(cacheTtl), evidence);
    return catalog.withNumbering(evidence);
  }

  Future<Map<int, VerifiedEpisodeNumbering>?> _fetchNumbering(ShowEpisodeCatalogResult catalog) async {
    http.Client? client;
    var finished = false;
    void checkActive() {
      if (finished) throw const ShowEpisodeCatalogUnavailable('Numbering request expired');
    }

    Future<Map<int, VerifiedEpisodeNumbering>> fetch() async {
      final created = await _clientFactory();
      if (finished) {
        created.close();
        throw const ShowEpisodeCatalogUnavailable('Numbering request expired');
      }
      client = created;
      final lists = ShowEpisodeCatalog._list(
        await ShowEpisodeCatalog._get(created, '/shows/${catalog.tvmazeId}/alternatelists', const {}, checkActive),
      );
      final eligible = lists
          .where(
            (list) =>
                list['broadcast_premiere'] == true &&
                list['dvd_release'] == false &&
                list['verbatim_order'] == false &&
                list['language_premiere'] == false,
          )
          .toList();
      // Inspect every eligible list within a fixed budget; never truncate away
      // a possible conflicting broadcast order and call the remainder proof.
      if (eligible.isEmpty || eligible.length > 3) return {};
      final batches = await Future.wait(
        eligible.map((list) async {
          final id = ShowEpisodeCatalog._requiredInteger(list['id'], minimum: 1);
          final rows = ShowEpisodeCatalog._list(
            await ShowEpisodeCatalog._get(created, '/alternatelists/$id/alternateepisodes', const {
              'embed': 'episodes',
            }, checkActive),
          );
          return (id, rows);
        }),
      );
      return _broadcastEvidence(catalog, batches);
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
}

Map<int, VerifiedEpisodeNumbering> _broadcastEvidence(
  ShowEpisodeCatalogResult catalog,
  List<(int, List<Map<String, dynamic>>)> batches,
) {
  // Missing coordinates cannot be treated as irrelevant to a season: they
  // might conceal a conflicting broadcast mapping.
  bool positive(Object? value) => value is int && value > 0;
  for (final (_, rows) in batches) {
    for (final row in rows) {
      final embedded = row['_embedded'];
      final linked = embedded is Map ? embedded['episodes'] : null;
      if (!positive(row['id']) ||
          row['season'] is! int ||
          (row['season'] as int) < 0 ||
          !positive(row['number']) ||
          row['type'] is! String ||
          linked is! List ||
          linked.isEmpty) {
        throw const FormatException('Unverifiable broadcast coordinates');
      }
      for (final episode in linked) {
        final links = episode is Map ? episode['_links'] : null;
        final show = links is Map ? links['show'] : null;
        if (episode is! Map ||
            !positive(episode['id']) ||
            episode['season'] is! int ||
            (episode['season'] as int) < 0 ||
            !positive(episode['number']) ||
            episode['name'] is! String ||
            (episode['name'] as String).trim().isEmpty ||
            show is! Map ||
            show['href'] != 'https://api.tvmaze.com/shows/${catalog.tvmazeId}') {
          throw const FormatException('Unverifiable canonical episode binding');
        }
      }
    }
  }
  final proofs = <int, VerifiedEpisodeNumbering>{};
  for (final season in catalog.episodes.map((e) => e.seasonNumber).where((s) => s > 0).toSet()) {
    final expected = catalog.episodes.where((e) => e.seasonNumber == season).toList();
    if (expected.isEmpty ||
        expected.any(
          (e) =>
              e.id <= 0 ||
              e.name.trim().isEmpty ||
              e.type != 'regular' ||
              e.episodeNumber == null ||
              e.episodeNumber! < 1,
        )) {
      continue;
    }
    final byId = {for (final e in expected) e.id: e};
    if (byId.length != expected.length || expected.map((e) => e.episodeNumber).toSet().length != expected.length) {
      continue;
    }
    final numbers = expected.map((e) => e.episodeNumber!).toList()..sort();
    if (numbers.indexed.any((entry) => entry.$2 != entry.$1 + 1)) continue;
    int? supportingList;
    var conflict = false;
    for (final (listId, rows) in batches) {
      final relevant = rows.where((row) {
        final embedded = row['_embedded'];
        final episodes = embedded is Map ? embedded['episodes'] : null;
        return row['season'] == season ||
            (episodes is List && episodes.any((e) => e is Map && byId.containsKey(e['id'])));
      }).toList();
      if (relevant.isEmpty) continue;
      final seen = <int>{};
      var valid = relevant.length == expected.length;
      for (final row in relevant) {
        final embedded = row['_embedded'];
        final episodes = embedded is Map ? embedded['episodes'] : null;
        if (episodes is! List || episodes.length != 1 || episodes.single is! Map) {
          valid = false;
          break;
        }
        final linked = episodes.single as Map;
        final canonical = byId[linked['id']];
        final links = linked['_links'];
        final showLink = links is Map ? links['show'] : null;
        if (canonical == null ||
            !seen.add(canonical.id) ||
            row['type'] != 'regular' ||
            row['season'] != season ||
            row['number'] != canonical.episodeNumber ||
            linked['season'] != season ||
            linked['number'] != canonical.episodeNumber ||
            linked['name'] != canonical.name ||
            showLink is! Map ||
            showLink['href'] != 'https://api.tvmaze.com/shows/${catalog.tvmazeId}') {
          valid = false;
          break;
        }
      }
      if (!valid || seen.length != expected.length) {
        conflict = true;
        break;
      }
      supportingList ??= listId;
    }
    if (conflict || supportingList == null) continue;
    for (final e in expected) {
      proofs[e.id] = VerifiedEpisodeNumbering(
        showId: catalog.tvmazeId,
        episodeId: e.id,
        season: season,
        episode: e.episodeNumber!,
        title: e.name,
        alternateListId: supportingList,
      );
    }
  }
  return Map.unmodifiable(proofs);
}
