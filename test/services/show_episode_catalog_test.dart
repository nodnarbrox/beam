import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/beam/show_episode_catalog.dart';

const title = 'Spidey and His Amazing Friends';
Map<String, dynamic> show({int id = 43708, String name = title, String? premiered = '2021-08-06'}) => {
  'id': id,
  'name': name,
  'premiered': premiered,
  'url': 'https://www.tvmaze.com/shows/$id/spidey-and-his-amazing-friends',
  'externals': {'imdb': 'tt10862280', 'thetvdb': 404491},
  'image': {'original': 'https://fixture/show.jpg'},
  'summary': '<p>A team &amp; friends.</p>',
};
http.Response json(Object? body, [int status = 200]) => http.Response(jsonEncode(body), status);
Map<String, dynamic> episode(
  int id,
  int season,
  int? number, {
  String type = 'regular',
  String airdate = '2025-07-01',
}) => {
  'id': id,
  'season': season,
  'number': number,
  'name': 'Episode title $id',
  'type': type,
  'url': 'https://www.tvmaze.com/episodes/$id',
  'airdate': airdate,
  'airstamp': '${airdate}T12:00:00+00:00',
  'image': {'medium': 'https://fixture/episode-$id.jpg'},
  'summary': '<p>First &amp; second.<br>Next line.</p>',
  'runtime': 12,
};

http.Response catalog(http.Request request) {
  if (request.url.path == '/shows/43708/akas') {
    return json([
      {'name': "Marvel's Spidey and His Amazing Friends"},
    ]);
  }
  if (request.url.path == '/search/shows') {
    return json([
      {'show': show()},
    ]);
  }
  if (request.url.path == '/lookup/shows') return json(show());
  if (request.url.path == '/shows/43708/seasons') {
    return json([
      for (final number in [1, 2, 3, 4, 5])
        {'id': 100 + number, 'number': number, 'name': '', 'episodeOrder': 999, 'premiereDate': '2021-08-06'},
    ]);
  }
  if (request.url.path == '/shows/43708/episodes') {
    expect(request.url.queryParameters['specials'], '1');
    return json([
      episode(1, 1, 1),
      episode(2, 4, 9),
      episode(3, 4, 13),
      episode(4, 4, null, type: 'significant_special'),
      episode(5, 0, null, type: 'insignificant_special'),
      episode(6, 5, 1, airdate: '2099-01-01'),
      episode(7, 5, null, airdate: '2099-01-02'),
    ]);
  }
  throw StateError('Unexpected request ${request.url}');
}

