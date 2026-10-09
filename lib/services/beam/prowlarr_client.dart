import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:plezy/utils/app_logger.dart';

import 'beam_config.dart';
import 'indexer_search.dart' show kPublicTrackers;

/// One search hit from Prowlarr's aggregated indexer search.
class ProwlarrResult {
  ProwlarrResult({
    required this.title,
    required this.indexer,
    required this.size,
    required this.seeders,
    required this.leechers,
    required this.magnetUrl,
    required this.downloadUrl,
    required this.infoUrl,
    required this.categories,
    required this.publishDate,
  });

  final String title;
  final String indexer;
  final int size; // bytes
  final int seeders;
  final int leechers;

  /// A `magnet:?` URI when the indexer exposes one directly.
  final String? magnetUrl;

  /// A `.torrent` fetch URL (Prowlarr-proxied) when no magnet is present.
  final String? downloadUrl;
  final String? infoUrl;
  final List<int> categories;
  final DateTime? publishDate;

  /// The link to hand to Real-Debrid — prefer a magnet; fall back to the
  /// Prowlarr download URL (RD accepts hoster/.tornrent URLs via addTorrent,
  /// but magnets are the common path).
  String? get grabLink => (magnetUrl != null && magnetUrl!.isNotEmpty)
      ? magnetUrl
      : downloadUrl;

  bool get hasMagnet => magnetUrl != null && magnetUrl!.isNotEmpty;

  /// The bittorrent info-hash (lowercase hex) for this release, derived from
  /// the magnet's `xt=urn:btih:` parameter. This is the STABLE identity used by
  /// the local Beam library / resume store (the resolved playback URL is
  /// ephemeral, the info-hash is not). Null when no magnet is available.
  String? get infoHash => infoHashFromMagnet(magnetUrl);

  String get sizeHuman {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double s = size.toDouble();
    int u = 0;
    while (s >= 1024 && u < units.length - 1) {
      s /= 1024;
      u++;
    }
    return '${s.toStringAsFixed(s >= 100 || u == 0 ? 0 : 1)} ${units[u]}';
  }

  factory ProwlarrResult.fromJson(Map<String, dynamic> j) {
    final cats = <int>[];
    final rawCats = j['categories'];
    if (rawCats is List) {
      for (final c in rawCats) {
        if (c is Map && c['id'] is int) cats.add(c['id'] as int);
      }
    }
    // Prowlarr quirk: its `magnetUrl` field is often a Prowlarr-PROXIED
    // `.torrent` download URL (http://prowlarr/N/download?apikey=…), NOT a real
    // magnet. The actual magnet: URI lives in `guid`, and `infoHash` is present
    // too. So derive a real magnet from guid/infoHash, and treat the proxied
    // magnetUrl/downloadUrl as the .torrent download fallback.
    final title = (j['title'] ?? '').toString();
    final guid = j['guid']?.toString();
    final rawMagnet = j['magnetUrl']?.toString();
    final infoHash = j['infoHash']?.toString();

    String? magnet;
    if (guid != null && guid.startsWith('magnet:')) {
      magnet = guid;
    } else if (rawMagnet != null && rawMagnet.startsWith('magnet:')) {
      magnet = rawMagnet;
    } else if (infoHash != null && infoHash.trim().isNotEmpty) {
      magnet = _magnetFromHash(infoHash.trim(), title);
    }

    // Anything that is a real magnet goes to magnetUrl; the proxied download
    // URL (or downloadUrl) is the .torrent fallback for Real-Debrid.
    final downloadUrl = <String?>[
      (rawMagnet != null && !rawMagnet.startsWith('magnet:')) ? rawMagnet : null,
      j['downloadUrl']?.toString(),
    ].firstWhere((e) => e != null && e.isNotEmpty, orElse: () => null);

    return ProwlarrResult(
      title: title,
      indexer: (j['indexer'] ?? '').toString(),
      size: (j['size'] is int)
          ? j['size'] as int
          : int.tryParse('${j['size']}') ?? 0,
      seeders: (j['seeders'] is int) ? j['seeders'] as int : 0,
      leechers: (j['leechers'] is int) ? j['leechers'] as int : 0,
      magnetUrl: magnet,
      downloadUrl: downloadUrl,
      infoUrl: j['infoUrl']?.toString(),
      categories: cats,
      publishDate: DateTime.tryParse('${j['publishDate']}'),
    );
  }
}

/// Extracts the bittorrent info-hash (lowercase hex) from a magnet URI, or
/// null. Handles both the 40-char hex btih and the rarer 32-char base32 form
/// (base32 is normalized to hex). Shared by [ProwlarrResult.infoHash] and the
/// Real-Debrid dedupe path so both key on the exact same identity.
String? infoHashFromMagnet(String? magnet) {
  if (magnet == null || magnet.isEmpty) return null;
  final m = RegExp(r'xt=urn:btih:([A-Za-z0-9]+)', caseSensitive: false).firstMatch(magnet);
  if (m == null) return null;
  final raw = m.group(1)!;
  if (raw.length == 40 && RegExp(r'^[0-9A-Fa-f]{40}$').hasMatch(raw)) {
    return raw.toLowerCase();
  }
  if (raw.length == 32) {
    final hex = _base32ToHex(raw.toUpperCase());
    if (hex != null) return hex.toLowerCase();
  }
  return raw.toLowerCase();
}

