import 'indexer_search.dart' show buildMagnet;
import 'prowlarr_client.dart';

/// Validates a user-supplied v1 magnet without fetching or guessing metadata.
abstract final class MagnetSource {
  static ProwlarrResult parse(String input, {String? title, int? seeders, int? size}) {
    if (input.isEmpty ||
        RegExp(r'\s|[\x00-\x1f\x7f-\x9f]').hasMatch(input) ||
        RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(input)) {
      throw const FormatException('Enter a valid magnet link without unescaped whitespace.');
    }
    final uri = Uri.parse(input);
    if (uri.scheme.toLowerCase() != 'magnet' ||
        uri.hasAuthority ||
        uri.path.isNotEmpty ||
        uri.hasFragment ||
        !uri.hasQuery) {
      throw const FormatException('A magnet link is required.');
    }
    final params = uri.queryParametersAll;
    for (final entry in params.entries) {
      if (_hasControl(entry.key) || entry.value.any(_hasControl)) {
        throw const FormatException('The magnet link contains control characters.');
      }
    }
    final topics = params['xt'];
    if (topics == null || topics.isEmpty) {
      throw const FormatException('The magnet link has no BitTorrent hash.');
    }
    String? hash;
    for (final topic in topics) {
      final match = RegExp(r'^urn:btih:([0-9a-fA-F]{40}|[a-zA-Z2-7]{32})$', caseSensitive: false).firstMatch(topic);
      if (match == null) throw const FormatException('The magnet link requires a valid v1 BitTorrent hash.');
      final normalized = infoHashFromMagnet('magnet:?xt=urn:btih:${match.group(1)}')!;
      if (hash != null && hash != normalized) {
        throw const FormatException('The magnet link contains conflicting BitTorrent hashes.');
      }
      hash = normalized;
    }
    if ((seeders ?? 0) < 0 || (size ?? 0) < 0 || (title != null && _hasControl(title))) {
      throw const FormatException('Invalid magnet source metadata.');
    }
    final names = params['dn'] ?? const <String>[];
    final name = names
        .map((value) => value.trim())
        .firstWhere(
          (value) => value.isNotEmpty,
          orElse: () => title?.trim().isNotEmpty == true ? title!.trim() : 'Magnet source',
        );
    final defaults = Uri.parse(buildMagnet(hash!, name)).queryParametersAll['tr'] ?? const <String>[];
    final trackers = <String>{...?params['tr']?.where((value) => value.isNotEmpty), ...defaults};
    // Keep xt literal: the shared release/resume identity extractor expects
    // urn:btih in this form. Decode then encode each other parameter exactly once.
    final output = StringBuffer('magnet:?xt=urn:btih:$hash&dn=${Uri.encodeQueryComponent(name)}');
    for (final tracker in trackers) {
      output.write('&tr=${Uri.encodeQueryComponent(tracker)}');
    }
    for (final entry in params.entries) {
      if (entry.key == 'xt' || entry.key == 'dn' || entry.key == 'tr') continue;
      for (final value in entry.value) {
        output.write('&${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(value)}');
      }
    }
    return ProwlarrResult(
      title: name,
      indexer: 'Magnet link',
      size: size ?? 0,
      seeders: seeders ?? 0,
      leechers: 0,
      magnetUrl: output.toString(),
      downloadUrl: null,
      infoUrl: null,
      categories: const [],
      publishDate: null,
    );
  }

  static bool _hasControl(String value) => RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value);
}
