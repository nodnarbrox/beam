import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:plezy/utils/app_logger.dart';

/// The kind of link the device is currently on, collapsed to the only
/// distinction that matters for quality selection: is this an *unmetered*,
/// generally-fast link (WiFi / Ethernet) or a *metered*, variable cellular
/// link where we should stream conservatively to avoid stalls AND to spare the
/// user's data cap?
enum NetworkClass {
  /// WiFi / Ethernet / VPN-over-WiFi — treat as unmetered & fast. Use the full
  /// device-capability ceiling; bandwidth measurement governs from there.
  unmetered,

  /// Cellular / mobile data — metered & variable. Start conservative (a lower
  /// resolution cap) so playback is smooth on a slow/variable link and we don't
  /// burn the data cap; let the bandwidth EWMA upshift only if it's truly fast.
  cellular,

  /// Highly-constrained satellite link — most conservative of all.
  constrained,

  /// No connectivity / unknown — assume unmetered so we don't needlessly cap a
  /// device we can't classify (the bandwidth downshift still protects playback).
  unknown,
}

/// A tiny wrapper over connectivity_plus that (a) classifies the current link
/// into a [NetworkClass], (b) exposes an initial-quality *resolution cap* for
/// that class, and (c) streams changes so a live playback controller can
/// re-evaluate and downshift when the link degrades (e.g. WiFi -> cellular).
class NetworkClassProbe {
  NetworkClassProbe._();

  static final NetworkClassProbe instance = NetworkClassProbe._();

  final Connectivity _conn = Connectivity();

  /// Resolution ceiling (in vertical pixels) to *start* at for a given class,
  /// before any bandwidth measurement. On cellular we deliberately begin low
  /// (720p) and let a genuinely-fast pipe upshift; unmetered links defer
  /// entirely to the device-capability ceiling (represented as no extra cap).
  ///
  /// Returns `null` when the class imposes no cap (unmetered / unknown).
  static int? capForClass(NetworkClass c) {
    switch (c) {
      case NetworkClass.cellular:
        return 720; // data-saver default on mobile data
      case NetworkClass.constrained:
        return 480; // satellite / heavily-constrained
      case NetworkClass.unmetered:
      case NetworkClass.unknown:
        return null; // no network-imposed cap; device ceiling governs
    }
  }

  static NetworkClass _classify(List<ConnectivityResult> results) {
    // The list can carry multiple transports (e.g. [mobile, satellite] or
    // [wifi, vpn]). Order of precedence for *safety*: satellite (most
    // constrained) > cellular > unmetered. VPN alone maps to unmetered because
    // a VPN over WiFi is still WiFi-speed; a VPN over cellular will also carry
    // the `mobile` entry, which we catch first.
    if (results.contains(ConnectivityResult.satellite)) {
      return NetworkClass.constrained;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return NetworkClass.cellular;
    }
    if (results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet)) {
      return NetworkClass.unmetered;
    }
    if (results.contains(ConnectivityResult.vpn) ||
        results.contains(ConnectivityResult.other) ||
        results.contains(ConnectivityResult.bluetooth)) {
      // Ambiguous transport — assume unmetered so we don't over-restrict.
      return NetworkClass.unmetered;
    }
    // [none] or empty -> unknown.
    return NetworkClass.unknown;
  }

  /// Probes the current link once. Never throws — on any error returns
  /// [NetworkClass.unknown] so quality is not over-restricted.
  Future<NetworkClass> probe() async {
    try {
      final results = await _conn.checkConnectivity();
      final cls = _classify(results);
      appLogger.i('NetworkClass: $cls '
          '(${results.map((r) => r.name).join('+')}, '
          'cap=${capForClass(cls) ?? 'none'})');
      return cls;
    } catch (e) {
      appLogger.w('NetworkClass probe failed, assuming unmetered: $e');
      return NetworkClass.unknown;
    }
  }

  /// Emits a new [NetworkClass] whenever connectivity changes. Distinct — only
  /// fires when the *class* actually changes (e.g. WiFi -> cellular), not on
  /// every raw transport flap. Use this to downshift mid-stream.
  Stream<NetworkClass> get changes => _conn.onConnectivityChanged
      .map(_classify)
      .distinct();
}
