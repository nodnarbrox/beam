import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:plezy/utils/app_logger.dart';

import 'beam_config.dart';
import 'beam_http.dart';
import 'prowlarr_client.dart';
import 'release_identity.dart';
import 'tpb_magnet_source.dart';

/// On-device torrent indexer search. Queries public tracker JSON APIs directly
/// from Dart (no Prowlarr server required) and returns [ProwlarrResult] objects
/// so the rest of the app stays source-agnostic.
///
/// All outbound requests go through [BeamHttp.client] so swarm-adjacent lookups
/// ride the configured proxy.

/// Public trackers appended to every synthesized magnet.
///
/// CRITICAL for proxied streaming: SOCKS5 carries TCP only, so udp:// tracker
/// announces (and DHT) CANNOT traverse the proxy — behind a proxy, a udp-only
/// magnet finds 0 peers and stalls forever on "downloading metadata". The
/// HTTP/HTTPS trackers below ARE TCP and DO go through SOCKS5, so they're what
/// actually yields peers when the torrent path is proxied (verified in
/// test_torrent_proxy: http trackers → 2 peers → data flowing through the
/// proxy in ~9s, vs 0 peers with udp-only). Keep the http(s) ones FIRST.
const List<String> kPublicTrackers = [
  // TCP (http) trackers FIRST — the only ones that work when UDP is blocked.
  // Plain http:// only: libtorrent's TLS stack fails these tracker endpoints
  // with "asio.ssl error" (observed on-device for tracker.opentrackr.org:443),
  // so an https:// entry is dead weight even when the host is fine.
  ...kProxyableTrackers,
  // UDP trackers — only reachable on a direct/UDP-capable connection. They are
  // STRIPPED by [augmentMagnetForProxy] when the UDP probe says otherwise.
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.demonii.com:1337/announce',
  'udp://exodus.desync.com:6969/announce',
  'udp://tracker.torrent.eu.org:451/announce',
];

/// TCP-only (http/https) trackers — the subset that survives when UDP is
/// unavailable: through a SOCKS5 proxy (TCP-only by protocol) AND through
/// commercial VPNs that silently drop outbound UDP (Surfshark does; verified
/// on-device — TCP to tracker.opentrackr.org:1337 connects while UDP to the
/// SAME host:port times out, and DHT never bootstraps).
///
/// Every entry below was verified with a REAL announce returning live peers
/// (2026-08-23). Ordered best-first: opentrackr answered with 50 peers for a
/// well-seeded YTS release, the rest with 8-11.
///
/// http:// ONLY — no https://. libtorrent fails HTTPS tracker announces here
/// with "asio.ssl error" even for hosts whose http:// endpoint works, so an
/// https:// entry only wastes announce attempts.
///
/// Do NOT re-add tracker.tamersunion.org / tracker.gbitt.info /
/// tracker.openbittorrent.com / opentracker.i2p.rocks. They are NOT censored —
/// they are DEAD: their own authoritative nameservers return no A record
/// (confirmed via DNS-over-HTTPS against Cloudflare and Google, which bypasses
/// any local DNS filtering). "Host not found (authoritative)" is the truth,
/// not a block, so there is nothing to work around.
const List<String> kProxyableTrackers = [
  'http://tracker.opentrackr.org:1337/announce',
  'http://tracker.dler.org:6969/announce',
  'http://tracker.bt4g.com:2095/announce',
  'http://tracker.mywaifu.best:6969/announce',
  'http://bt.okmp3.ru:2710/announce',
  'http://tracker.files.fm:6151/announce',
  'http://tracker.bittor.pw:1337/announce',
];

