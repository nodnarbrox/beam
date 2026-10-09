import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../../utils/app_logger.dart';
import 'youtube_service.dart';

/// YouTube rejects open-ended ranges on some CDN routes. Present a seekable
/// local file to mpv, fetching bounded ranges with backpressure underneath.
/// The server and signed URLs live only for this playback route.
class YouTubeStreamRelay {
  YouTubeStreamRelay._(this._server, this.chunkBytes);
  final HttpServer _server;
  final int chunkBytes;
  final _tracks = <String, ({Uri uri, int size})>{};
  final _clients = <HttpClient>{};
  bool _closed = false;
  late final YouTubePlayback playback;

  static Future<YouTubeStreamRelay> open(YouTubePlayback source, {int chunkBytes = 1024 * 1024}) async {
    if (chunkBytes <= 0) throw ArgumentError.value(chunkBytes, 'chunkBytes');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = YouTubeStreamRelay._(server, chunkBytes);
    final random = Random.secure();
    final token = List.generate(24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    String route(String url, String name, int? knownSize) {
      final uri = Uri.parse(url);
      final size = knownSize ?? int.tryParse(uri.queryParameters['clen'] ?? '');
      // HLS has its own bounded segments and does not need this file relay.
      if (size == null || size <= 0) return url;
      final path = '/$token/$name';
      relay._tracks[path] = (uri: uri, size: size);
      return 'http://127.0.0.1:${server.port}$path';
    }

    relay.playback = YouTubePlayback(
      videoUrl: route(source.videoUrl, 'video.mp4', source.videoSize),
      audioUrl: source.audioUrl == null ? null : route(source.audioUrl!, 'audio.m4a', source.audioSize),
    );
    server.listen((request) => unawaited(relay._serve(request)));
    return relay;
  }

  Future<void> _serve(HttpRequest request) async {
    final track = _tracks[request.uri.path];
    final output = request.response;
    if (_closed || track == null || !const {'GET', 'HEAD'}.contains(request.method)) {
      output.statusCode = HttpStatus.notFound;
      await output.close();
      return;
    }
    final uri = track.uri;
    final size = track.size;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    var end = size - 1;
    if (range != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
      if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
        output.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      } else if (match[1]!.isEmpty) {
        final suffix = int.tryParse(match[2]!);
        if (suffix == null || suffix <= 0) {
          output.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        } else {
          start = max(0, size - suffix);
        }
      } else {
        start = int.tryParse(match[1]!) ?? size;
        end = match[2]!.isEmpty ? end : min(int.tryParse(match[2]!) ?? -1, end);
        if (start > end || start >= size) output.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      }
      if (output.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        output.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await output.close();
        return;
      }
      output.statusCode = HttpStatus.partialContent;
      output.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$size');
    }
    output.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    output.headers.set(HttpHeaders.contentTypeHeader, uri.queryParameters['mime'] ?? 'video/mp4');
    output.contentLength = end - start + 1;
    if (request.method == 'HEAD') {
      await output.close();
      return;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    _clients.add(client);
    var disconnected = false;
    unawaited(
      output.done.then<void>(
        (_) {},
        onError: (Object _) {
          disconnected = true;
          client.close(force: true);
        },
      ),
    );
    try {
      while (!_closed && !disconnected && start <= end) {
        final chunkEnd = min(end, start + chunkBytes - 1);
        final upstream = await client.getUrl(uri).timeout(const Duration(seconds: 15));
        upstream.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$chunkEnd');
        final response = await upstream.close().timeout(const Duration(seconds: 20));
        if (response.statusCode != HttpStatus.partialContent ||
            response.headers.value(HttpHeaders.contentRangeHeader) != 'bytes $start-$chunkEnd/$size') {
          throw HttpException('YouTube range request failed (HTTP ${response.statusCode})');
        }
        var received = 0;
        await output.addStream(
          response.timeout(const Duration(seconds: 20)).map((bytes) {
            received += bytes.length;
            if (received > chunkEnd - start + 1) throw const HttpException('YouTube returned an oversized range');
            return bytes;
          }),
        );
        if (received != chunkEnd - start + 1) {
          throw const HttpException('YouTube stream ended before its range completed');
        }
        start = chunkEnd + 1;
      }
      await output.close();
    } catch (error, stack) {
      if (!_closed && !disconnected) appLogger.w('YouTube stream interrupted', error: error, stackTrace: stack);
      // Abort a partial response: closing it normally would advertise a complete
      // file. mpv then reports playback failure through the regular error path.
      try {
        final socket = await output.detachSocket(writeHeaders: false);
        socket.destroy();
      } catch (_) {
        /* The player may already have disconnected. */
      }
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
    await _server.close(force: true);
  }
}
