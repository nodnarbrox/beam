import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/beam/indexer_search.dart';

Map<String, Object> row(int id, String title, {String imdb = '1234567'}) => {
  'title': title,
  'hash': id.toRadixString(16).padLeft(40, '0'),
  'imdb_id': imdb,
  'size_bytes': '1000000',
  'seeds': '5',
  'peers': 2,
};
http.Response json(Object value, [int status = 200]) => http.Response(jsonEncode(value), status);

class _Client extends MockClient {
  _Client(super.fn);
  int closes = 0;
  @override
  void close() {
    closes++;
    super.close();
  }
}

void main() {
  test('IMDb row comparison handles omitted leading zeros without accepting conflicts', () async {
    final rows = [
      for (final entry in <Object>['0123456', 123456, 'tt0123456', '123457', 'invalid', -123456, 123456.0].indexed)
        {...row(entry.$1 + 1, 'Pioneer.One.S01E02.720p'), 'imdb_id': entry.$2},
    ];
    final source = EztvSource(
      clientFactory: () async => _Client((_) async => json({'torrents_count': rows.length, 'torrents': rows})),
    );
    final results = await source.searchEpisode(imdbId: 'tt0123456', show: 'Pioneer One', season: 1, episode: 2);
    expect(results.map((r) => r.infoHash), [for (var i = 1; i <= 3; i++) i.toRadixString(16).padLeft(40, '0')]);
  });
  test('verified show search finds requested older episode on second bounded page', () async {
    final pages = <String?>[];
    final client = _Client((request) async {
      pages.add(request.url.queryParameters['page']);
      expect(request.url.queryParameters['imdb_id'], '1234567');
      expect(request.url.queryParameters['limit'], '100');
      return pages.length == 1
          ? json({
              'torrents_count': 200,
              'torrents': [for (var i = 0; i < 100; i++) row(i + 1, 'Pioneer.One.S02E01.720p')],
            })
          : json({
              'torrents_count': 200,
              'torrents': [row(200, 'Pioneer.One.S01E02.720p')],
            });
    });
    final result = await EztvSource(
      clientFactory: () async => client,
    ).searchEpisode(imdbId: 'tt1234567', show: 'Pioneer One', season: 1, episode: 2);
    expect(pages, ['1', '2']);
    expect(result.single.title, 'Pioneer.One.S01E02.720p');
    expect(client.closes, greaterThan(0));
  });

  test('same strict title, aliases, season and pack identity gates apply', () async {
    final client = _Client(
      (_) async => json({
        'torrents_count': 7,
        'torrents': [
          row(1, 'Other.Show.S01E02.720p'),
          row(2, 'Pioneer.One.S02E02.720p'),
          row(3, 'Pioneer.One.S01E03.720p'),
          row(4, 'Pioneer.One.S01E02.720p', imdb: '9999999'),
          row(5, 'Pioneer.One.S01.Complete.720p'),
          row(6, 'Verified.Alias.S01E02.720p'),
          row(7, 'Unverified.Alias.S01E02.720p'),
        ],
      }),
    );
    final result = await EztvSource(
      clientFactory: () async => client,
    ).searchEpisode(imdbId: 'tt1234567', show: 'Pioneer One', season: 1, episode: 2, aliases: ['Verified Alias']);
    expect(result.map((r) => r.title), ['Pioneer.One.S01.Complete.720p', 'Verified.Alias.S01E02.720p']);
  });

  test('no match scans at most three pages and repeated pages stop early', () async {
    for (final repeated in [false, true]) {
      var calls = 0;
      final source = EztvSource(
        clientFactory: () async => _Client((_) async {
          calls++;
          return json({
            'torrents_count': 1000,
            'torrents': [
              for (var i = 0; i < 100; i++) row((repeated ? 0 : calls * 100) + i, 'Pioneer.One.S02E02.720p'),
            ],
          });
        }),
      );
      expect(await source.searchEpisode(imdbId: 'tt1234567', show: 'Pioneer One', season: 1, episode: 2), isEmpty);
      expect(calls, repeated ? 2 : 3);
    }
  });

  test('invalid or guessed IMDb never opens a client', () async {
    var calls = 0;
    final source = EztvSource(
      clientFactory: () async {
        calls++;
        return _Client((_) async => json({}));
      },
    );
    for (final id in ['Pioneer One', 'tt12', '1234567 S01E02', '']) {
      expect(await source.searchEpisode(imdbId: id, show: 'Pioneer One', season: 1, episode: 2), isEmpty);
    }
    expect(calls, 0);
  });

  test('live empty shape is valid, provider failure and malformed JSON are not empty success', () async {
    final empty = EztvSource(clientFactory: () async => _Client((_) async => json({'torrents_count': 0})));
    expect(await empty.searchEpisode(imdbId: 'tt1234567', show: 'Pioneer One', season: 1, episode: 2), isEmpty);
    for (final response in [
      json({}, 503),
      json({'torrents_count': 5}),
      http.Response('not-json', 200),
    ]) {
      final source = EztvSource(clientFactory: () async => _Client((_) async => response));
      await expectLater(
        source.searchEpisode(imdbId: 'tt1234567', show: 'Pioneer One', season: 1, episode: 2),
        throwsA(anything),
      );
    }
  });

  test('cancellation closes client promptly and late response cannot fetch another page', () async {
    final cancel = Completer<void>();
    final response = Completer<http.Response>();
    var calls = 0;
    final client = _Client((_) {
      calls++;
      return response.future;
    });
    final pending = EztvSource(
      clientFactory: () async => client,
    ).searchEpisode(imdbId: 'tt1234567', show: 'Pioneer One', season: 1, episode: 2, cancelled: cancel.future);
    await Future<void>.delayed(Duration.zero);
    cancel.complete();
    expect(await pending, isEmpty);
    response.complete(
      json({
        'torrents_count': 1000,
        'torrents': [for (var i = 0; i < 100; i++) row(i, 'Pioneer.One.S02E01')],
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(client.closes, greaterThan(0));
  });

  test('total deadline closes late-created client before any request', () async {
    final opened = Completer<http.Client>();
    var calls = 0;
    final client = _Client((_) async {
      calls++;
      return json({'torrents_count': 0});
    });
    final pending = EztvSource(
      clientFactory: () => opened.future,
      timeout: const Duration(milliseconds: 5),
    ).searchEpisode(imdbId: 'tt1234567', show: 'Pioneer One', season: 1, episode: 2);
    await expectLater(pending, throwsA(isA<TimeoutException>()));
    opened.complete(client);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);
    expect(client.closes, greaterThan(0));
  });
}
