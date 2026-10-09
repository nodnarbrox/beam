import 'prowlarr_client.dart';
import 'release_identity.dart';

enum EpisodeSourceAvailability { candidate, unavailable, unknown }

/// Search is a hint, never proof that a pack contains an episode. Playback
/// verifies the actual file list with EpisodeFileSelector before opening it.
class EpisodeSourceProbe {
  EpisodeSourceProbe(this.search, {DateTime Function()? now}) : _now = now ?? DateTime.now;
  final Future<List<ProwlarrResult>> Function(String query) search;
  final DateTime Function() _now;
  final _packs = <String, (DateTime, List<ProwlarrResult>)>{};
  final _pendingPacks = <String, Future<(List<ProwlarrResult>, bool)>>{};

  static bool usable(ProwlarrResult r) => (r.hasMagnet && r.seeders > 0) || (r.grabLink?.isNotEmpty ?? false);

  /// Bounded shared query set for availability and actual playback discovery.
  static List<String> queries(String show, int season, int episode, {int? year}) {
    final clean = show.replaceAll(RegExp(r'\s+'), ' ').trim();
    final s = season.toString().padLeft(2, '0');
    final normalized = clean.replaceAll(RegExp("['\u2018\u2019]"), '');
    final articleFree = normalized.replaceFirst(RegExp(r'^(?:the|an|a)\s+', caseSensitive: false), '');
    return [
      '$clean S${s}E${episode.toString().padLeft(2, '0')}',
      '$clean S$s',
      '$clean Season $season',
      '$clean Complete',
      // A range-only name such as S01-S04 need not contain S03 or "Complete".
      // The bounded title query still passes the same strict identity filter.
      clean,
      // Some indexers require the premiere year and omit title apostrophes.
      // These are lookup variants only; every hit keeps the strict title/S/E
      // identity gate and actual-file verification used by the original queries.
      if (year != null && year >= 1800 && year <= 2199) ...[
        '$normalized $year S${s}E${episode.toString().padLeft(2, '0')}',
        '$normalized $year S$s',
        // Indexer full-title matching can omit an initial article as well as
        // apostrophes. This is one bounded variant, never a guessed show alias.
        if (articleFree.isNotEmpty && articleFree != clean) articleFree,
      ],
    ];
  }

  Future<EpisodeSourceAvailability> check(String show, int season, int episode) async {
    final clean = show.replaceAll(RegExp(r'\s+'), ' ').trim();
    final searches = queries(clean, season, episode);
    bool matches(ProwlarrResult r) =>
        usable(r) && ReleaseIdentity.matchesEpisodeSource(r, show: clean, season: season, episode: episode);
    var failed = false;
    try {
      final singles = await search(searches.first);
      if (singles.any(matches)) return EpisodeSourceAvailability.candidate;
    } catch (_) {
      failed = true;
    }
    // Empty episode searches still probe packs. Unknown results are never cached.
    final key = '${clean.toLowerCase()}|$season';
    final cached = _packs[key];
    List<ProwlarrResult> packs;
    if (cached != null && _now().difference(cached.$1) < const Duration(minutes: 2)) {
      packs = cached.$2;
    } else {
      final pending = _pendingPacks.putIfAbsent(key, () => _searchPacks(searches.skip(1)));
      final result = await pending;
      if (identical(_pendingPacks[key], pending)) {
        // Already awaited above; removal must not await this completed future again.
        // ignore: unawaited_futures
        _pendingPacks.remove(key);
      }
      packs = result.$1;
      // Cache candidates, not an episode-specific verdict: a cached S01E02
      // hit must never make S01E03 appear available.
      if (!result.$2) _packs[key] = (_now(), packs);
      failed = failed || result.$2;
    }
    return packs.any(matches)
        ? EpisodeSourceAvailability.candidate
        : failed
        ? EpisodeSourceAvailability.unknown
        : EpisodeSourceAvailability.unavailable;
  }

  Future<(List<ProwlarrResult>, bool)> _searchPacks(Iterable<String> queries) async {
    var failed = false;
    final batches = await Future.wait(
      queries.map((query) async {
        try {
          return await search(query);
        } catch (_) {
          failed = true;
          return <ProwlarrResult>[];
        }
      }),
    );
    return (batches.expand((batch) => batch).toList(), failed);
  }
}
