import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/beam/indexer_search.dart' show buildMagnet;
import 'package:plezy/services/beam/magnet_source.dart';

const _hash = '0123456789abcdef0123456789abcdef01234567';
const _base32 = 'AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH';
const _magnet = 'magnet:?xt=urn:btih:$_hash';

void main() {
  test('valid hex link has stable actual hash and honest default metadata', () {
    final source = MagnetSource.parse('MAGNET:?xt=urn:btih:${_hash.toUpperCase()}');
    expect(source.infoHash, _hash);
    expect(source.grabLink, source.magnetUrl);
    expect(source.title, 'Magnet source');
    expect(source.indexer, 'Magnet link');
    expect(source.seeders, 0);
    expect(source.size, 0);
    expect(source.leechers, 0);
    expect(source.categories, isEmpty);
    expect(source.downloadUrl, isNull);
    expect(source.infoUrl, isNull);
    expect(source.publishDate, isNull);
  });

  test('base32 and percent-encoded exact topic normalize to the same hex identity', () {
    final encoded = Uri.encodeQueryComponent('urn:btih:$_base32');
    expect(MagnetSource.parse('magnet:?xt=$encoded').infoHash, _hash);
    expect(MagnetSource.parse('magnet:?xt=urn:btih:${_base32.toLowerCase()}').infoHash, _hash);
    expect(MagnetSource.parse('$_magnet&xt=urn:btih:$_base32').infoHash, _hash);
  });

  test('display name decodes once and overrides supplied fallback without episode guessing', () {
    const name = 'Pioneer One & friends + 100%';
    final source = MagnetSource.parse(
      '$_magnet&dn=${Uri.encodeQueryComponent(name)}',
      title: 'Fallback',
      seeders: 12,
      size: 123456,
    );
    expect(source.title, name);
    expect(Uri.parse(source.magnetUrl!).queryParameters['dn'], name);
    expect(source.seeders, 12);
    expect(source.size, 123456);
    expect(source.categories, isEmpty);
    expect(MagnetSource.parse('$_magnet&dn=%20%20', title: ' A title ').title, 'A title');
    expect(MagnetSource.parse('$_magnet&dn=', title: ' ').title, 'Magnet source');
  });

  test('retains supplied trackers and supplemental parameters while deduplicating defaults', () {
    const custom = 'https://tracker.example/announce?pass=hello+world&key=abc';
    final defaults = Uri.parse(buildMagnet(_hash, 'fixture')).queryParametersAll['tr']!;
    final source = MagnetSource.parse(
      '$_magnet&tr=${Uri.encodeQueryComponent(custom)}'
      '&tr=${Uri.encodeQueryComponent(defaults.first)}&tr=${Uri.encodeQueryComponent(custom)}'
      '&ws=https%3A%2F%2Fexample.org%2Fvideo',
    );
    final params = Uri.parse(source.magnetUrl!).queryParametersAll;
    expect(params['tr']!.first, custom);
    expect(params['tr']!.toSet(), {custom, ...defaults});
    expect(params['tr']!.length, params['tr']!.toSet().length);
    expect(params['ws'], ['https://example.org/video']);
    expect(source.infoHash, _hash);
    expect(MagnetSource.parse(source.magnetUrl!).magnetUrl, source.magnetUrl);
  });

  for (final input in <String>[
    '',
    'https://example.org/video.torrent',
    '$_magnet ',
    '\n$_magnet',
    '$_magnet&dn=unescaped space',
    'magnet://host?xt=urn:btih:$_hash',
    'magnet:path?xt=urn:btih:$_hash',
    '$_magnet#fragment',
    'magnet:?dn=NoHash',
    'magnet:?xt=urn:btih:short',
    'magnet:?xt=urn:btih:${'z' * 40}',
    'magnet:?xt=urn:btih:${'1' * 32}',
    'magnet:?xt=urn:btih:$_hash.extra',
    '$_magnet&xt=urn:btih:${'f' * 40}',
    '$_magnet&xt=',
    '$_magnet&dn=bad%escape',
    '$_magnet&dn=bad%',
    '$_magnet&dn=bad%0Aname',
    '$_magnet&tr=http%3A%2F%2Fexample.org%00',
    '$_magnet&dn=bad\u007fname',
    'magnet:?xt=urn%3Abtih%3A$_hash%20',
  ]) {
    test('rejects malformed or ambiguous magnet ${Uri.encodeComponent(input)}', () {
      expect(() => MagnetSource.parse(input), throwsFormatException);
    });
  }

  test('rejects invalid caller metadata instead of inventing count values', () {
    expect(() => MagnetSource.parse(_magnet, seeders: -1), throwsFormatException);
    expect(() => MagnetSource.parse(_magnet, size: -1), throwsFormatException);
    expect(() => MagnetSource.parse(_magnet, title: 'bad\nname'), throwsFormatException);
  });
}
