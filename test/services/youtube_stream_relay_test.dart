import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/youtube/youtube_service.dart';
import 'package:plezy/services/youtube/youtube_stream_relay.dart';

void main() {
  late HttpServer upstream;
  late YouTubeStreamRelay relay;
  late HttpClient client;
  late List<String> ranges;
  final bytes = List.generate(101, (i) => i);

  setUp(() async {
    ranges = [];
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      final range = request.headers.value('range')!;
      ranges.add(range);
      final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
      if (match == null) {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      final start = int.parse(match[1]!);
      final end = int.parse(match[2]!);
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes $start-$end/${bytes.length}');
      request.response.contentLength = end - start + 1;
      request.response.add(bytes.sublist(start, end + 1));
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${upstream.port}/stream?clen=${bytes.length}&mime=video%2Fmp4';
    relay = await YouTubeStreamRelay.open(YouTubePlayback(videoUrl: url, audioUrl: url), chunkBytes: 32);
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await relay.close();
    await upstream.close(force: true);
  });

  Future<(HttpClientResponse, List<int>)> fetch({String? range, bool audio = false, String method = 'GET'}) async {
    final request = await client.openUrl(method, Uri.parse(audio ? relay.playback.audioUrl! : relay.playback.videoUrl));
    if (range != null) request.headers.set('range', range);
    final response = await request.close();
    final data = await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    return (response, data);
  }

  test('open-ended player range becomes bounded upstream chunks without gaps', () async {
    final (response, data) = await fetch(range: 'bytes=0-');
    expect(response.statusCode, 206);
    expect(response.headers.value('content-range'), 'bytes 0-100/101');
    expect(data, bytes);
    expect(ranges, ['bytes=0-31', 'bytes=32-63', 'bytes=64-95', 'bytes=96-100']);
  });

  test('audio seeks return exactly the requested interval across chunks', () async {
    final (_, data) = await fetch(range: 'bytes=23-75', audio: true);
    expect(data, bytes.sublist(23, 76));
    expect(ranges, ['bytes=23-54', 'bytes=55-75']);
  });

  test('suffix range, no range, and HEAD retain standard HTTP semantics', () async {
    final (_, suffix) = await fetch(range: 'bytes=-9');
    expect(suffix, bytes.sublist(92));
    final (response, all) = await fetch();
    expect(response.statusCode, 200);
    expect(all, bytes);
    ranges.clear();
    final (head, body) = await fetch(method: 'HEAD');
    expect(head.contentLength, 101);
    expect(body, isEmpty);
    expect(ranges, isEmpty);
  });

  test('invalid, overflowing, and multipart ranges are rejected locally', () async {
    for (final range in [
      'bytes=101-',
      'bytes=40-20',
      'bytes=-0',
      'bytes=0-1,4-8',
      'bytes=-',
      'bytes=99999999999999999999999-',
    ]) {
      final (response, _) = await fetch(range: range);
      expect(response.statusCode, 416, reason: range);
    }
    expect(ranges, isEmpty);
  });

  test('arbitrary paths cannot select an upstream URL', () async {
    final uri = Uri.parse(relay.playback.videoUrl).replace(path: '/other', query: 'url=https://example.com');
    final request = await client.getUrl(uri);
    final response = await request.close();
    expect(response.statusCode, 404);
    await response.drain<void>();
    expect(ranges, isEmpty);
  });

  test('manifest sizes support combined streams without a clen query parameter', () async {
    final combined = await YouTubeStreamRelay.open(
      YouTubePlayback(videoUrl: 'http://127.0.0.1:${upstream.port}/combined', videoSize: bytes.length),
      chunkBytes: 32,
    );
    try {
      final request = await client.getUrl(Uri.parse(combined.playback.videoUrl));
      final response = await request.close();
      expect(await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk)), bytes);
    } finally {
      await combined.close();
    }
  });

  test('playability check rejects a track whose first bytes work but tail is forbidden', () async {
    final limited = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final service = YouTubeService();
    final requested = <String>[];
    limited.listen((request) async {
      final range = request.headers.value('range')!;
      requested.add(range);
      if (range.startsWith('bytes=0-')) {
        request.response.statusCode = 206;
        request.response.add([1, 2, 3]);
      } else {
        request.response.statusCode = 403;
      }
      await request.response.close();
    });
    try {
      expect(
        await service.canPlay(YouTubePlayback(videoUrl: 'http://127.0.0.1:${limited.port}/limited', videoSize: 10000)),
        isFalse,
      );
      expect(requested, ['bytes=0-1023', 'bytes=8976-9999']);
    } finally {
      service.close();
      await limited.close(force: true);
    }
  });
}