/// Rewrites [magnet] for a UDP-less network path: STRIPS every `udp://`
/// tracker and appends the verified TCP-only [kProxyableTrackers].
///
/// Stripping matters as much as appending. libtorrent coalesces trackers for
/// the same host, so leaving `udp://tracker.opentrackr.org:1337` alongside
/// `http://tracker.opentrackr.org:1337` meant only the UDP endpoint was ever
/// announced to — it timed out, and the working HTTP announce for the SAME
/// tracker was never attempted (observed on-device: the alert log contained
/// only udp:// opentrackr entries, never the http:// one, while a manual HTTP
/// announce to that tracker returned 31 live peers).
///
/// Non-magnet inputs are returned unchanged.
String augmentMagnetForProxy(String magnet) {
  if (!magnet.startsWith('magnet:')) return magnet;

  final uri = Uri.parse(magnet);
  final kept = <String>[];
  for (final tr in uri.queryParametersAll['tr'] ?? const <String>[]) {
    final t = tr.toLowerCase();
    // Drop udp:// (and the rare udp6://) — dead weight on this path, and they
    // shadow the working TCP endpoint for the same host.
    if (t.startsWith('udp')) continue;
    // Drop https:// trackers: libtorrent's TLS fails them with "asio.ssl
    // error" here, and an https entry for a host we also list over http would
    // otherwise shadow the working one exactly like udp:// did.
    if (t.startsWith('https')) continue;
    kept.add(tr);
  }
  for (final tr in kProxyableTrackers) {
    if (!kept.contains(tr)) kept.add(tr);
  }

  // Rebuild preserving xt/dn (and any other params) but with our tracker set.
  final buf = StringBuffer('magnet:?');
  var first = true;
  void add(String k, String v) {
    if (!first) buf.write('&');
    first = false;
    buf.write('$k=${Uri.encodeQueryComponent(v)}');
  }

  uri.queryParametersAll.forEach((key, values) {
    if (key == 'tr') return; // replaced below
    for (final v in values) {
      // xt must not be re-encoded — 'urn:btih:<hash>' has meaningful colons.
      if (key == 'xt') {
        if (!first) buf.write('&');
        first = false;
        buf.write('xt=$v');
      } else {
        add(key, v);
      }
    }
  });
  for (final tr in kept) {
    add('tr', tr);
  }
  return buf.toString();
}

/// Builds a `magnet:?xt=urn:btih:<hash>` URI with [name] as the display name
/// and the standard public tracker list appended as `&tr=` params.
String buildMagnet(String infoHash, String name) {
  final hash = infoHash.trim();
  final buf = StringBuffer('magnet:?xt=urn:btih:$hash');
  if (name.trim().isNotEmpty) {
    buf.write('&dn=${Uri.encodeQueryComponent(name.trim())}');
  }
  for (final tr in kPublicTrackers) {
    buf.write('&tr=${Uri.encodeQueryComponent(tr)}');
  }
  return buf.toString();
}

/// Normalizes a bittorrent info-hash to lowercase hex for de-dup keys.
String? _hashKey(String? infoHash, String? magnet) {
  if (infoHash != null && infoHash.trim().isNotEmpty) {
    return infoHash.trim().toLowerCase();
  }
  if (magnet != null) {
    final m = RegExp(r'urn:btih:([a-zA-Z0-9]+)').firstMatch(magnet);
    if (m != null) return m.group(1)!.toLowerCase();
  }
  return null;
}

/// A single public indexer that can answer a text query.
abstract class IndexerSource {
  String get name;

  /// [categories] follows Newznab conventions (2000 = movies, 5000 = TV);
  /// individual sources may ignore it when their API is single-purpose.
  Future<List<ProwlarrResult>> search(String query, {List<int> categories = const [2000, 5000]});
}

/// Live YTS API mirrors, best-first.
///
/// YTS rotates its domain constantly and `yts.mx` is now DEAD — its
/// authoritative nameservers (nic.mx) return NXDOMAIN, so it fails everywhere,
/// not just behind a VPN. Verified 2026-08-23: these four serve the genuine API
/// (all returned the same info-hash for the same query, which rules out clone
/// sites), while ~17 other candidate domains were parked, proxies, or dead.
///
/// Trying them in order means one dead mirror no longer kills movie search.
const List<String> kYtsMirrors = [
  'https://yts.lt/api/v2',
  'https://yts.am/api/v2',
  'https://yts.ag/api/v2',
  'https://yts.bz/api/v2',
];

