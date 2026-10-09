import 'package:flutter/material.dart';

import '../services/beam/beam_buffer_wait.dart';

/// TV-friendly choice for a measured, slow initial buffer. The race continues.
class BeamBufferWaitDialog extends StatefulWidget {
  const BeamBufferWaitDialog({super.key, required this.offer, required this.onKeepBuffering, required this.onCancel});

  final BeamBufferWaitOffer offer;
  final VoidCallback onKeepBuffering;
  final VoidCallback onCancel;

  static String formatWait(Duration duration) {
    final rounded = (duration.inMilliseconds / 1000).ceil();
    final seconds = rounded < 1 ? 1 : rounded;
    if (seconds >= 3600) {
      return '${seconds ~/ 3600}:${((seconds % 3600) ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
    }
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  State<BeamBufferWaitDialog> createState() => _BeamBufferWaitDialogState();
}

class _BeamBufferWaitDialogState extends State<BeamBufferWaitDialog> {
  final _keepFocus = FocusNode(debugLabel: 'BeamKeepBuffering');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keepFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _keepFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final estimate = widget.offer.estimatedWait;
    return AlertDialog(
      title: const Text('Wait for this video to buffer?'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              estimate == null
                  ? 'This source is slow. There is not enough progress to estimate the wait yet.'
                  : 'About ${BeamBufferWaitDialog.formatWait(estimate)} more to build the starting buffer.',
            ),
            const SizedBox(height: 12),
            const Text('The estimate can change. Playback may still pause if the download stays slow.'),
            const SizedBox(height: 12),
            const Text('We will keep trying other sources and start automatically when one is ready.'),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
        FilledButton(
          focusNode: _keepFocus,
          autofocus: true,
          onPressed: widget.onKeepBuffering,
          child: const Text('Keep buffering'),
        ),
      ],
    );
  }
}
