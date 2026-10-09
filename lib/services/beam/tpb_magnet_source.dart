import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import 'beam_http.dart';
import 'indexer_search.dart' show IndexerSource, IndexerUnavailableException;
import 'magnet_source.dart';
import 'prowlarr_client.dart';

/// One bounded, metadata-only HTML search when the TPB JSON index is empty.
/// Parses actual links; scripts, images, detail pages and torrents are not fetched.
class TpbMagnetSource implements IndexerSource {
  TpbMagnetSource({Future<http.Client> Function()? clientFactory, this.timeout = const Duration(seconds: 12)})
    : _clientFactory = clientFactory ?? BeamHttp.client;
  final Future<http.Client> Function() _clientFactory;
  final Duration timeout;
  static const _maxBytes = 2 * 1024 * 1024;
  static final _origin = Uri.parse('https://tpb.party');
  @override
  String get name => 'ThePirateBay HTML';

  Future<Document> _load(Uri uri) async {
    http.Client? client;
    var active = true;
    Future<Document> fetch() async {
      final opened = await _clientFactory();
      client = opened;
      if (!active) {
        opened.close();
        throw TimeoutException('TPB lookup expired');
      }
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers.addAll({'User-Agent': 'Plezy/1.0', 'Accept': 'text/html'});
      final response = await opened.send(request);
      if (!active) throw TimeoutException('TPB lookup expired');
      if (response.statusCode != 200) throw IndexerUnavailableException('TPB HTML HTTP ${response.statusCode}');
      if ((response.contentLength ?? 0) > _maxBytes) throw IndexerUnavailableException('TPB HTML response too large');
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (!active) throw TimeoutException('TPB lookup expired');
        if (bytes.length + chunk.length > _maxBytes) throw IndexerUnavailableException('TPB HTML response too large');
        bytes.add(chunk);
      }
      return html.parse(utf8.decode(bytes.takeBytes(), allowMalformed: true));
    }