/// YTS movie indexer. Each movie carries a list of torrents (with `hash`,
/// `size_bytes`, `seeds`, `peers`, `quality`); we synthesize one result per
/// torrent.
///
/// YTS matters disproportionately on a UDP-blocked path: its releases are
/// heavily seeded and reachable over TCP trackers (measured 145 peer entries
/// vs 67 for a comparable non-YTS release), which is exactly what a tunnel
/// that drops UDP needs.
class YtsSource implements IndexerSource {
  YtsSource({String? baseUrl}) : _mirrors = baseUrl != null ? [baseUrl] : kYtsMirrors;

  final List<String> _mirrors;

  /// Mirror that answered last — tried first next time so we don't re-walk
  /// dead hosts on every keystroke.
  static String? _lastGood;

  String get baseUrl => _lastGood ?? _mirrors.first;

  @override
  String get name => 'YTS';

  @override
  Future<List<ProwlarrResult>> search(String query, {List<int> categories = const [2000]}) async {
    if (query.trim().isEmpty) return const [];
    final client = await BeamHttp.client();
    try {
      // Walk the mirrors until one answers — a dead/parked domain must not
      // take movie search down with it. Start from the last known-good one.
      final order = <String>[
        if (_lastGood != null && _mirrors.contains(_lastGood)) _lastGood!,
        ..._mirrors.where((m) => m != _lastGood),
      ];

      List? movies;
      for (final base in order) {
        final uri = Uri.parse(
          '$base/list_movies.json',
        ).replace(queryParameters: {'query_term': query.trim(), 'limit': '50', 'sort_by': 'seeds'});
        try {
          final r = await client.get(uri).timeout(const Duration(seconds: 12));
          if (r.statusCode != 200) {
            appLogger.w('YTS mirror $base HTTP ${r.statusCode}');
            continue;
          }
          final body = jsonDecode(r.body);
          if (body is! Map) continue;
          final data = body['data'];
          final m = (data is Map) ? data['movies'] : null;
          if (m is! List) continue;
          movies = m;
          if (_lastGood != base) {
            appLogger.i('YTS: using mirror $base');
            _lastGood = base;
          }
          break;
        } catch (e) {
          appLogger.w('YTS mirror $base failed: $e');
        }
      }
      if (movies == null) {
        appLogger.w('YTS: all ${order.length} mirrors failed');
        return const [];
      }

      final out = <ProwlarrResult>[];
      for (final m in movies.whereType<Map>()) {
        final movieTitle = (m['title_long'] ?? m['title'] ?? '').toString();
        final infoUrl = m['url']?.toString();
        final torrents = m['torrents'];
        if (torrents is! List) continue;
        for (final t in torrents.whereType<Map>()) {
          final hash = t['hash']?.toString();
          if (hash == null || hash.isEmpty) continue;
          final quality = t['quality']?.toString() ?? '';
          final type = t['type']?.toString() ?? '';
          final codec = t['video_codec']?.toString() ?? '';
          final title = [movieTitle, quality, type, codec].where((e) => e.isNotEmpty).join(' ').trim();
          final size = (t['size_bytes'] is int) ? t['size_bytes'] as int : int.tryParse('${t['size_bytes']}') ?? 0;
          out.add(
            ProwlarrResult(
              title: title,
              indexer: name,
              size: size,
              seeders: (t['seeds'] is int) ? t['seeds'] as int : 0,
              leechers: (t['peers'] is int) ? t['peers'] as int : 0,
              magnetUrl: buildMagnet(hash, title),
              downloadUrl: t['url']?.toString(),
              infoUrl: infoUrl,
              categories: const [2000],
              publishDate: DateTime.tryParse('${m['date_uploaded']}'),
            ),
          );
        }
      }
      return out;
    } finally {
      client.close();
    }
  }
}

