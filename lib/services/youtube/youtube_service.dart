import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

class YouTubeVideo {
  const YouTubeVideo({
    required this.id,
    required this.title,
    required this.author,
    required this.channelId,
    this.durationSeconds,
  });

  final String id;
  final String title;
  final String author;
  final String channelId;
  final int? durationSeconds;
  String get thumbnail => 'https://i.ytimg.com/vi/$id/hqdefault.jpg';

  factory YouTubeVideo.fromVideo(yt.Video video) => YouTubeVideo(
    id: video.id.value,
    title: video.title,
    author: video.author,
    channelId: video.channelId.value,
    durationSeconds: video.duration?.inSeconds,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'channelId': channelId,
    'durationSeconds': durationSeconds,
  };

  factory YouTubeVideo.fromJson(Map<String, dynamic> json) => YouTubeVideo(
    id: json['id'] as String,
    title: json['title'] as String,
    author: json['author'] as String,
    channelId: json['channelId'] as String,
    durationSeconds: json['durationSeconds'] as int?,
  );
}

class YouTubeChannel {
  const YouTubeChannel({required this.id, required this.title, this.avatarUrl, this.description = ''});
  final String id;
  final String title;
  final String? avatarUrl;
  final String description;
  String get url => 'https://www.youtube.com/channel/$id';
}

class YouTubePlayback {
  const YouTubePlayback({required this.videoUrl, this.audioUrl, this.videoSize, this.audioSize});
  final String videoUrl;
  final String? audioUrl;
  final int? videoSize;
  final int? audioSize;
}

/// Each operation owns a client, including its deadline and disposal. A slow
/// YouTube response never blocks library search or leaves sockets behind.
class YouTubeService {
  final Set<yt.YoutubeExplode> _clients = {};
  final Set<HttpClient> _probes = {};
  bool _closed = false;

  Future<T> _request<T>(Future<T> Function(yt.YoutubeExplode client) operation, {int seconds = 25}) async {
    if (_closed) throw StateError('YouTube service has been closed');
    final client = yt.YoutubeExplode();
    _clients.add(client);
    try {
      return await operation(client).timeout(Duration(seconds: seconds));
    } finally {
      if (_clients.remove(client)) client.close();
    }
  }

  void close() {
    _closed = true;
    for (final client in _clients) {
      client.close();
    }
    _clients.clear();
    for (final probe in _probes) {
      probe.close(force: true);
    }
    _probes.clear();
  }

  Future<List<YouTubeVideo>> search(String query) => _request((client) async {
    final text = query.trim();
    if (text.isEmpty) return <YouTubeVideo>[];
    final uri = Uri.tryParse(text);
    final isYouTube =
        uri != null &&
        const {
          'youtube.com',
          'www.youtube.com',
          'm.youtube.com',
          'music.youtube.com',
          'youtu.be',
        }.contains(uri.host.toLowerCase());
    if (isYouTube) {
      final playlist = uri.queryParameters['list'];
      if (playlist != null && playlist.isNotEmpty) {
        return (await client.playlists.getVideos(playlist).take(40).toList()).map(YouTubeVideo.fromVideo).toList();
      }
      final parts = uri.pathSegments;
      if (parts.isNotEmpty && parts.first.startsWith('@')) {
        final channel = await client.channels.getByHandle(parts.first);
        return _channelUploads(client, channel.id);
      }
      if (parts.length >= 2 && parts.first == 'channel') {
        return _channelUploads(client, parts[1]);
      }
      final id = parts.length >= 2 && const {'shorts', 'live', 'embed'}.contains(parts.first)
          ? parts[1]
          : yt.VideoId.parseVideoId(text);
      if (id != null) return [YouTubeVideo.fromVideo(await client.videos.get(id))];
    }
    if (text.startsWith('@')) {
      final channel = await client.channels.getByHandle(text);
      return _channelUploads(client, channel.id);
    }
    return (await client.search.search(text)).map(YouTubeVideo.fromVideo).toList();
  });

  Future<List<YouTubeChannel>> searchChannels(String query) async {
    final text = query.trim();
    if (text.isEmpty || Uri.tryParse(text)?.hasScheme == true) return [];
    return _request((client) async {
      final results = await client.search.searchContent(text, filter: yt.TypeFilters.channel);
      return results
          .whereType<yt.SearchChannel>()
          .take(10)
          .map(
            (channel) => YouTubeChannel(
              id: channel.id.value,
              title: channel.name,
              description: channel.description,
              avatarUrl: channel.thumbnails.isEmpty ? null : channel.thumbnails.last.url.toString(),
            ),
          )
          .toList();
    });
  }