    try {
      return await fetch().timeout(timeout);
    } finally {
      active = false;
      client?.close();
    }
  }

  @override
  Future<List<ProwlarrResult>> search(String query, {List<int> categories = const [2000, 5000]}) async {
    if (query.trim().isEmpty) return const [];
    final uri = Uri(scheme: 'https', host: 'tpb.party', pathSegments: ['search', query.trim(), '1', '99', '0']);
    final doc = await _load(uri);
    final table = doc.querySelector('#searchResult');
    if (table == null) throw IndexerUnavailableException('TPB returned no recognizable search table');
    final headings = table.querySelectorAll('th').map((node) => _text(node).toLowerCase()).toList();
    int column(String key) => headings.indexWhere((text) => text == key || text.startsWith('$key '));
    final seedColumn = column('se');
    final leechColumn = column('le');
    final sizeColumn = column('size');
    final seen = <String>{};
    final results = <ProwlarrResult>[];
    for (final row in table.querySelectorAll('tr').take(101)) {
      final cells = row.children.where((child) => child.localName == 'td').toList();
      if (cells.isEmpty) continue;
      String cell(int index) => index < 0 || index >= cells.length ? '' : _text(cells[index]);
      final page = row.querySelectorAll('a[href]').where((a) => _pageUrl(a.attributes['href']) != null).firstOrNull;
      if (page == null) continue;
      final seeders = _count(
        seedColumn >= 0
            ? cell(seedColumn)
            : cells.length >= 4
            ? cell(cells.length - 2)
            : '',
      );
      final leechers = _count(
        leechColumn >= 0
            ? cell(leechColumn)
            : cells.length >= 4
            ? cell(cells.length - 1)
            : '',
      );
      final size = _size(sizeColumn >= 0 ? cell(sizeColumn) : _text(row.querySelector('.detDesc')));
      final candidate = _result(
        row,
        title: _text(page),
        size: size,
        seeders: seeders,
        leechers: leechers,
        infoUrl: _pageUrl(page.attributes['href'])!,
      );
      if (candidate == null || (candidate.categories.isNotEmpty && !candidate.categories.any(categories.contains))) {
        continue;
      }
      if (seen.add(candidate.infoHash!)) results.add(candidate);
    }
    return results;
  }

  /// Metadata-only lookup for an explicitly supported public detail page.
  Future<ProwlarrResult?> lookupPage(String url) async {
    if (!isSupportedPageUrl(url)) throw const FormatException('Unsupported TPB torrent page');
    final doc = await _load(Uri.parse(url));
    final details = doc.querySelector('#detailsframe');
    final title = _text(details?.querySelector('#title'));
    if (details == null || title.isEmpty) throw IndexerUnavailableException('TPB returned no torrent details');
    final values = <String, String>{};
    for (final label in details.querySelectorAll('dt')) {
      final value = label.nextElementSibling;
      if (value?.localName == 'dd') values[_text(label).toLowerCase().replaceAll(':', '')] = _text(value);
    }
    return _result(
      details,
      title: title,
      size: _size(values['size'] ?? ''),
      seeders: _count(values['seeders'] ?? ''),
      leechers: _count(values['leechers'] ?? ''),
      infoUrl: url,
    );
  }

  static String? _pageUrl(String? href) {
    if (href == null) return null;
    try {
      final value = _origin.resolve(href).toString();
      return isSupportedPageUrl(value) ? value : null;
    } on FormatException {
      return null;
    }
  }

  static bool isSupportedPageUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'tpb.party' &&
        !uri.hasPort &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        RegExp(r'^/torrent/[0-9]+(?:/[^/]*)?/?$').hasMatch(uri.path);
  }

  ProwlarrResult? _result(
    Element row, {
    required String title,
    required int size,
    required int seeders,
    required int leechers,
    required String infoUrl,
  }) {
    if (title.isEmpty) return null;
    ProwlarrResult? parsed;
    for (final anchor in row.querySelectorAll('a[href^="magnet:"]')) {
      try {
        final candidate = MagnetSource.parse(anchor.attributes['href']!, title: title, size: size, seeders: seeders);
        if (parsed != null && parsed.infoHash != candidate.infoHash) return null;
        parsed ??= candidate;
      } on FormatException {
        return null;
      }
    }
    if (parsed == null) return null;
    final ids = row
        .querySelectorAll('a[href*="/browse/"]')
        .map((a) {
          final uri = Uri.tryParse(a.attributes['href'] ?? '');
          return int.tryParse(uri?.pathSegments.lastOrNull ?? '');
        })
        .whereType<int>()
        .toSet();
    // Major Video often precedes its specific TV/movie link. Explicit adult
    // categories must never turn into an unknown, potentially eligible row.
    final cats = ids.any((id) => id >= 500 && id < 600)
        ? <int>[6000]
        : ids.any((id) => id == 205 || id == 208)
        ? <int>[5000]
        : ids.any([201, 202, 207, 209].contains)
        ? <int>[2000]
        : ids.any((id) => id < 200 || id >= 300)
        ? <int>[8000]
        : <int>[];
    return ProwlarrResult(
      title: parsed.title,
      indexer: name,
      size: size,
      seeders: seeders,
      leechers: leechers,
      magnetUrl: parsed.magnetUrl,
      downloadUrl: null,
      infoUrl: infoUrl,
      categories: cats,
      publishDate: null,
    );
  }

  static String _text(Element? element) => (element?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  static int _count(String text) => math.max(0, int.tryParse(text.replaceAll(',', '').trim()) ?? 0);
  static int _size(String text) {
    final exact = RegExp(r'([0-9,]+)\s*Bytes', caseSensitive: false).firstMatch(text);
    if (exact != null) return _count(exact.group(1)!);
    final match = RegExp(
      r'([0-9]+(?:\.[0-9]+)?)\s*(KiB|MiB|GiB|TiB|KB|MB|GB|TB|B)',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return 0;
    final unit = match.group(2)!.toUpperCase();
    final exponent = switch (unit[0]) {
      'K' => 1,
      'M' => 2,
      'G' => 3,
      'T' => 4,
      _ => 0,
    };
    return (double.parse(match.group(1)!) * math.pow(unit.contains('I') ? 1024 : 1000, exponent)).round();
  }
}