class TrackedClient extends MockClient {
  TrackedClient(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  test('optional alias outage does not discard verified episodes', () async {
    final service = ShowEpisodeCatalog(
      clientFactory: () async => MockClient((request) async {
        if (request.url.path.endsWith('/akas')) return http.Response('unavailable', 503);
        return catalog(request);
      }),
    );
    final result = (await service.load(title: title, year: 2021))!;
    expect(result.episodes, hasLength(7));
    expect(result.aliases, isEmpty);
    expect(result.aliasesComplete, isFalse);
  });
  test('cached healthy episodes retry failed aliases without refetching show identity or episodes', () async {
    final paths = <String>[];
    var aliasesFailed = true;
    final service = ShowEpisodeCatalog(
      clientFactory: () async => MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/akas') && aliasesFailed) return http.Response('unavailable', 503);
        return catalog(request);
      }),
    );
    final first = (await service.load(title: title, year: 2021))!;
    expect(first.aliasesComplete, isFalse);
    aliasesFailed = false;
    final recovered = (await service.load(title: title, year: 2021))!;
    expect(recovered.aliasesComplete, isTrue);
    expect(recovered.aliases, ["Marvel's Spidey and His Amazing Friends"]);
    expect(recovered.episodes, same(first.episodes));
    expect(recovered.seasons, same(first.seasons));
    expect(paths.where((path) => path.endsWith('/akas')), hasLength(2));
    expect(paths.where((path) => path == '/search/shows'), hasLength(1));
    expect(paths.where((path) => path.endsWith('/episodes')), hasLength(1));
    final cached = (await service.load(title: title, year: 2021))!;
    expect(cached.aliases, recovered.aliases);
    expect(paths, hasLength(5));
  });
  test('successful empty aliases are complete and retain normal cache behavior', () async {
    var calls = 0;
    final service = ShowEpisodeCatalog(
      clientFactory: () async => MockClient((request) async {
        calls++;
        return request.url.path.endsWith('/akas') ? json([]) : catalog(request);
      }),
    );
    final result = (await service.load(title: title, year: 2021))!;
    expect(result.aliases, isEmpty);
    expect(result.aliasesComplete, isTrue);
    expect(await service.load(title: title, year: 2021), same(result));
    expect(await service.retryAliases(result), same(result));
    expect(calls, 4);
  });
  test('simultaneous retries share the verified ID request and preserve each healthy catalog', () async {
    final gate = Completer<http.Response>();
    var calls = 0;
    final client = TrackedClient((request) async {
      calls++;
      expect(request.url.path, '/shows/43708/akas');
      return gate.future;
    });
    final service = ShowEpisodeCatalog(clientFactory: () async => client);
    const result = ShowEpisodeCatalogResult(
      tvmazeId: 43708,
      name: title,
      sourceUrl: 'https://www.tvmaze.com/shows/43708',
      aliasesComplete: false,
    );
    final first = service.retryAliases(result);
    final second = service.retryAliases(result);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    gate.complete(
      json([
        {'name': "Marvel's Spidey and His Amazing Friends"},
      ]),
    );
    for (final recovered in await Future.wait([first, second])) {
      expect(recovered.tvmazeId, result.tvmazeId);
      expect(recovered.aliasesComplete, isTrue);
      expect(recovered.aliases, hasLength(1));
    }
    expect(client.closed, isTrue);
  });
  test('alias retry timeout retains healthy metadata and closes a late client without requests', () {
    fakeAsync((async) {
      final factory = Completer<http.Client>();
      var requests = 0;
      final client = TrackedClient((request) async {
        requests++;
        return json([]);
      });
      final service = ShowEpisodeCatalog(clientFactory: () => factory.future);
      const original = ShowEpisodeCatalogResult(
        tvmazeId: 43708,
        name: title,
        sourceUrl: 'https://www.tvmaze.com/shows/43708',
        aliasesComplete: false,
      );
      ShowEpisodeCatalogResult? result;
      unawaited(service.retryAliases(original).then((value) => result = value));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();
      expect(result, same(original));
      factory.complete(client);
      async.flushMicrotasks();
      expect(requests, 0);
      expect(client.closed, isTrue);
    });
  });
  test(
    'loads all actual seasons and episode metadata without expanding episode counts or inventing specials numbers',
    () async {
      final client = TrackedClient((request) async => catalog(request));
      final service = ShowEpisodeCatalog(clientFactory: () async => client);
      final result = (await service.load(title: title, year: 2021))!;
      expect(result.tvmazeId, 43708);
      expect(result.year, 2021);
      expect(result.imdbId, 'tt10862280');
      expect(result.tvdbId, 404491);
      expect(result.aliases, ["Marvel's Spidey and His Amazing Friends"]);
      expect(result.attributionName, 'TVmaze');
      expect(result.sourceUrl, contains('tvmaze.com/shows/43708'));
      expect(result.imageUrl, 'https://fixture/show.jpg');
      expect(result.summary, 'A team & friends.');
      expect(result.seasons.map((season) => season.number), [0, 1, 2, 3, 4, 5]);
      expect(result.episodes, hasLength(7));
      expect(
        result.seasons.singleWhere((season) => season.number == 4).episodes.map((episode) => episode.episodeNumber),
        [9, 13, null],
      );
      final ordinary = result.episodes[1];
      expect(ordinary.name, 'Episode title 2');
      expect(ordinary.airdate, '2025-07-01');
      expect(ordinary.imageUrl, 'https://fixture/episode-2.jpg');
      expect(ordinary.summary, 'First & second.\nNext line.');
      expect(ordinary.runtimeMinutes, 12);
      expect(ordinary.isSpecial, isFalse);
      expect(result.episodes[3].isSpecial, isTrue);
      expect(result.episodes[3].episodeNumber, isNull);
      expect(result.episodes.last.episodeNumber, isNull);
      expect(result.episodes.last.isSpecial, isFalse);
      expect(result.episodes.last.airStamp!.year, 2099);
      expect(client.closed, isTrue);
      expect(() => result.episodes.clear(), throwsUnsupportedError);
    },
  );

  test('fuzzy search ranking cannot select related show or remake instead of exact title and premiere year', () async {
    final service = ShowEpisodeCatalog(
      clientFactory: () async => MockClient((request) async {
        if (request.url.path == '/search/shows') {
          return json([
            {'show': show(id: 1, name: 'Meet Spidey and His Amazing Friends')},
            {'show': show(id: 2, premiered: '2024-08-06')},
            {'show': show()},
          ]);
        }
        return catalog(request);
      }),
    );
    expect((await service.load(title: 'Spidey and His Amazing Friends', year: 2021))!.tvmazeId, 43708);
  });

  for (final candidates in [
    [show(id: 1), show(id: 2)],
    [show(name: "Marvel's Spidey and His Amazing Friends")],
    [show(premiered: '2024-08-06')],
    [show(premiered: null)],
  ]) {
    test(
      'ambiguous, prefixed, wrong-year or unknown-premiere match never fetches episodes: ${candidates.first['name']} ${candidates.first['premiered']}',
      () async {
        var calls = 0;
        final service = ShowEpisodeCatalog(
          clientFactory: () async => MockClient((request) async {
            calls++;
            expect(request.url.path, '/search/shows');
            return json(candidates.map((show) => {'show': show}).toList());
          }),
        );
        expect(await service.load(title: title, year: 2021), isNull);
        expect(calls, 1);
      },
    );
  }

  test('missing premiere year or malformed external IDs cannot trigger guessed searches', () async {
    var clients = 0;
    final service = ShowEpisodeCatalog(
      clientFactory: () async {
        clients++;
        throw StateError('must not fetch');
      },
    );
    expect(await service.load(title: title), isNull);
    expect(await service.load(title: title, year: 2021, imdbId: 'bad-id'), isNull);
    expect(await service.load(title: title, year: 2021, tvdbId: -1), isNull);
    expect(clients, 0);
  });

  test('exact external ID follows official lookup redirect and permits a provider title variation', () async {
    final paths = <String>[];
    final service = ShowEpisodeCatalog(
      clientFactory: () async => MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/lookup/shows') {
          expect(request.url.queryParameters, {'imdb': 'tt10862280'});
          return http.Response('', 301, headers: {'location': 'https://api.tvmaze.com/shows/43708'});
        }
        if (request.url.path == '/shows/43708') return json(show(name: "Marvel's Spidey and His Amazing Friends"));
        return catalog(request);
      }),
    );
    final result = await service.load(title: title, year: 2021, imdbId: 'tt10862280', tvdbId: 404491);
    expect(result!.tvmazeId, 43708);
    expect(paths, isNot(contains('/search/shows')));
  });

  test('conflicting external IDs and unknown IDs never fall back to title guessing', () async {
    var missing = false;
    final service = ShowEpisodeCatalog(
      clientFactory: () async => MockClient((request) async {
        expect(request.url.path, '/lookup/shows');
        return missing ? http.Response('', 404) : json(show());
      }),
    );
    expect(await service.load(title: title, year: 2021, imdbId: 'tt10862280', tvdbId: 123), isNull);
    missing = true;
    expect(await service.load(title: title, year: 2021, imdbId: 'tt00000'), isNull);
  });

  test('in-flight loads deduplicate, successful cache expires, and clients close', () async {
    var now = DateTime(2026);
    final pendingClient = Completer<http.Client>();
    var factories = 0;
    final clients = <TrackedClient>[];
    final service = ShowEpisodeCatalog(
      now: () => now,
      clientFactory: () async {
        factories++;
        if (factories == 1) return pendingClient.future;
        final client = TrackedClient((request) async => catalog(request));
        clients.add(client);
        return client;
      },
    );
    final first = service.load(title: title, year: 2021);
    final second = service.load(title: title, year: 2021);
    expect(identical(first, second), isTrue);
    final initial = TrackedClient((request) async => catalog(request));
    pendingClient.complete(initial);
    final results = await Future.wait([first, second]);
    expect(results[0], same(results[1]));
    expect(await service.load(title: title, year: 2021), same(results.first));
    expect(factories, 1);
    now = now.add(const Duration(hours: 1, seconds: 1));
    await service.load(title: title, year: 2021);
    expect(factories, 2);
    expect(initial.closed, isTrue);
    expect(clients.single.closed, isTrue);
  });

  for (final malformed in [false, true]) {
    test('${malformed ? "malformed episode payload" : "HTTP outage"} throws and is not cached as empty', () async {
      var fail = true;
      var clients = 0;
      final service = ShowEpisodeCatalog(
        clientFactory: () async {
          clients++;
          return MockClient((request) async {
            if (fail && !malformed) return json({'error': 'rate limited'}, 429);
            if (fail && request.url.path.endsWith('/episodes')) {
              return json([
                {'id': 1, 'season': 'four'},
              ]);
            }
            return catalog(request);
          });
        },
      );
      await expectLater(service.load(title: title, year: 2021), throwsA(isA<ShowEpisodeCatalogUnavailable>()));
      fail = false;
      expect(await service.load(title: title, year: 2021), isNotNull);
      expect(clients, 2);
    });
  }

  test('whole-load timeout closes a late client without sending requests and permits retry', () {
    fakeAsync((time) {
      final pending = Completer<http.Client>();
      final late = TrackedClient((_) async => throw StateError('must not request after expiry'));
      var first = true;
      Object? failure;
      ShowEpisodeCatalogResult? result;
      final service = ShowEpisodeCatalog(
        clientFactory: () async {
          if (first) {
            first = false;
            return pending.future;
          }
          return MockClient((request) async => catalog(request));
        },
      );
      service
          .load(title: title, year: 2021)
          .then(
            (_) {},
            onError: (Object error) {
              failure = error;
            },
          );
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 21));
      expect(failure, isA<ShowEpisodeCatalogUnavailable>());
      pending.complete(late);
      time.flushMicrotasks();
      expect(late.closed, isTrue);
      service.load(title: title, year: 2021).then((value) {
        result = value;
      });
      time.flushMicrotasks();
      expect(result?.tvmazeId, 43708);
    });
  });
}
