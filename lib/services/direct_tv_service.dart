import 'dart:convert';

import 'package:http/http.dart' as http;

/// The same tuner endpoint Plex uses, with no Plex account or token involved.
class DirectTvChannel {
  final String number;
  final String name;
  final Uri stream;

  const DirectTvChannel(this.number, this.name, this.stream);
}

class DirectTvLineup {
  final List<DirectTvChannel> channels;
  final Set<String> majorNetworks;
  final Set<String> preloaded;

  const DirectTvLineup(this.channels, this.majorNetworks, this.preloaded);
}

class DirectTvService {
  static const defaultAddress = '';
  final http.Client _client;
  final Uri address;

  DirectTvService(String address, {http.Client? client})
    : address = parseAddress(address),
      _client = client ?? http.Client();

  static Uri parseAddress(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException('Enter a TV service address such as http://tv-server.local:8776');
    }
    return uri.replace(path: '');
  }

  Future<dynamic> _get(String path) async {
    final response = await _client.get(address.resolve(path)).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) throw const FormatException('TV service is unavailable.');
    return jsonDecode(response.body);
  }

  Future<DirectTvLineup> load() async {
    // Status is optional: ordinary HDHomeRun-compatible tuners need not have it.
    final statusFuture = _get('/health').then<Map<String, dynamic>>(
      (value) => value is Map<String, dynamic> ? value : {},
      onError: (Object _) => <String, dynamic>{},
    );
    final dynamic rows = await _get('/lineup.json');
    if (rows is! List) throw const FormatException('TV service returned an invalid channel list.');
    final channels = <DirectTvChannel>[];
    final seen = <String>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final number = '${row['GuideNumber'] ?? ''}';
      final name = '${row['GuideName'] ?? ''}';
      final source = Uri.tryParse('${row['URL'] ?? ''}');
      if (number.isEmpty ||
          name.isEmpty ||
          source == null ||
          !['http', 'https'].contains(source.scheme) ||
          source.userInfo.isNotEmpty) {
        continue;
      }
      // Use the configured address even when the tuner advertises its LAN IP.
      // Reject arbitrary provider paths instead of leaking credentials or silently
      // bypassing the shared connection pool.
      if (source.path != '/auto/v$number' || source.hasQuery || source.hasFragment) continue;
      if (seen.add(number)) channels.add(DirectTvChannel(number, name, address.resolve(source.path)));
    }
    if (channels.isEmpty) throw const FormatException('No playable channels were returned.');
    final status = await statusFuture;
    Set<String> numbers(String key) =>
        status[key] is List ? (status[key] as List).map((v) => '$v').toSet() : <String>{};
    return DirectTvLineup(channels, numbers('preload_candidates'), numbers('preloaded'));
  }

  void close() => _client.close();
}