/// The Pirate Bay via the apibay JSON endpoint.
/// https://apibay.org/q.php?q=`query` -> JSON array of
/// {name, info_hash, size (bytes as string), seeders, leechers, category, ...}.
/// A single element with info_hash all-zeros means "no results".
/// apibay JSON API host(s), best-first. `apibay.org` is the canonical (and, as of
/// 2026-08, effectively the only live) `/q.php?q=` JSON endpoint — the many
/// "TPB proxy" domains are HTML scrapers that 404 this API. It has brief outages
/// (measured down for ~minutes on 2026-08-25 then back), so search() retries the
/// list; add a real JSON mirror here if one is verified. Kept as a list so
/// adding one later needs no code change.
const List<String> kApibayMirrors = ['https://apibay.org'];

class ApibaySource implements IndexerSource {
  ApibaySource({String? baseUrl, Future<http.Client> Function()? clientFactory, TpbMagnetSource? fallback})
    : _mirrors = baseUrl != null ? [baseUrl] : kApibayMirrors,
      _clientFactory = clientFactory ?? BeamHttp.client,
      _fallback = fallback ?? TpbMagnetSource(clientFactory: clientFactory);

  final TpbMagnetSource _fallback;
  final List<String> _mirrors;
  final Future<http.Client> Function() _clientFactory;
  String? _lastGood;

  @override
  String get name => 'ThePirateBay';

  @override
  Future<List<ProwlarrResult>> search(String query, {List<int> categories = const [2000, 5000]}) async {
    if (query.trim().isEmpty) return const [];
    // Try the last-good mirror first, then the rest, so we don't re-walk dead
    // hosts on every keystroke.
    final order = <String>[?_lastGood, ..._mirrors.where((m) => m != _lastGood)];
    for (final base in order) {
      final res = await _searchOne(base, query.trim());
      if (res != null) {
        _lastGood = base;
        return res.isNotEmpty ? res : _fallback.search(query, categories: categories);
      }
    }
    appLogger.w('apibay: all ${order.length} mirrors failed; trying HTML magnets');
    return _fallback.search(query, categories: categories);
  }

  /// Returns results from one mirror, or null if that mirror failed (so the
  /// caller advances to the next). An empty list is a valid "no results" and is
  /// returned as-is (not null).
  Future<List<ProwlarrResult>?> _searchOne(String base, String query) async {
    final client = await _clientFactory();
    try {
      final uri = Uri.parse('$base/q.php').replace(queryParameters: {'q': query, 'cat': ''});
      final r = await client.get(uri).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        appLogger.w('apibay $base HTTP ${r.statusCode}');
        return null;
      }
      final body = jsonDecode(r.body);
      if (body is! List) return null;

      final out = <ProwlarrResult>[];
      for (final e in body.whereType<Map>()) {
        final hash = e['info_hash']?.toString() ?? '';
        // apibay's "no results" sentinel.
        if (hash.isEmpty || hash == '0000000000000000000000000000000000000000') {
          continue;
        }
        final title = (e['name'] ?? '').toString();
        final size = int.tryParse('${e['size']}') ?? 0;
        // TPB uses three-digit categories (205 TV, 208 HD TV), not
        // Torznab buckets. Preserve TV identity before the strict release gate.
        final cat = int.tryParse('${e['category']}') ?? 0;
        final catBucket = (cat == 205 || cat == 208 || (cat >= 205000 && cat < 206000))
            ? 5000
            : (cat >= 500 && cat < 600)
            ? 6000
            : 2000;
        out.add(
          ProwlarrResult(
            title: title,
            indexer: name,
            size: size,
            seeders: int.tryParse('${e['seeders']}') ?? 0,
            leechers: int.tryParse('${e['leechers']}') ?? 0,
            magnetUrl: buildMagnet(hash, title),
            downloadUrl: null,
            infoUrl: null,
            categories: [catBucket],
            publishDate: () {
              final added = int.tryParse('${e['added']}');
              return added == null ? null : DateTime.fromMillisecondsSinceEpoch(added * 1000);
            }(),
          ),
        );
      }
      return out;
    } catch (e) {
      // Timeout / DNS / TLS on this mirror — signal failure so the caller tries
      // the next one.
      appLogger.w('apibay $base failed: $e');
      return null;
    } finally {
      client.close();
    }
  }
}

