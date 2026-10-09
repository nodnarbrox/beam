import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/beam/episode_file_selector.dart';
import 'package:plezy/services/beam/show_catalog_merge.dart';
import 'package:plezy/services/beam/show_episode_catalog.dart';

Map<String, dynamic> fixture(String name) =>
    (jsonDecode(File('test/fixtures/beam/broadcast_numbering.json').readAsStringSync()) as Map)[name]
        as Map<String, dynamic>;
ShowEpisodeCatalogResult catalog(Map<String, dynamic> data) => ShowEpisodeCatalogResult(
  tvmazeId: data['showId'] as int,
  name: data['showId'] == 79408 ? "The 'Burbs" : 'Spidey and His Amazing Friends',
  sourceUrl: 'https://www.tvmaze.com/shows/${data['showId']}',
  seasons: [
    for (final number in (data['episodes'] as List).map((e) => e['season'] as int).toSet())
      ShowCatalogSeason(number: number),
  ],
  episodes: [
    for (final e in data['episodes'] as List)
      ShowCatalogEpisode(
        id: e['id'] as int,
        seasonNumber: e['season'] as int,
        episodeNumber: e['number'] as int?,
        name: e['name'] as String,
        type: e['type'] as String?,
        sourceUrl: 'https://www.tvmaze.com/episodes/${e['id']}',
      ),
  ],
);
ShowEpisodeCatalog service(Map<String, dynamic> data, List<String> calls) => ShowEpisodeCatalog(
  clientFactory: () async => MockClient((request) async {
    calls.add(request.url.path);
    if (request.url.path == '/shows/${data['showId']}/alternatelists') {
      return http.Response(
        jsonEncode(data['lists']),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    final id = RegExp(r'/alternatelists/(\d+)/alternateepisodes').firstMatch(request.url.path)?.group(1);
    if (id != null) {
      expectSync(request.url.queryParameters['embed'], 'episodes');
      return http.Response(
        jsonEncode((data['alternates'] as Map)[id]),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    throw StateError('Unexpected request');
  }),
);
MediaItem episode(ShowEpisodeCatalogResult result, int season, int number) => mergeShowCatalog(
  show: MediaItem(id: 'show', backend: MediaBackend.plex, kind: MediaKind.show, title: result.name),
  catalog: result,
).episodes.singleWhere((e) => e.parentIndex == season && e.index == number);

void main() {
  test('actual Burbs broadcast premiere maps every catalog episode ID and unlocks exact generic E2', () async {
    final data = fixture('burbs');
    final calls = <String>[];
    final api = service(data, calls);
    final original = catalog(data);
    final result = await api.verifyNumbering(original);
    expect(result.numberingChecked, isTrue);
    expect(result.numberingEvidence, hasLength(8));
    final item = episode(result, 1, 2);
    final identity = BeamEpisodeIdentity.fromMetadata(item)!;
    expect(item.title, 'Mind Your Own Business');
    expect(item.raw?['tvmazeEpisodeId'], 3461027);
    expect(item.raw?['beamNumberingEvidence'], containsPair('alternateListId', 5340));
    expect(identity.storyConstraint, isNull);
    expect(
      EpisodeFileSelector.select(
        [const EpisodeFile(id: 0, path: 'The.Burbs.S01E02.1080p.WEB.h264-ETHEL.mkv', size: 99)],
        season: 1,
        episode: 2,
        storyConstraint: identity.storyConstraint,
      ).id,
      0,
    );
    expect(
      () => EpisodeFileSelector.select(
        [const EpisodeFile(id: 0, path: 'The.Burbs.S01E03.1080p.mkv', size: 99)],
        season: 1,
        episode: 2,
      ),
      throwsA(isA<EpisodeSelectionException>()),
    );
    await api.verifyNumbering(original);
    expect(calls, hasLength(2));
    expect(result.withAliases(['Alias']).numberingEvidence, hasLength(8));
    for (final changed in [
      item.copyWith(index: 3),
      item.copyWith(parentIndex: 2),
      item.copyWith(title: 'Other story'),
      item.copyWith(raw: {...?item.raw, 'tvmazeEpisodeId': 7}),
      item.copyWith(raw: {...?item.raw, 'tvmazeShowId': 7}),
    ]) {
      expect(BeamEpisodeIdentity.fromMetadata(changed)!.storyConstraint, isNotNull);
    }
  });
  test('actual partial Spidey broadcast lists do not verify season4 or disable story safety', () async {
    final data = fixture('spidey');
    final result = await service(data, []).verifyNumbering(catalog(data));
    expect(result.numberingChecked, isTrue);
    expect(result.numberingEvidence, isEmpty);
    final identity = BeamEpisodeIdentity.fromMetadata(episode(result, 4, 16))!;
    expect(identity.storyConstraint, isNotNull);
    expect(
      EpisodeFileSelector.matches('Spidey.S04E16.1080p.mkv', 4, 16, storyConstraint: identity.storyConstraint),
      isFalse,
    );
  });
  for (final mutation in [
    'partial',
    'moved',
    'combined',
    'duplicate',
    'wrong show',
    'wrong title',
    'DVD',
    'custom',
    'unknown type',
    'conflict',
    'too many',
    'unclassifiable second list',
  ]) {
    test('$mutation cannot establish full season numbering', () async {
      final data = fixture('burbs');
      final rows = (data['alternates'] as Map)['5340'] as List;
      final list = (data['lists'] as List).single as Map;
      switch (mutation) {
        case 'partial':
          rows.removeLast();
        case 'moved':
          rows[1]['number'] = 3;
        case 'combined':
          (rows[1]['_embedded']['episodes'] as List).add(rows[0]['_embedded']['episodes'][0]);
        case 'duplicate':
          rows[1] = rows[0];
        case 'wrong show':
          rows[1]['_embedded']['episodes'][0]['_links']['show']['href'] = 'https://api.tvmaze.com/shows/43708';
        case 'wrong title':
          rows[1]['_embedded']['episodes'][0]['name'] = 'Different story';
        case 'DVD':
          list['dvd_release'] = true;
        case 'custom':
          list['verbatim_order'] = true;
        case 'unknown type':
          list.remove('broadcast_premiere');
        case 'conflict':
          (data['lists'] as List).add({...list, 'id': 999});
          final copy = jsonDecode(jsonEncode(rows)) as List;
          copy[1]['number'] = 3;
          (data['alternates'] as Map)['999'] = copy;
        case 'too many':
          (data['lists'] as List).addAll([
            for (final id in [9, 10, 11]) {...list, 'id': id},
          ]);
        case 'unclassifiable second list':
          (data['lists'] as List).add({...list, 'id': 999});
          (data['alternates'] as Map)['999'] = [{}];
      }
      final calls = <String>[];
      final result = await service(data, calls).verifyNumbering(catalog(data));
      expect(result.numberingEvidence, isEmpty);
      expect(result.numberingChecked, !['wrong show', 'unclassifiable second list'].contains(mutation));
      expect(
        calls,
        hasLength(
          ['DVD', 'custom', 'unknown type', 'too many'].contains(mutation)
              ? 1
              : ['conflict', 'unclassifiable second list'].contains(mutation)
              ? 3
              : 2,
        ),
      );
      expect(BeamEpisodeIdentity.fromMetadata(episode(result, 1, 2))!.storyConstraint, isNotNull);
    });
  }
  test('invalid raw proof identifiers or blank canonical title cannot waive the story guard', () async {
    final data = fixture('burbs');
    final result = await service(data, []).verifyNumbering(catalog(data));
    expect(result.numberingChecked, isTrue);
    final original = episode(result, 1, 2);
    for (final field in ['showId', 'episodeId', 'alternateListId', 'title']) {
      final raw = {...original.raw!};
      final proof = Map<String, Object?>.from(raw['beamNumberingEvidence'] as Map);
      proof[field] = field == 'title' ? '' : 0;
      if (field == 'showId') raw['tvmazeShowId'] = 0;
      if (field == 'episodeId') raw['tvmazeEpisodeId'] = 0;
      if (field == 'alternateListId') proof['source'] = 'https://api.tvmaze.com/alternatelists/0/alternateepisodes';
      raw['beamNumberingEvidence'] = proof;
      final changed = original.copyWith(raw: raw, title: field == 'title' ? '' : original.title);
      expect(BeamEpisodeIdentity.fromMetadata(changed)!.storyConstraint, isNotNull);
    }
  });
  test('transient failure stays retryable; a changed catalog snapshot cannot reuse old proof', () async {
    final data = fixture('burbs');
    var failing = true;
    final calls = <String>[];
    final delegate = service(data, calls);
    final api = ShowEpisodeCatalog(
      clientFactory: () async => MockClient((request) async {
        if (failing) return http.Response('unavailable', 503);
        if (request.url.path.endsWith('/alternatelists')) {
          return http.Response(
            jsonEncode(data['lists']),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(
          jsonEncode((data['alternates'] as Map)['5340']),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final original = catalog(data);
    final failed = await api.verifyNumbering(original);
    expect(failed, same(original));
    expect(failed.numberingChecked, isFalse);
    failing = false;
    expect((await api.verifyNumbering(failed)).numberingEvidence, hasLength(8));
    await delegate.verifyNumbering(original);
    (data['episodes'] as List)[1]['id'] = 9999;
    expect((await delegate.verifyNumbering(catalog(data))).numberingEvidence, isEmpty);
    expect(calls, hasLength(4));
  });
  test('deadline closes a late-created client without issuing requests', () {
    fakeAsync((async) {
      final gate = Completer<http.Client>();
      var requested = false;
      var closed = false;
      final client = _ClosingClient((_) async {
        requested = true;
        return http.Response('[]', 200);
      }, () => closed = true);
      final api = ShowEpisodeCatalog(clientFactory: () => gate.future);
      final original = catalog(fixture('burbs'));
      ShowEpisodeCatalogResult? result;
      api.verifyNumbering(original).then((value) => result = value);
      async.elapse(const Duration(seconds: 4));
      expect(result, same(original));
      gate.complete(client);
      async.flushMicrotasks();
      expect(closed, isTrue);
      expect(requested, isFalse);
    });
  });
}

class _ClosingClient extends MockClient {
  _ClosingClient(super.fn, this.closed);
  final void Function() closed;
  @override
  void close() {
    closed();
    super.close();
  }
}
