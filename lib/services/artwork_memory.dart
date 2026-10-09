import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

/// Releases browsing artwork while one or more player routes own playback.
/// The routes and card state stay mounted; their decoded images do not.
abstract final class ArtworkMemory {
  static final _owners = Set<Object>.identity();
  static final _suspended = ValueNotifier<bool>(false);
  static final _browseAborts = <VoidCallback>{};
  static bool _publishScheduled = false;

  static ValueListenable<bool> get suspended => _suspended;
  static bool get isSuspended => _suspended.value;

  static void acquirePlayback(Object owner) {
    if (_owners.add(owner)) _schedulePublish();
  }

  static void releasePlayback(Object owner) {
    if (_owners.remove(owner)) _schedulePublish();
  }

  /// Only browsing providers register here; player trickplay is independent.
  static VoidCallback registerBrowseAbort(VoidCallback abort) {
    _browseAborts.add(abort);
    return () => _browseAborts.remove(abort);
  }

  static void _schedulePublish() {
    if (_publishScheduled) return;
    _publishScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _publishScheduled = false;
      final suspend = _owners.isNotEmpty;
      if (_suspended.value == suspend) return;
      _suspended.value = suspend;
      if (suspend) {
        // Listeners rebuild in the next frame. Evict only after their Image
        // widgets (including crossfade images) have detached their listeners.
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!isSuspended) return;
          for (final abort in List<VoidCallback>.of(_browseAborts)) {
            abort();
          }
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
        });
      }
      SchedulerBinding.instance.ensureVisualUpdate();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }
}
