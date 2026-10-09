import 'package:plezy/services/beam/rd_request_coordinator.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/episode_file_selector.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/services/beam/realdebrid_client.dart';
import 'package:plezy/services/beam/torrent_stream_service.dart';

const story = EpisodeStoryConstraint(title: 'To Catch a Cat', companionTitles: {15: 'Mixing Up Trouble'});
const paired = 'Spidey.and.His.Amazing.Friends.S04E15-E16.Mixing.Up.Trouble.To.Catch.a.Cat.1080p.WEB.h264.mkv';
const single = 'Spidey.and.His.Amazing.Friends.S04E16.To.Catch.a.Cat.1080p.mkv';
const untitled = 'Spidey.and.His.Amazing.Friends.S04E16.1080p.WEB.h264-DOLORES.mkv';
EpisodeFile file(int id, String path) => EpisodeFile(id: id, path: path, size: 100);
http.Response json(Object body, [int code = 200]) => http.Response(jsonEncode(body), code);

void main() {
  for (final path in [paired, single, 'Spidey.S04E15E16.Mixing.Up.Trouble.and.To.Catch.a.Cat.mp4']) {
    test('catalog story is corroborated by complete filename title: $path', () {
      expect(EpisodeFileSelector.select([file(1, path)], season: 4, episode: 16, storyConstraint: story).id, 1);
    });
  }
  for (final path in [
    untitled,
    'Spidey.S04E16.Another.Story.mkv',
    'Spidey.S04E15-E16.1080p.mkv',
    'Spidey.S04E16.Home.Alone.mkv',
  ]) {
    test('catalog virtual rejects missing or conflicting actual story: $path', () {
      expect(
        () => EpisodeFileSelector.select([file(1, path)], season: 4, episode: 16, storyConstraint: story),
        throwsA(isA<EpisodeSelectionException>()),
      );
    });
  }
  test('no substring title match and no empty catalog-title bypass', () {
    expect(
      EpisodeFileSelector.matches(
        'Show.S01E01.Home.Alone.mkv',
        1,
        1,
        storyConstraint: const EpisodeStoryConstraint(title: 'Home'),
      ),
      isFalse,
    );
    expect(
      EpisodeFileSelector.matches(single, 4, 16, storyConstraint: const EpisodeStoryConstraint(title: '')),
      isFalse,
    );
    expect(EpisodeFileSelector.matches(single, 4, 15, storyConstraint: story), isFalse);
    expect(EpisodeFileSelector.matches(untitled, 4, 16), isTrue);
  });
  test('actual Spidey broadcast E09 cannot impersonate catalog Campout Chaos E09', () {
    expect(
      EpisodeFileSelector.matches(
        'Spidey.S04E09.How.to.Catch.a.Caterpillar.A.Jellyfish.Tale.1080p.mkv',
        4,
        9,
        storyConstraint: const EpisodeStoryConstraint(title: 'Campout Chaos'),
      ),
      isFalse,
    );
  });
  test('known companion titles are needed to corroborate a concatenated paired title', () {
    expect(
      EpisodeFileSelector.matches(
        paired,
        4,
        16,
        storyConstraint: const EpisodeStoryConstraint(title: 'To Catch a Cat'),
      ),
      isFalse,
    );
    expect(
      EpisodeFileSelector.matches(
        paired,
        4,
        16,
        storyConstraint: const EpisodeStoryConstraint(title: 'To Catch a Cat', companionTitles: {15: 'Unrelated'}),
      ),
      isFalse,
    );
  });
  test('native pack adapter chooses titled copy and rejects generic-only copy before stream', () {
    FileInfo native(int id, String name) => FileInfo(index: id, name: name, path: name, size: 100, isStreamable: true);
    expect(
      TorrentStreamService.selectFileIndex(
        [native(1, untitled), native(2, paired)],
        season: 4,
        episode: 16,
        storyConstraint: story,
      ),
      2,
    );
    expect(
      () => TorrentStreamService.selectFileIndex([native(1, untitled)], season: 4, episode: 16, storyConstraint: story),
      throwsA(isA<EpisodeSelectionException>()),
    );
  });
  test('RD rejects generic actual file before selecting and deletes only its newly created job', () async {
    final calls = <String>[];
    final client = RealDebridClient(
      coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
      tokenProvider: () async => 'fixture',
      httpClient: MockClient((request) async {
        calls.add(request.url.path);
        if (request.url.path.endsWith('/addMagnet')) return json({'id': 'job'}, 201);
        if (request.url.path.endsWith('/delete/job')) {
          expect(request.method, 'DELETE');
          return http.Response('', 204);
        }
        if (request.url.path.endsWith('/info/job')) {
          return json({
            'status': 'waiting_files_selection',
            'files': [
              {'id': 1, 'path': untitled, 'bytes': 100, 'selected': 0},
            ],
          });
        }
        fail('Wrong story must be rejected before ${request.url}');
      }),
    );
    await expectLater(
      client.resolveMagnet('magnet:fixture', season: 4, episode: 16, storyConstraint: story),
      throwsA(isA<EpisodeSelectionException>()),
    );
    expect(calls, hasLength(3));
    expect(calls.last, endsWith('/delete/job'));
  });
  for (final status in ['downloaded', 'downloading']) {
    test('existing $status job with wrong story is preserved without adding a duplicate', () async {
      final calls = <String>[];
      final client = RealDebridClient(
        coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
        tokenProvider: () async => 'fixture',
        httpClient: MockClient((request) async {
          calls.add(request.url.path);
          if (request.url.path.endsWith('/torrents')) {
            return json([
              {'id': 'existing', 'hash': 'hash', 'status': status},
            ]);
          }
          if (request.url.path.endsWith('/info/existing')) {
            return json({
              'status': status,
              'files': [
                {'id': 1, 'path': untitled, 'bytes': 100, 'selected': 1},
              ],
              'links': ['wrong-story'],
            });
          }
          fail('Must preserve existing job without re-adding, selecting or unrestricting: ${request.url}');
        }),
      );
      await expectLater(
        client.resolveMagnetSmart('magnet:fixture', infoHash: 'hash', season: 4, episode: 16, storyConstraint: story),
        throwsA(isA<EpisodeSelectionException>()),
      );
      expect(calls, hasLength(2));
    });
  }
  test('existing cache with a valid unselected story permits fresh correct selection and preserves old job', () async {
    final selected = <String>[];
    var newPolls = 0;
    final client = RealDebridClient(
      coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
      tokenProvider: () async => 'fixture',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/torrents')) {
          return json([
            {'id': 'old', 'hash': 'hash', 'status': 'downloaded'},
          ]);
        }
        if (request.url.path.endsWith('/info/old')) {
          return json({
            'status': 'downloaded',
            'files': [
              {'id': 1, 'path': untitled, 'bytes': 100, 'selected': 1},
              {'id': 2, 'path': paired, 'bytes': 100, 'selected': 0},
            ],
            'links': ['old-link'],
          });
        }
        if (request.url.path.endsWith('/addMagnet')) return json({'id': 'new'}, 201);
        if (request.url.path.endsWith('/info/new')) {
          return json({
            'status': newPolls++ == 0 ? 'waiting_files_selection' : 'downloaded',
            'files': [
              {'id': 1, 'path': untitled, 'bytes': 100, 'selected': 0},
              {'id': 2, 'path': paired, 'bytes': 100, 'selected': 1},
            ],
            'links': ['right-link'],
          });
        }
        if (request.url.path.endsWith('/selectFiles/new')) {
          selected.add(request.bodyFields['files']!);
          return http.Response('', 204);
        }
        if (request.url.path.endsWith('/unrestrict/link')) {
          expect(request.bodyFields['link'], 'right-link');
          return json({'filename': paired, 'download': 'https://fixture/right'});
        }
        fail('No deletion or unrelated mutation allowed: ${request.url}');
      }),
    );
    final result = await client.resolveMagnetSmart(
      'magnet:fixture',
      infoHash: 'hash',
      season: 4,
      episode: 16,
      storyConstraint: story,
      pollEvery: Duration.zero,
    );
    expect(result.primaryVideo!.filename, paired);
    expect(selected, ['2']);
  });
  for (final returned in [paired, untitled]) {
    test('RD correct cached paired actual file still validates unrestrict filename: $returned', () async {
      final client = RealDebridClient(
        coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
        tokenProvider: () async => 'fixture',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/addMagnet')) return json({'id': 'job'}, 201);
          if (request.url.path.endsWith('/info/job')) {
            return json({
              'status': 'downloaded',
              'files': [
                {'id': 1, 'path': paired, 'bytes': 100, 'selected': 1},
                {'id': 2, 'path': untitled, 'bytes': 100, 'selected': 0},
              ],
              'links': ['paired-link'],
            });
          }
          if (request.url.path.endsWith('/unrestrict/link')) {
            expect(request.bodyFields['link'], 'paired-link');
            return json({'filename': returned, 'download': 'https://fixture/paired'});
          }
          fail('Unexpected request ${request.url}');
        }),
      );
      final future = client.resolveMagnet('magnet:fixture', season: 4, episode: 16, storyConstraint: story);
      if (returned == paired) {
        expect((await future).primaryVideo!.filename, paired);
      } else {
        await expectLater(future, throwsA(isA<RdException>()));
      }
    });
  }
  test('fast wrong-story leg cannot win; other matching leg remains eligible until first frame', () async {
    late BeamCancellation rdCancel;
    late BeamCancellation torrentCancel;
    final nativeReady = Completer<BeamPlayResult>();
    final source = ProwlarrResult.fromJson({'title': 'Spidey S04', 'guid': 'magnet:?xt=urn:btih:fixture'});
    final service = BeamPlayService(
      realDebrid: (source, season, episode, cancellation) async {
        rdCancel = cancellation;
        return BeamPlayResult(
          url: 'https://fixture/wrong',
          winner: BeamPlayWinner.realDebrid,
          magnet: source.magnetUrl!,
          selectedFilename: untitled,
        );
      },
      torrent: (source, season, episode, cancellation) {
        torrentCancel = cancellation;
        return nativeReady.future;
      },
    );
    final pending = service.race(
      source,
      rdEnabled: true,
      torrentEnabled: true,
      season: 4,
      episode: 16,
      storyConstraint: story,
      deferLoserCancellation: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(rdCancel.isCancelled, isTrue);
    expect(torrentCancel.isCancelled, isFalse);
    nativeReady.complete(
      BeamPlayResult(
        url: 'http://fixture/right',
        winner: BeamPlayWinner.torrent,
        magnet: source.magnetUrl!,
        selectedFilename: paired,
      ),
    );
    final result = await pending;
    expect(result.winner, BeamPlayWinner.torrent);
    expect(result.selectedFilename, paired);
    result.commitPlayback();
    expect(torrentCancel.isCancelled, isFalse);
    result.cancel();
    expect(torrentCancel.isCancelled, isTrue);
  });
}
