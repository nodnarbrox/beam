import 'package:plezy/services/beam/rd_request_coordinator.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:plezy/services/beam/episode_file_selector.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/services/beam/realdebrid_client.dart';
import 'package:plezy/services/beam/release_identity.dart';
import 'package:plezy/services/beam/torrent_stream_service.dart';

const show = 'Spidey and His Amazing Friends';
const paired = 'Spidey.and.His.Amazing.Friends.S04E15-E16.Mixing.Up.Trouble.To.Catch.a.Cat.mkv';
ProwlarrResult source(String title) => ProwlarrResult.fromJson({'title': title, 'seeders': 4});
EpisodeFile file(int id, String path) => EpisodeFile(id: id, path: path, size: 100);

void main() {
  for (final marker in ['S04E15-E16', 'S04E15E16', 'S04E15-16', '4x15x16', '4x15-16']) {
    test('explicit pair $marker matches both stories without inferring other numbers', () {
      final path = '$show.$marker.1080p.mkv';
      expect(EpisodeFileSelector.episodesFor(path, season: 4), [15, 16]);
      for (final episode in [15, 16]) {
        expect(EpisodeFileSelector.select([file(1, path)], season: 4, episode: episode).id, 1);
        expect(ReleaseIdentity.matchesEpisodeSource(source(path), show: show, season: 4, episode: episode), isTrue);
      }
      for (final episode in [7, 8, 14, 17, 30, 31, 32]) {
        expect(EpisodeFileSelector.matches(path, 4, episode), isFalse);
        expect(ReleaseIdentity.matchesEpisodeSource(source(path), show: show, season: 4, episode: episode), isFalse);
      }
      expect(EpisodeFileSelector.matches(path, 5, 15), isFalse);
    });
  }

  test('explicit list has no guessed gap; a bounded range includes interior episodes', () {
    expect(EpisodeFileSelector.episodesFor('$show.S05E07E09E10.mkv', season: 5), [7, 9, 10]);
    expect(EpisodeFileSelector.matches('$show.S05E07E09E10.mkv', 5, 8), isFalse);
    expect(EpisodeFileSelector.episodesFor('$show.S05E07-E10.mkv', season: 5), [7, 8, 9, 10]);
    expect(EpisodeFileSelector.episodesFor('$show.S05E07E08.mkv', season: 5), [7, 8]);
  });

  for (final marker in [
    'S04E15-E14',
    'S04E15E15',
    'S04E15-E999',
    'S04E15-E16-E999',
    'S04E15E16E17E18E19E20E21E22E23',
    'S04E15-S05E16',
    'S04E15-S04E16',
    'S04E15x16',
    '4x15E16',
    'S04E15+E16',
    'S04E15&E16',
    'S04E15 and E16',
    'S04E15 to E16',
    'S04E15 16',
    'S04E15-E16bad',
    'S04E150',
    'S04E07',
    '15-16',
  ]) {
    test('rejects malformed, ambiguous, guessed or wrong episode marker $marker', () {
      final path = '$show.$marker.1080p.mkv';
      expect(EpisodeFileSelector.matches(path, 4, 15), isFalse);
      expect(ReleaseIdentity.matchesEpisodeSource(source(path), show: show, season: 4, episode: 15), isFalse);
    });
  }

  test('paired source still needs exact show and unique actual playable file', () {
    expect(
      ReleaseIdentity.matchesEpisodeSource(source('Other.Show.S04E15-E16'), show: show, season: 4, episode: 15),
      isFalse,
    );
    expect(ReleaseIdentity.matchesEpisodeSource(source('Other.$paired'), show: show, season: 4, episode: 15), isFalse);
    for (final files in [
      [file(1, paired), file(2, '$show.S04E16.mp4')],
      [file(1, 'Samples/$paired')],
      [file(1, '$show.S04E15-E16/15-16.mp4')],
    ]) {
      expect(
        () => EpisodeFileSelector.select(files, season: 4, episode: 16),
        throwsA(isA<EpisodeSelectionException>()),
      );
    }
  });

  test('native adapter selects the explicit paired file for its second story', () {
    final files = [
      FileInfo(index: 1, name: paired, path: paired, size: 100, isStreamable: true),
      FileInfo(index: 2, name: '$show.S04E17.mkv', path: '$show.S04E17.mkv', size: 1000, isStreamable: true),
    ];
    expect(TorrentStreamService.selectFileIndex(files, season: 4, episode: 16), 1);
    expect(
      () => TorrentStreamService.selectFileIndex(files, season: 5, episode: 16),
      throwsA(isA<EpisodeSelectionException>()),
    );
  });

  for (final returnedName in [paired, '$show.S04E17.mkv']) {
    test('RD validates actual paired selection and returned file: $returnedName', () async {
      final selected = <String>[];
      final unlocked = <String>[];
      var polls = 0;
      final client = RealDebridClient(
        coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
        tokenProvider: () async => 'fixture-token',
        httpClient: MockClient((request) async {
          Object body;
          if (request.url.path.endsWith('/addMagnet')) {
            return http.Response(jsonEncode({'id': 'paired'}), 201);
          } else if (request.url.path.endsWith('/info/paired')) {
            body = {
              'status': polls++ == 0 ? 'waiting_files_selection' : 'downloaded',
              'files': [
                {'id': 4, 'path': paired, 'bytes': 100, 'selected': 1},
                {'id': 5, 'path': '$show.S04E17.mkv', 'bytes': 1000, 'selected': 0},
              ],
              'links': ['paired-link'],
            };
          } else if (request.url.path.endsWith('/selectFiles/paired')) {
            selected.add(request.bodyFields['files']!);
            return http.Response('', 204);
          } else if (request.url.path.endsWith('/unrestrict/link')) {
            unlocked.add(request.bodyFields['link']!);
            body = {'filename': returnedName, 'download': 'https://fixture/paired', 'filesize': 100};
          } else {
            throw StateError('Unexpected request ${request.url}');
          }
          return http.Response(jsonEncode(body), 200);
        }),
      );
      final future = client.resolveMagnet('magnet:fixture', season: 4, episode: 16, pollEvery: Duration.zero);
      if (returnedName == paired) {
        expect((await future).primaryVideo!.downloadUrl, 'https://fixture/paired');
      } else {
        await expectLater(future, throwsA(anyOf(isA<EpisodeSelectionException>(), isA<RdException>())));
      }
      expect(selected, ['4']);
      expect(unlocked, ['paired-link']);
    });
  }
}