/// EZTV TV indexer. https://eztvx.to/api/get-torrents
///
/// LIMITATION: EZTV's API keys off an IMDB id (`imdb_id`, digits only, no
/// "tt" prefix), NOT a free-text title. Since [search] receives a text query,
/// this source is best-effort: if the query is a bare IMDB id (all digits, or
/// "tt#######") we query directly; otherwise we cannot map title -> imdb here
/// and return an empty list rather than guess. Callers wanting EZTV results
/// for a title should resolve the IMDB id upstream and pass it as the query.
class EztvSource implements IndexerSource {
  EztvSource({
    this.baseUrl = 'https://eztvx.to/api',
    Future<http.Client> Function()? clientFactory,
    this.timeout = const Duration(seconds: 15),
  }) : _clientFactory = clientFactory ?? BeamHttp.client;

  final String baseUrl;
  final Future<http.Client> Function() _clientFactory;
  final Duration timeout;
  @override
  String get name => 'EZTV';

  @override
  Future<List<ProwlarrResult>> search(String query, {List<int> categories = const [5000]}) =>
      _searchByImdb(query, maxPages: 1);

  /// Independent bounded TV lookup; older episodes may be beyond the newest
  /// 100 releases. Exact show/episode/pack filtering is identical to text search.
  Future<List<ProwlarrResult>> searchEpisode({
    required String imdbId,
    required String show,
    required int season,
    required int episode,
    Iterable<String> aliases = const [],
    Future<void>? cancelled,
  }) => _searchByImdb(
    imdbId,
    maxPages: 3,
    cancelled: cancelled,
    accept: (source) =>
        ReleaseIdentity.episodeSourceKind(source, show: show, season: season, episode: episode, aliases: aliases) !=
        null,
  );

  Future<List<ProwlarrResult>> _searchByImdb(
    String query, {
    required int maxPages,
    bool Function(ProwlarrResult)? accept,
    Future<void>? cancelled,
  }) async {
    final match = RegExp(r'^(?:tt)?(\d{6,9})$', caseSensitive: false).firstMatch(query.trim());
    if (match == null) return const [];
    final imdb = match.group(1)!;
    var active = true;
    http.Client? client;
    final cancellation = Completer<void>();
    if (cancelled != null) {
      unawaited(
        cancelled.then((_) {
          active = false;
          client?.close();
          if (!cancellation.isCompleted) cancellation.complete();
        }),
      );
    }
    Future<List<ProwlarrResult>> fetch() async {
      final opened = await _clientFactory();
      client = opened;
      if (!active) {
        opened.close();
        return const [];
      }
      final seen = <String>{};
      final results = <ProwlarrResult>[];
      for (var page = 1; active && page <= maxPages; page++) {
        final uri = Uri.parse(
          '$baseUrl/get-torrents',
        ).replace(queryParameters: {'imdb_id': imdb, 'limit': '100', 'page': '$page'});
        final response = await opened.get(uri);
        if (!active) return const [];
        if (response.statusCode != 200) throw IndexerUnavailableException('EZTV HTTP ${response.statusCode}');
        final body = jsonDecode(response.body);
        if (body is! Map) throw IndexerUnavailableException('EZTV returned an invalid search response');
        // The live API omits torrents entirely when the total is zero.
        final count = int.tryParse('${body['torrents_count']}');
        if (body['torrents'] == null && count == 0) return const [];
        if (body['torrents'] is! List || (body['torrents'] as List).length > 100) {
          throw IndexerUnavailableException('EZTV returned an invalid search response');
        }
        final rows = body['torrents'] as List;
        var added = 0;
        for (final row in rows.whereType<Map>()) {
          // The endpoint is keyed by a show ID; reject contradictory row IDs.
          final rowImdb = row['imdb_id']?.toString().replaceFirst(RegExp(r'^tt', caseSensitive: false), '');
          if (rowImdb != null &&
              (!RegExp(r'^\d{1,9}$').hasMatch(rowImdb) || int.tryParse(rowImdb) != int.parse(imdb))) {
            continue;
          }
          final title = (row['title'] ?? row['filename'] ?? '').toString();
          final hash = row['hash']?.toString() ?? '';
          final magnet = row['magnet_url']?.toString();
          final timestamp = int.tryParse('${row['date_released_unix']}');
          final result = ProwlarrResult(
            title: title,
            indexer: name,
            size: int.tryParse('${row['size_bytes']}') ?? 0,
            seeders: int.tryParse('${row['seeds']}') ?? 0,
            leechers: int.tryParse('${row['peers']}') ?? 0,
            magnetUrl: magnet?.isNotEmpty == true
                ? magnet
                : hash.isNotEmpty
                ? buildMagnet(hash, title)
                : null,
            downloadUrl: row['torrent_url']?.toString(),
            infoUrl: null,
            categories: const [5000],
            publishDate: timestamp == null ? null : DateTime.fromMillisecondsSinceEpoch(timestamp * 1000),
          );
          final key = result.infoHash ?? result.grabLink ?? '$title|${result.size}';
          if (!seen.add(key)) continue;
          added++;
          if (accept == null || accept(result)) results.add(result);
        }
        if (results.isNotEmpty ||
            rows.isEmpty ||
            added == 0 ||
            (count != null ? page * 100 >= count : rows.length < 100)) {
          break;
        }
      }
      results.sort((a, b) => b.seeders.compareTo(a.seeders));
      return results;
    }

    try {
      return await Future.any([
        fetch(),
        if (cancelled != null) cancellation.future.then((_) => <ProwlarrResult>[]),
      ]).timeout(timeout);
    } finally {
      active = false;
      client?.close();
    }
  }
}

