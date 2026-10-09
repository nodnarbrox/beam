import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

import 'package:plezy/utils/app_logger.dart';

import 'release_quality.dart';

/// What a given piece of hardware can realistically DECODE and play smoothly —
/// independent of network bandwidth. Used as a *ceiling* on the initial quality
/// pick so a weak box (e.g. a 32-bit ONN with ~1.9 GB RAM) never even attempts
/// 2160p / HEVC / AV1 / HDR, which it cannot play smoothly regardless of pipe.
///
/// The bandwidth-based downshift in [AdaptiveQualityController] still applies on
/// top of this: final first pick = min(bandwidth-allows, device-can-decode).
class DeviceCapability {
  const DeviceCapability({
    required this.maxResolution,
    required this.allowHevc,
    required this.allowAv1,
    required this.allowHdr,
    required this.is64Bit,
    required this.ramMb,
    required this.label,
  });

  /// Highest resolution this device should attempt (e.g. 1080 or 2160).
  final int maxResolution;

  /// May we pick an HEVC/x265 release? Weak 32-bit SoCs often lack a fast HEVC
  /// decoder path; software HEVC at 1080p+ stutters.
  final bool allowHevc;

  /// May we pick an AV1 release? AV1 hardware decode is rare on older/weak TV
  /// boxes; software AV1 is effectively unplayable there.
  final bool allowAv1;

  /// May we pick an HDR/Dolby-Vision release? SDR panels + weak tone-mapping
  /// make HDR look worse, not better, on cheap boxes.
  final bool allowHdr;

  final bool is64Bit;
  final int ramMb;

  /// Human-readable summary for logs / diagnostics.
  final String label;

  /// A permissive default used when probing fails — assume a capable device so
  /// we don't needlessly cap quality on an unknown platform. (The bandwidth
  /// downshift still protects playback.)
  static const DeviceCapability unknownCapable = DeviceCapability(
    maxResolution: 2160,
    allowHevc: true,
    allowAv1: true,
    allowHdr: true,
    is64Bit: true,
    ramMb: 0,
    label: 'unknown (assumed capable)',
  );

  /// Conservative floor for a weak 32-bit / low-RAM box like the ONN.
  static const DeviceCapability lowEnd = DeviceCapability(
    maxResolution: 1080,
    allowHevc: false,
    allowAv1: false,
    allowHdr: false,
    is64Bit: false,
    ramMb: 0,
    label: 'low-end 32-bit',
  );

  static DeviceCapability? _cached;

  /// Probes the running device once (cached). Uses device_info_plus for RAM +
  /// ABI list and dart:io [Platform] as a cross-check for arch. Never throws —
  /// on any error returns [unknownCapable] so quality is not over-restricted.
  static Future<DeviceCapability> probe() async {
    final cached = _cached;
    if (cached != null) return cached;

    DeviceCapability cap;
    try {
      if (Platform.isAndroid) {
        cap = await _probeAndroid();
      } else if (Platform.isIOS) {
        // Modern iOS devices are 64-bit with hardware HEVC/HDR; AV1 hw decode
        // only on very recent chips, but software AV1 on iOS is acceptable at
        // 1080p. Treat as fully capable.
        cap = unknownCapable;
      } else {
        // Desktop (Windows/macOS/Linux) — assume capable; bandwidth governs.
        cap = unknownCapable;
      }
    } catch (e) {
      appLogger.w('DeviceCapability probe failed, assuming capable: $e');
      cap = unknownCapable;
    }
    appLogger.i('DeviceCapability: ${cap.label} '
        '(maxRes=${cap.maxResolution}, hevc=${cap.allowHevc}, '
        'av1=${cap.allowAv1}, hdr=${cap.allowHdr}, ram=${cap.ramMb}MB)');
    _cached = cap;
    return cap;
  }

  static Future<DeviceCapability> _probeAndroid() async {
    final info = await DeviceInfoPlugin().androidInfo;
    final ramMb = info.physicalRamSize; // megabytes
    // 64-bit if the device advertises any 64-bit ABI (arm64-v8a / x86_64).
    final is64Bit = info.supported64BitAbis.isNotEmpty ||
        info.supportedAbis.any((a) =>
            a.contains('arm64') || a.contains('x86_64') || a.contains('64'));

    // Tiering:
    //  - Weak: 32-bit OR < 2500 MB RAM → 1080p x264 SDR only (the ONN class).
    //  - Mid : 64-bit + 2500..6000 MB  → up to 1080p, HEVC OK, no 4K/AV1/HDR.
    //  - High: 64-bit + >= 6000 MB     → up to 2160p, HEVC + AV1 + HDR.
    final bool weak = !is64Bit || ramMb < 2500;
    final bool high = is64Bit && ramMb >= 6000;

    if (weak) {
      return DeviceCapability(
        maxResolution: 1080,
        allowHevc: false,
        allowAv1: false,
        allowHdr: false,
        is64Bit: is64Bit,
        ramMb: ramMb,
        label: 'weak (${is64Bit ? '64' : '32'}-bit, ${ramMb}MB)',
      );
    }
    if (high) {
      return DeviceCapability(
        maxResolution: 2160,
        allowHevc: true,
        allowAv1: true,
        allowHdr: true,
        is64Bit: true,
        ramMb: ramMb,
        label: 'high-end (64-bit, ${ramMb}MB)',
      );
    }
    // Mid tier.
    return DeviceCapability(
      maxResolution: 1080,
      allowHevc: true,
      allowAv1: false,
      allowHdr: false,
      is64Bit: true,
      ramMb: ramMb,
      label: 'mid (64-bit, ${ramMb}MB)',
    );
  }

  /// True if this device should be allowed to attempt playing [q].
  bool allows(ReleaseQuality q) {
    if (q.resolution > maxResolution) return false;
    if (!allowHevc && q.codec == 'x265') return false;
    if (!allowAv1 && q.codec == 'AV1') return false;
    if (!allowHdr && q.hdr) return false;
    return true;
  }

  /// Returns a copy of this capability with its [maxResolution] tightened to at
  /// most [resolutionCap] — used to layer a *network-type* ceiling (e.g. 720p on
  /// cellular) on top of the hardware ceiling without loosening anything.
  ///
  /// Passing `null` (unmetered / unknown link) returns this instance unchanged.
  /// The resulting `allows()` therefore enforces
  /// min(device-can-decode, connection-type-cap).
  DeviceCapability cappedTo(int? resolutionCap) {
    if (resolutionCap == null || resolutionCap >= maxResolution) return this;
    return DeviceCapability(
      maxResolution: resolutionCap,
      allowHevc: allowHevc,
      allowAv1: allowAv1,
      allowHdr: allowHdr,
      is64Bit: is64Bit,
      ramMb: ramMb,
      label: '$label + net-cap ${resolutionCap}p',
    );
  }
}
