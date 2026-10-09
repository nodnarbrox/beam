import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/beam/indexer_search.dart';
import 'package:plezy/services/beam/tpb_magnet_source.dart';

const hash = '8d37e46f1d45b72a0c3053c9e520446b2d75f78c';
String row({
  String name = 'Actual.Show.S01E02',
  String? dn,
  String btih = hash,
  String category = '208',
  String seeds = '11',
  String? extra,
}) =>
    '''
<tr><td><a href="/browse/200">Video</a><a href="/browse/$category">Kind</a></td>
<td><a href="http://[bad">malformed</a><a href="/torrent/78834156/title">$name</a></td><td>date</td>
<td><a href="magnet:?xt=urn:btih:$btih&amp;dn=${Uri.encodeQueryComponent(dn ?? name)}&amp;tr=udp%3A%2F%2Ftracker.example%3A80&amp;xl=123">magnet</a>${extra ?? ''}</td>
<td>2.58 GiB</td><td>$seeds</td><td>3</td></tr>''';
String table(String rows) =>
    '<table id="searchResult"><tr><th>Type</th><th>Name</th><th>Uploaded</th><th></th><th>Size</th><th>SE</th><th>LE</th></tr>$rows</table>';
TpbMagnetSource source(String body, {int status = 200}) =>
    TpbMagnetSource(clientFactory: () async => MockClient((_) async => http.Response(body, status)));