/// Fans out a query across every configured [IndexerSource] in parallel,
/// merges + de-dupes by info-hash, and sorts best-first (seeders desc, then
/// size desc). A dead tracker is caught and logged; it never kills the search.
/// Thrown when EVERY indexer failed, so the caller can tell a real outage
/// apart from a search that genuinely matched nothing.
class IndexerUnavailableException implements Exception {
  IndexerUnavailableException(this.message);
  final String message;
  @override
  String toString() => message;
}

class MultiIndexer {
  MultiIndexer({List<IndexerSource>? sources}) : sources = sources ?? [YtsSource(), ApibaySource(), EztvSource()];

  final List<IndexerSource> sources;

  Future<List<ProwlarrResult>> search(String query, {List<int> categories = const [2000, 5000]}) async {
    if (query.trim().isEmpty) return const [];

    // Track how many sources actually answered. Without this, "every indexer
    // threw" and "every indexer legitimately returned nothing" both surface as
    // an empty list, so a total network outage renders as "No results" instead
    // of an actionable error.
    // No-op providers must not disguise failure of all applicable TV sources.
    final applicable = sources
        .where(
          (s) =>
              !(s is YtsSource && !categories.contains(2000)) &&
              !(s is EztvSource &&
                  (!categories.contains(5000) ||
                      !RegExp(r'^(?:tt?)?\d{6,9}$', caseSensitive: false).hasMatch(query.trim()))),
        )
        .toList();
    var failures = 0;
    final settled = await Future.wait(
      applicable.map((s) async {
        try {
          return await s.search(query, categories: categories);
        } catch (e) {
          failures++;
          appLogger.w('indexer ${s.name} failed: $e');
          return const <ProwlarrResult>[];
        }
      }),
    );
    if (failures == applicable.length && applicable.isNotEmpty) {
      throw IndexerUnavailableException('All ${applicable.length} indexers failed — check your connection.');
    }

    // Merge + de-dupe by info-hash (falling back to a title|size key when a
    // hash can't be derived, e.g. a magnet-less download-only result).
    final seen = <String>{};
    final merged = <ProwlarrResult>[];
    for (final list in settled) {
      for (final res in list) {
        final key = _hashKey(null, res.magnetUrl) ?? '${res.title.toLowerCase()}|${res.size}';
        if (seen.add(key)) merged.add(res);
      }
    }

    merged.sort((a, b) {
      final s = b.seeders.compareTo(a.seeders);
      if (s != 0) return s;
      return b.size.compareTo(a.size);
    });
    return merged;
  }
}

