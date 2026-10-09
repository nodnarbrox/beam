import 'dart:async';
import 'package:flutter/material.dart';
import '../focus/key_event_utils.dart';
import '../services/youtube/youtube_library.dart';
import '../services/youtube/youtube_service.dart';
import '../services/youtube/youtube_stream_relay.dart';
import '../utils/app_logger.dart';
import '../utils/video_player_navigation.dart';
import 'video_player_screen.dart';

class YouTubePlaybackScreen extends StatefulWidget {
  const YouTubePlaybackScreen({super.key, required this.video, this.library, this.youtubeFactory});
  final YouTubeVideo video;
  final YouTubeLibrary? library;
  final YouTubeService Function()? youtubeFactory;
  @override
  State<YouTubePlaybackScreen> createState() => YouTubePlaybackScreenState();
}

class YouTubePlaybackScreenState extends State<YouTubePlaybackScreen> {
  late final _service = widget.youtubeFactory?.call() ?? YouTubeService();
  YouTubeStreamRelay? _relay;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _service.close();
    unawaited(_relay?.close());
    super.dispose();
  }

  Future<void> _open() async {
    setState(() => _error = null);
    try {
      final resolved = await _service.resolve(widget.video.id);
      if (!mounted) return;
      final relay = await YouTubeStreamRelay.open(resolved);
      if (!mounted) {
        await relay.close();
        return;
      }
      _relay = relay;
      final stream = relay.playback;
      await Navigator.of(context).push(
        buildVideoPlayerRoute(
          builder: (_) => VideoPlayerScreen.direct(
            url: stream.videoUrl,
            audioUrl: stream.audioUrl,
            title: widget.video.title,
            onPlaybackStarted: () {
              final library = widget.library;
              if (library != null) {
                unawaited(
                  library.recordPlayed(widget.video).catchError((Object error, StackTrace stack) {
                    appLogger.w('YouTube history could not be saved', error: error, stackTrace: stack);
                  }),
                );
              }
            },
          ),
        ),
      );
      if (!mounted) return;
      if (mounted) Navigator.of(context).pop();
    } catch (error, stack) {
      if (mounted) appLogger.w('YouTube playback failed', error: error, stackTrace: stack);
      if (mounted) {
        setState(
          () => _error =
              'This video could not be played. It may be unavailable, restricted, or need an extractor update.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    skipTraversal: true,
    onKeyEvent: (_, event) => handleBackKeyNavigation(context, event),
    child: Scaffold(
      appBar: AppBar(title: Text(widget.video.title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error == null) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 20),
                const Text('Opening video…'),
              ] else ...[
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                FilledButton(onPressed: _open, child: const Text('Retry')),
              ],
              const SizedBox(height: 16),
              TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('Back')),
            ],
          ),
        ),
      ),
    ),
  );
}