/// Decodes a 32-char RFC-4648 base32 btih to 40-char hex, or null on bad input.
String? _base32ToHex(String b32) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  var bits = 0;
  var value = 0;
  final out = StringBuffer();
  for (final ch in b32.split('')) {
    final idx = alphabet.indexOf(ch);
    if (idx < 0) return null;
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.write(((value >> bits) & 0xFF).toRadixString(16).padLeft(2, '0'));
    }
  }
  final hex = out.toString();
  return hex.length == 40 ? hex : null;
}

/// Builds a magnet: URI from a bittorrent info-hash + display name, with a
/// standard public tracker list appended (mirrors indexer_search.buildMagnet).
String _magnetFromHash(String infoHash, String name) {
  // Shared with indexer_search so a UDP-blocked path (SOCKS5, or a VPN like
  // Surfshark that drops UDP) gets the same working http:// trackers. Keeping a
  // separate udp-only list here meant Prowlarr-sourced magnets found 0 peers.
  const List<String> trackers = kPublicTrackers;
  final buf = StringBuffer('magnet:?xt=urn:btih:$infoHash');
  if (name.trim().isNotEmpty) {
    buf.write('&dn=${Uri.encodeQueryComponent(name.trim())}');
  }
  for (final tr in trackers) {
    buf.write('&tr=${Uri.encodeQueryComponent(tr)}');
  }
  return buf.toString();
}

class ProwlarrException implements Exception {
  ProwlarrException(this.message);
  final String message;
  @override
  String toString() => 'ProwlarrException: $message';
}

/// Thin client over the Prowlarr v1 API. Notably, Prowlarr runs on the LAN
/// (CT109) and is NOT routed through the torrent proxy — only the actual
/// swarm/Real-Debrid traffic needs hiding, and Prowlarr talking to its
/// indexers is already its own concern.
class ProwlarrClient {
  ProwlarrClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

  Future<Map<String, String>> _headers() async => {
        'X-Api-Key': await BeamConfig.getProwlarrKey(),
        'Accept': 'application/json',
      };

  Uri _u(String path, [Map<String, dynamic>? query]) {
    final base = Uri.parse('${BeamConfig.prowlarrUrl}/api/v1$path');
    if (query == null) return base;
    return base.replace(
      queryParameters: query.map((k, v) => MapEntry(k, '$v')),
    );
  }

  /// Returns true when the configured URL+key answers `/health` with 200.
  Future<bool> testConnection() async {
    try {
      final r = await _http
          .get(_u('/health'), headers: await _headers())
          .timeout(const Duration(seconds: 8));
      return r.statusCode == 200;
    } catch (e) {
      appLogger.w('Prowlarr health check failed: $e');
      return false;
    }
  }

  /// Lists the configured indexers (id + name), useful for a settings panel.
  Future<List<Map<String, dynamic>>> indexers() async {
    final r = await _http
        .get(_u('/indexer'), headers: await _headers())
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw ProwlarrException('indexer list ${r.statusCode}');
    }
    final data = jsonDecode(r.body);
    if (data is! List) return const [];
    return data.cast<Map<String, dynamic>>();
  }

  /// Aggregated search across all (or the given) indexers.
  ///
  /// [categories] default to movies (2000) + TV (5000) top-level buckets.
  Future<List<ProwlarrResult>> search(
    String query, {
    List<int>? indexerIds,
    List<int> categories = const [2000, 5000],
    String type = 'search',
  }) async {
    if (query.trim().isEmpty) return const [];
    // Prowlarr accepts repeated indexerIds / categories params. Uri's
    // queryParameters can't express repeats from a Map, so build manually.
    final params = <String, List<String>>{
      'query': [query.trim()],
      'type': [type],
      if (categories.isNotEmpty)
        'categories': categories.map((e) => '$e').toList(),
      if (indexerIds != null && indexerIds.isNotEmpty)
        'indexerIds': indexerIds.map((e) => '$e').toList(),
    };
    final uri = Uri.parse('${BeamConfig.prowlarrUrl}/api/v1/search')
        .replace(queryParameters: params);

    final r = await _http
        .get(uri, headers: await _headers())
        .timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) {
      throw ProwlarrException('search ${r.statusCode}: ${r.body}');
    }
    final data = jsonDecode(r.body);
    if (data is! List) return const [];
    final results = data
        .whereType<Map<String, dynamic>>()
        .map(ProwlarrResult.fromJson)
        .toList();
    // Best-quality-first: seeders descending, then size descending.
    results.sort((a, b) {
      final s = b.seeders.compareTo(a.seeders);
      if (s != 0) return s;
      return b.size.compareTo(a.size);
    });
    return results;
  }

  void dispose() => _http.close();
}