/// The search entry point the app should use. Prefers a configured Prowlarr
/// server (LAN, DNS-independent, aggregates many private+public indexers
/// server-side) and only falls back to hitting public trackers *directly* from
/// the device when Prowlarr is unreachable or empty.
///
/// This ordering is what makes Beam work on a bare cord-cutter box like the
/// ONN: such boxes routinely have LAN connectivity but NO working public DNS,
/// so a direct indexer lookup throws `Failed host lookup`, while the LAN
/// Prowlarr at its literal IP resolves fine. On a phone with full internet the
/// direct fallback still covers the case where no Prowlarr is set up.
///
/// Note a host that fails to resolve is not necessarily censored: `yts.mx`
/// itself is simply DEAD upstream (NXDOMAIN from nic.mx), which is why
/// [kYtsMirrors] exists.
///
/// Prowlarr talks over [ProwlarrClient]'s own plain `http.Client` (LAN, never
/// proxied); the direct [MultiIndexer] fallback rides [BeamHttp.client] so it
/// honors the proxy when swarm-adjacent lookups must be hidden.
class CombinedIndexer {
  CombinedIndexer({ProwlarrClient? prowlarr, MultiIndexer? direct})
    : _direct = direct ?? MultiIndexer(),
      _prowlarrFactory = (prowlarr != null ? (() => prowlarr) : null);

  final MultiIndexer _direct;

  /// When a client is injected (tests) we reuse it; otherwise we build a fresh
  /// one per search and dispose it, so we never leak a socket.
  final ProwlarrClient Function()? _prowlarrFactory;

  Future<List<ProwlarrResult>> search(String query, {List<int> categories = const [2000, 5000]}) async {
    if (query.trim().isEmpty) return const [];
    await BeamConfig.init();

    // 1) ON-DEVICE indexers FIRST. Beam is meant to be self-contained — the
    //    indexer search runs in the app, not on a server. An external Prowlarr
    //    is a bonus, never a dependency.
    //
    //    This ordering also matters with a VPN: a Prowlarr on the LAN
    //    (192.168.x) is unreachable once the tunnel captures all traffic, so
    //    trying it first meant every search stalled on a 45s timeout before any
    //    results appeared.
    // A total on-device failure is remembered rather than rethrown here: an
    // external Prowlarr may still answer. If that also fails we surface the
    // outage instead of an empty list.
    var directFailed = false;
    var direct = const <ProwlarrResult>[];
    try {
      direct = await _direct.search(query, categories: categories);
    } on IndexerUnavailableException catch (e) {
      directFailed = true;
      appLogger.w('On-device indexers all failed: $e');
    }
    if (direct.isNotEmpty) return direct;

    // 2) Optional external Prowlarr — only if the user configured one AND the
    //    on-device indexers came back empty.
    final url = BeamConfig.prowlarrUrl.trim();
    if (url.isEmpty) {
      if (directFailed) {
        throw IndexerUnavailableException(
          'Search failed — no indexer could be reached. Check your '
          'connection or VPN.',
        );
      }
      return const [];
    }
    final injected = _prowlarrFactory != null;
    final client = _prowlarrFactory?.call() ?? ProwlarrClient();
    try {
      appLogger.i('On-device indexers empty; trying Prowlarr at $url');
      return await client.search(query, categories: categories);
    } catch (e) {
      appLogger.w('Prowlarr search failed ($url): $e');
      // Both paths dead => a real outage, not an empty result set.
      if (directFailed) {
        throw IndexerUnavailableException(
          'Search failed — on-device indexers and Prowlarr are both '
          'unreachable. Check your connection or VPN.',
        );
      }
      return const [];
    } finally {
      if (!injected) client.dispose();
    }
  }
}