class TrackingClient extends MockClient {
  TrackingClient(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  test('saved real public HTML yields target magnet, actual title, swarm and size', () async {
    final result = await source(
      File('test/fixtures/tpb/search.html').readAsStringSync(),
    ).search('1000-lb Sisters S07E01', categories: [5000]);
    final target = result.singleWhere((r) => r.infoHash == hash);
    expect(target.title, '1000-lb Sisters S07E01 1080p WEB h264-FREQUENCY');
    expect(target.seeders, 11);
    expect(target.leechers, 3);
    expect(target.size, (2.58 * 1024 * 1024 * 1024).round());
    expect(target.categories, [5000]);
    expect(target.magnetUrl, contains('tr='));
    expect(result.map((r) => r.infoHash).toSet().length, result.length);
  });
  test('metadata stays within row; dn wins and supplied trackers/extra params survive', () async {
    final results = await source(
      table(
        row(name: 'Requested Show S01E02', dn: 'Other.Show.S01E02') +
            row(name: 'Movie.2008', btih: 'a' * 40, category: '201', seeds: '4'),
      ),
    ).search('Requested Show');
    expect(results.map((r) => r.title), ['Other.Show.S01E02', 'Movie.2008']);
    expect(results.map((r) => r.seeders), [11, 4]);
    final uri = Uri.parse(results.first.magnetUrl!);
    expect(uri.queryParametersAll['tr'], contains('udp://tracker.example:80'));
    expect(uri.queryParameters['xl'], '123');
    expect(results.map((r) => r.categories.single), [5000, 2000]);
  });
  test('major category does not hide TV and explicit adult/audio rows are excluded', () async {
    final results = await source(
      table(row() + row(btih: 'b' * 40, category: '501') + row(btih: 'c' * 40, category: '101')),
    ).search('Show');
    expect(results.length, 1);
    expect(results.single.categories, [5000]);
  });
  test('requested movie/TV category is respected', () async {
    final results = await source(
      table(row() + row(name: 'Movie.2008', btih: 'a' * 40, category: '201')),
    ).search('anything', categories: [2000]);
    expect(results.single.title, 'Movie.2008');
  });
  test('duplicates removed, invalid hashes and conflicting same-row magnets rejected', () async {
    final result = await source(
      table(
        row() +
            row() +
            row(btih: 'not-a-hash') +
            row(btih: 'a' * 40, extra: '<a href="magnet:?xt=urn:btih:${'b' * 40}">other</a>'),
      ),
    ).search('query');
    expect(result.length, 1);
  });
  test('unknown seeds remain zero without fabricating swarm data', () async {
    expect((await source(table(row(seeds: '?'))).search('query')).single.seeders, 0);
  });
  test('classic four-column TPB layout uses same-row description and swarm columns', () async {
    final html =
        '''<table id="searchResult"><tr><td><a href="/browse/205">TV</a></td><td><a href="/torrent/1/name">Classic S01E02</a><a href="magnet:?xt=urn:btih:$hash">magnet</a><font class="detDesc">Uploaded today, Size 750 MiB, ULed</font></td><td>1,234</td><td>2</td></tr></table>''';
    final result = (await source(html).search('query')).single;
    expect(result.seeders, 1234);
    expect(result.leechers, 2);
    expect(result.size, 750 * 1024 * 1024);
  });
  test('empty recognizable result table is empty; challenge/malformed document fails', () async {
    expect(await source(table('')).search('query'), isEmpty);
    await expectLater(
      source('<html>Checking your browser</html>').search('query'),
      throwsA(isA<IndexerUnavailableException>()),
    );
    await expectLater(source(table(row()), status: 403).search('query'), throwsA(isA<IndexerUnavailableException>()));
  });
  test('response bound rejects oversized advertised body and closes client', () async {
    final client = TrackingClient((_) async => http.Response('x' * (2 * 1024 * 1024 + 1), 200));
    await expectLater(
      TpbMagnetSource(clientFactory: () async => client).search('query'),
      throwsA(isA<IndexerUnavailableException>()),
    );
    expect(client.closed, isTrue);
  });
  test('streaming body cap works even without advertised content length', () async {
    final client = MockClient.streaming(
      (_, _) async => http.StreamedResponse(Stream.value(List.filled(2 * 1024 * 1024 + 1, 120)), 200),
    );
    await expectLater(
      TpbMagnetSource(clientFactory: () async => client).search('query'),
      throwsA(isA<IndexerUnavailableException>()),
    );
  });
  test('deadline closes late factory before it can send', () async {
    var sends = 0;
    final client = TrackingClient((_) async {
      sends++;
      return http.Response(table(row()), 200);
    });
    final ready = Completer<http.Client>();
    final request = TpbMagnetSource(
      clientFactory: () => ready.future,
      timeout: const Duration(milliseconds: 5),
    ).search('query');
    await expectLater(request, throwsA(isA<TimeoutException>()));
    ready.complete(client);
    await Future<void>.delayed(Duration.zero);
    expect(client.closed, isTrue);
    expect(sends, 0);
  });
  test('one encoded search request only, no follow-up page/script/media requests', () async {
    final calls = <Uri>[];
    final client = TrackingClient((request) async {
      calls.add(request.url);
      expect(request.followRedirects, isFalse);
      return http.Response(table(row()), 200);
    });
    await TpbMagnetSource(clientFactory: () async => client).search('Movie & TV / 2026');
    expect(calls.single.pathSegments, ['search', 'Movie & TV / 2026', '1', '99', '0']);
    expect(client.closed, isTrue);
  });
  for (final apiStatus in [200, 503]) {
    test('Apibay ${apiStatus == 200 ? 'empty' : 'failure'} invokes HTML once', () async {
      var api = 0;
      var html = 0;
      final adapter = ApibaySource(
        baseUrl: 'https://apibay.example',
        clientFactory: () async => MockClient((_) async {
          api++;
          return http.Response('[]', apiStatus);
        }),
        fallback: TpbMagnetSource(
          clientFactory: () async => MockClient((_) async {
            html++;
            return http.Response(table(row()), 200);
          }),
        ),
      );
      expect((await adapter.search('Actual Show')).single.infoHash, hash);
      expect(api, 1);
      expect(html, 1);
    });
  }
  test('successful nonempty API never queries HTML', () async {
    final adapter = ApibaySource(
      baseUrl: 'https://apibay.example',
      clientFactory: () async => MockClient(
        (_) async => http.Response(
          jsonEncode([
            {'name': 'Actual Show', 'info_hash': hash, 'category': '208'},
          ]),
          200,
        ),
      ),
      fallback: TpbMagnetSource(clientFactory: () async => throw StateError('must not open')),
    );
    expect((await adapter.search('Actual Show')).single.infoHash, hash);
  });
  test('approved page lookup extracts real metadata, unsupported URL never sends', () async {
    final html =
        '''<div id="detailsframe"><h1 id="title">Actual.Show.S01E02</h1><dl><dt>Size:</dt><dd>2.58 GiB (2768304861 Bytes)</dd><dt>Seeders:</dt><dd>11</dd><dt>Leechers:</dt><dd>3</dd></dl><a href="/browse/208">TV</a><a href="magnet:?xt=urn:btih:$hash">magnet</a></div>''';
    final result = await source(html).lookupPage('https://tpb.party/torrent/78834156/name');
    expect(result!.infoHash, hash);
    expect(result.size, 2768304861);
    expect(result.seeders, 11);
    for (final url in [
      'http://tpb.party/torrent/1',
      'https://localhost/torrent/1',
      'https://tpb.party.evil/torrent/1',
      'https://tpb.party/torrent/1?token=secret',
    ]) {
      await expectLater(source(html).lookupPage(url), throwsFormatException);
    }
  });
}
