import 'package:plezy/services/beam/rd_request_coordinator.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:plezy/services/beam/realdebrid_client.dart';
import 'package:plezy/services/beam/torrent_stream_service.dart';

// Opt-in external-media probe. The default suite needs neither media downloads
// nor ffmpeg. This is service-to-decoder evidence, not a real RD/swarm/device test.
void main() {
  final fixtureDir = Platform.environment['PLEZY_TV_MEDIA_DIR'];
  test(
    'Pioneer One E02 resolves, streams and seeks through both file adapters',
    () async {
      final files = [
        for (final episode in [1, 2]) File('$fixtureDir/Pioneer.One.S01E0$episode.test-excerpt.mp4'),
      ];
      expect(await files.first.length(), greaterThan(await files.last.length()));
      final bytes = [for (final file in files) await file.readAsBytes()];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        final index = request.uri.path == '/e02.mp4' ? 1 : 0;
        final data = bytes[index];
        var start = 0;
        var end = data.length - 1;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
          if (match == null || int.parse(match[1]!) >= data.length) {
            request.response.statusCode = 416;
            await request.response.close();
            return;
          }
          start = int.parse(match[1]!);
          if (match[2]!.isNotEmpty) end = int.parse(match[2]!).clamp(start, end);
          request.response.statusCode = 206;
          request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${data.length}');
        }
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.contentLength = end - start + 1;
        if (request.method != 'HEAD') request.response.add(data.sublist(start, end + 1));
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final native = [
        for (var i = 0; i < files.length; i++)
          FileInfo(
            index: i,
            name: files[i].uri.pathSegments.last,
            path: files[i].path,
            size: bytes[i].length,
            isStreamable: true,
          ),
      ];
      final selected = TorrentStreamService.selectFileIndex(native, season: 1, episode: 2);
      expect(selected, 1);
      final client = RealDebridClient(
        coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
        tokenProvider: () async => 'fixture-token',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/addMagnet')) return http.Response('{"id":"pack"}', 201);
          if (request.url.path.endsWith('/info/pack')) {
            return http.Response(
              jsonEncode({
                'status': 'downloaded',
                'files': [
                  for (var i = 0; i < files.length; i++)
                    {'id': i + 1, 'path': native[i].name, 'bytes': bytes[i].length, 'selected': 1},
                ],
                'links': ['rd-e01', 'rd-e02'],
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/unrestrict/link')) {
            expect(request.bodyFields['link'], 'rd-e02');
            return http.Response(
              jsonEncode({'filename': native[1].name, 'download': '$base/e02.mp4', 'filesize': bytes[1].length}),
              200,
            );
          }
          throw StateError('Unexpected provider request ${request.url.path}');
        }),
      );
      final resolved = await client.resolveMagnet('magnet:?xt=urn:btih:fixture', season: 1, episode: 2);
      for (final url in ['$base/e0${selected + 1}.mp4', resolved.primaryVideo!.downloadUrl]) {
        final decoded = await Process.run('ffmpeg', [
          '-hide_banner',
          '-nostdin',
          '-ss',
          '2',
          '-i',
          url,
          '-t',
          '3',
          '-f',
          'null',
          '-',
        ]).timeout(const Duration(seconds: 30));
        expect(decoded.exitCode, 0, reason: decoded.stderr.toString());
        expect(decoded.stderr.toString(), contains('frame='));
        // ignore: avoid_print
        print(
          'Decoded selected E02 after 2s seek: ${decoded.stderr.toString().split('\n').where((line) => line.contains('frame=')).join(' ').trim()}',
        );
      }
      expect(requests, isNotEmpty);
      expect(requests.toSet(), {'/e02.mp4'});
    },
    skip: fixtureDir == null ? 'Set PLEZY_TV_MEDIA_DIR and install ffmpeg for actual-media probe.' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