  Future<List<YouTubeVideo>> _channelUploads(yt.YoutubeExplode client, dynamic channelId) async {
    // YouTube can return an empty uploads playlist for an active channel.
    // Its Videos tab is an independent source, so use it when that happens.
    final uploads = await client.channels.getUploads(channelId).take(30).toList();
    if (uploads.isNotEmpty) return uploads.map(YouTubeVideo.fromVideo).toList();
    final page = await client.channels.getUploadsFromPage(channelId);
    return page.take(30).map(YouTubeVideo.fromVideo).toList();
  }

  Future<List<YouTubeVideo>> related(YouTubeVideo seed) => _request((client) async {
    final video = await client.videos.get(seed.id);
    final related = await client.videos.getRelatedVideos(video);
    return (related ?? <yt.Video>[]).take(20).map(YouTubeVideo.fromVideo).toList();
  });

  Future<YouTubePlayback> resolve(String id) => _request((client) async {
    final manifest = await client.videos.streams.getManifest(id);
    final preferred = selectPlayback(manifest);
    final muxed =
        manifest.muxed.where((v) => v.videoCodec.startsWith('avc1') && v.videoResolution.height <= 1080).toList()
          ..sort((a, b) => b.videoResolution.compareTo(a.videoResolution));
    final tried = <String>{};
    for (final candidate in [
      preferred,
      ...muxed.map((v) => YouTubePlayback(videoUrl: v.url.toString(), videoSize: v.size.totalBytes)),
    ]) {
      if (!tried.add(candidate.videoUrl)) continue;
      if (await canPlay(candidate)) {
        return candidate;
      }
    }
    throw StateError('YouTube did not provide a stream that can be played through.');
  }, seconds: 50);

  Future<bool> canPlay(YouTubePlayback playback) async =>
      await _canRead(playback.videoUrl, playback.videoSize) &&
      (playback.audioUrl == null || await _canRead(playback.audioUrl!, playback.audioSize));

  // Some clients return URLs that only permit the first minute. Test both ends
  // before opening the player; fall back to a combined track when needed.
  Future<bool> _canRead(String url, int? size) async {
    if (_closed) throw StateError('YouTube service has been closed');
    if (size == null || size <= 0) return true; // segmented HLS
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    _probes.add(http);
    try {
      for (final start in {0, max(0, size - 1024)}) {
        final request = await http.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 8));
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${min(size - 1, start + 1023)}');
        final response = await request.close().timeout(const Duration(seconds: 8));
        if (response.statusCode != 206) return false;
        final data = await response.first.timeout(const Duration(seconds: 8));
        if (data.isEmpty) return false;
      }
      return true;
    } catch (_) {
      if (_closed) throw StateError('YouTube service has been closed');
      return false;
    } finally {
      _probes.remove(http);
      http.close(force: true);
    }
  }

  /// H.264/AAC at up to 1080p keeps the ONN's hardware decoding path usable.
  /// Separate tracks are opened together by Plezy's existing mpv player.
  static YouTubePlayback selectPlayback(yt.StreamManifest manifest) {
    final videos =
        manifest.videoOnly
            .where(
              (v) =>
                  v.videoCodec.startsWith('avc1') &&
                  v.videoResolution.height <= 1080 &&
                  v.framerate.framesPerSecond <= 60,
            )
            .toList()
          ..sort((a, b) => b.videoResolution.compareTo(a.videoResolution));
    final audio =
        manifest.audioOnly
            .where((a) => a.audioCodec.startsWith('mp4a') && (a.audioTrack == null || a.audioTrack!.audioIsDefault))
            .toList()
          ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    if (videos.isNotEmpty && audio.isNotEmpty) {
      return YouTubePlayback(
        videoUrl: videos.first.url.toString(),
        audioUrl: audio.first.url.toString(),
        videoSize: videos.first.size.totalBytes,
        audioSize: audio.first.size.totalBytes,
      );
    }
    final muxed =
        manifest.muxed.where((v) => v.videoCodec.startsWith('avc1') && v.videoResolution.height <= 1080).toList()
          ..sort((a, b) => b.videoResolution.compareTo(a.videoResolution));
    if (muxed.isNotEmpty) {
      return YouTubePlayback(videoUrl: muxed.first.url.toString(), videoSize: muxed.first.size.totalBytes);
    }
    if (manifest.hls.isNotEmpty) return YouTubePlayback(videoUrl: manifest.hls.first.url.toString());
    throw StateError('No compatible YouTube stream is available for this video.');
  }
}
