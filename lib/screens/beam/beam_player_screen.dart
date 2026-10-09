import 'dart:async';

import 'package:flutter/material.dart';

import 'package:plezy/utils/app_logger.dart';

import '../../mpv/mpv.dart';

/// Self-contained fullscreen player for a plain network/localhost URL, used by
/// the Beam search->resolve->play flow.
///
/// Reuses the app's real mpv/ExoPlayer stack: [Player] (from lib/mpv) opened on
/// a [Media] and rendered through the [Video] widget. No Plex plumbing — this is
/// a raw-URL player so a Real-Debrid direct link or a torrent-stream localhost
/// URL can be handed straight in.
///
/// PLAYBACK IS REAL here (not a hook): the mpv widget/controller API is
/// confirmed from lib/mpv/mpv.dart + lib/mpv/video.dart — `Player()`,
/// `player.open(Media(url))`, `player.play()`, `Video(player: player)`,
/// `player.dispose()`.
class BeamPlayerScreen extends StatefulWidget {
  const BeamPlayerScreen({
    super.key,
    required this.url,
    this.title,
    this.headers,
  });

  /// A directly-playable URL: RD unrestricted HTTPS or a torrent-stream
  /// localhost URL.
  final String url;

  /// Optional display title shown in the overlay bar.
  final String? title;

  /// Optional extra HTTP headers (e.g. auth) forwarded to the backend.
  final Map<String, String>? headers;

  /// Convenience push helper so callers don't have to import [MaterialPageRoute].
  static Future<void> push(
    BuildContext context, {
    required String url,
    String? title,
    Map<String, String>? headers,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BeamPlayerScreen(url: url, title: title, headers: headers),
      ),
    );
  }

  @override
  State<BeamPlayerScreen> createState() => _BeamPlayerScreenState();
}

class _BeamPlayerScreenState extends State<BeamPlayerScreen> {
  late final Player _player;
  final List<StreamSubscription<dynamic>> _subs = [];

  bool _controlsVisible = true;
  bool _buffering = true;
  String? _error;
  Timer? _hideTimer;

  /// Drives [Video]'s black cover.
  ///
  /// THIS is why the picture was black. Video() paints
  /// `ColoredBox(color: hasFirstFrame ? transparent : backgroundColor)` OVER
  /// the video surface, and only lifts that cover once this flips true. This
  /// screen never passed `hasFirstFrame`, so the cover stayed opaque black
  /// forever — audio played, the decoder reported healthy 1920x1080 output,
  /// the surface was configured, and the user saw black.
  ///
  /// [VideoPlayerScreen] sets it from `streams.playbackRestart`, with a
  /// position-advance fallback because on Android/ExoPlayer playbackRestart
  /// does not fire. We need both for the same reason.
  final ValueNotifier<bool> _hasFirstFrame = ValueNotifier<bool>(false);
  int? _lastPositionMs;

  @override
  void initState() {
    super.initState();
    // Force the MPV backend instead of ExoPlayer.
    //
    // Diagnostic bisect for the black-picture bug: every symptom so far points
    // at the ExoPlayer *surface* path rather than at decode or delivery
    // (decoder reports healthy 1920x1080, surface configures, audio plays,
    // hasFirstFrame flips true, and the stream serves a valid fast-start MP4).
    // MPV renders through a completely different output path, so if the
    // picture appears with this one line changed, the fault is isolated to
    // ExoPlayer surface compositing on this 32-bit Amlogic TV.
    _player = Player(useExoPlayer: false);
    _wireStreams();
    _open();
    _scheduleHide();
  }

  /// Configure video output BEFORE opening the media.
  ///
  /// This screen previously did `Player()` -> `open()` -> `play()` with no
  /// property setup at all, unlike [VideoPlayerScreen], which configures the
  /// Android/ExoPlayer backend explicitly. The omission that matters is
  /// TUNNELED PLAYBACK.
  ///
  /// PlayerAndroid defaults `_tunnelingEnabled = true`, and on this Amlogic
  /// Android TV that engages the hardware VideoTunnelRenderer: decoded frames
  /// go straight from the decoder to the display via a hardware sync id,
  /// bypassing the app's surface entirely. Flutter is then supposed to punch a
  /// transparent hole for the hardware layer to show through. When that hole
  /// isn't established, the result is EXACTLY the observed symptom — audio
  /// plays, the decoder reports healthy 1920x1080 output, the surface is
  /// configured, and the picture is BLACK.
  ///
  /// Disabling tunneling routes frames back through the normal surface path,
  /// which is the one already proven to render on this device.
  Future<void> _configureVideoOutput() async {
    // Each property is set independently: an unsupported one must not skip
    // the rest.
    Future<void> set(String name, String value) async {
      try {
        await _player.setProperty(name, value);
      } catch (e) {
        appLogger.w('BeamPlayer: setProperty($name=$value) failed: $e');
      }
    }

    await set('tunneled-playback', 'no');

    // Match the WORKING player (video_player_screen.dart -> _getHwdecValue).
    // The `mediacodec-copy` fallback is the important half: plain `mediacodec`
    // hands frames to the display in an opaque hardware buffer that Flutter
    // cannot composite into its own surface, whereas `-copy` copies them back
    // into memory the renderer can actually draw. Leaving this unset let the
    // backend pick the opaque path — audio plays, the decoder reports healthy
    // 1920x1080 output, and the picture stays black.
    await set('hwdec', 'mediacodec,mediacodec-copy');
  }

  void _markFirstFrame() {
    if (!mounted || _hasFirstFrame.value) return;
    _hasFirstFrame.value = true;
  }

  void _wireStreams() {
    // Primary signal: the renderer restarted, i.e. a frame is on screen.
    _subs.add(_player.streams.playbackRestart.listen((_) => _markFirstFrame()));

    // Fallback: on Android/ExoPlayer playbackRestart does not fire, so infer
    // readiness from the position clock actually advancing. Without this the
    // black cover never lifts on this device.
    _subs.add(_player.streams.position.listen((pos) {
      if (_hasFirstFrame.value) return;
      final ms = pos.inMilliseconds;
      if (_lastPositionMs != null && ms != _lastPositionMs) _markFirstFrame();
      _lastPositionMs = ms;
    }));

    _subs.add(_player.streams.buffering.listen((b) {
      if (mounted) setState(() => _buffering = b);
    }));
    _subs.add(_player.streams.error.listen((e) {
      appLogger.e('BeamPlayer error: ${e.message}');
      if (mounted) setState(() => _error = e.message);
    }));
  }

  Future<void> _open() async {
    try {
      // Must precede open(): the backend latches its video-output mode when
      // the media is loaded, so setting this afterwards is too late.
      await _configureVideoOutput();
      await _player.open(Media(widget.url, headers: widget.headers));
      await _player.play();
    } catch (e) {
      appLogger.e('BeamPlayer open failed: $e');
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _hasFirstFrame.dispose();
    // Fire-and-forget; the native core tears itself down.
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Video(
              player: _player,
              // Without this the widget's opaque black cover never lifts.
              hasFirstFrame: _hasFirstFrame,
              backgroundColor: Colors.black,
            ),
            if (_buffering && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (_error != null) _buildError(context),
            if (_controlsVisible || _error != null) _buildTopBar(context),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.7), Colors.transparent],
          ),
        ),
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 8,
          bottom: 24,
          left: 8,
          right: 16,
        ),
        child: Row(
          children: [
            IconButton(
              autofocus: true,
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: Text(
                widget.title ?? 'Beam',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 56),
            const SizedBox(height: 16),
            Text(
              'Playback failed',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}
