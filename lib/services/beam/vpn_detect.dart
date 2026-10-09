import 'dart:async';
import 'dart:io';

import 'package:plezy/utils/app_logger.dart';

/// Detects a DEVICE-LEVEL VPN (Surfshark, Mullvad, PIA, WireGuard…).
///
/// Why this matters: the torrent path is fail-closed and originally demanded an
/// in-app SOCKS5 proxy. But a real VPN is the model every working torrent
/// streamer actually uses (Elementum/Stremio), and it's strictly better here:
/// SOCKS5 carries TCP only — it kills DHT/uTP and free SOCKS5 proxies proved
/// flaky and even MITM'd TLS. A device VPN tunnels EVERYTHING (including UDP),
/// so DHT works, peer discovery is healthy, and the traffic is encrypted.
///
/// Surfshark specifically offers no SOCKS5 endpoint (removed 2021), so without
/// this the app would refuse to stream even though the user is fully protected.
///
/// Detection is interface-based: Android routes VPN traffic over a `tun`/`ppp`/
/// `wg` device, so the presence of such an interface holding a non-loopback
/// address means a VPN tunnel is up. This is a best-effort signal, not proof of
/// a particular provider.
class VpnDetect {
  VpnDetect._();

  static const _vpnPrefixes = ['tun', 'ppp', 'wg', 'ipsec', 'utun'];

  /// True when a VPN tunnel interface is up and carrying an address.
  static Future<bool> isVpnActive() async {
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.any,
      );
      for (final i in ifaces) {
        final name = i.name.toLowerCase();
        final isVpnIface = _vpnPrefixes.any(name.startsWith);
        if (isVpnIface && i.addresses.isNotEmpty) {
          appLogger.i('VpnDetect: device VPN active on ${i.name} '
              '(${i.addresses.first.address})');
          return true;
        }
      }
      return false;
    } catch (e) {
      // Never fail OPEN on an error — if we can't tell, report no VPN so the
      // fail-closed guard keeps protecting the user.
      appLogger.w('VpnDetect: interface probe failed: $e');
      return false;
    }
  }

  /// Cached result of [udpWorks] and when it was measured.
  ///
  /// The cache MUST expire. The answer changes whenever the network path does
  /// — reconnecting the VPN, switching server, or changing protocol
  /// (OpenVPN-TCP has no UDP; OpenVPN-UDP/WireGuard do). Caching for the whole
  /// process lifetime meant flipping the VPN to UDP had no effect until the
  /// app was force-restarted, and the stale answer silently kept DHT/uTP
  /// disabled — the swarm then found peers but never seeds.
  static bool? _udpWorks;
  static DateTime? _udpWorksAt;

  /// How long a UDP verdict stays trustworthy.
  static const Duration _udpCacheTtl = Duration(minutes: 2);

  /// Also keyed to the tunnel identity, so a VPN reconnect that hands us a new
  /// interface/address re-probes immediately rather than waiting out the TTL.
  static String? _udpWorksIface;

  /// Drop the cached UDP verdict — call when the network is known to have
  /// changed and the next probe must be fresh.
  static void invalidateUdpCache() {
    _udpWorks = null;
    _udpWorksAt = null;
    _udpWorksIface = null;
  }

  /// True when outbound UDP actually reaches a tracker through the current
  /// network path.
  ///
  /// A VPN being up does NOT imply UDP works. Surfshark (verified on-device,
  /// 2026-08) silently drops outbound UDP: TCP to tracker.opentrackr.org:1337
  /// connects fine while UDP to the SAME host:port never answers, so every
  /// `udp://` tracker times out and DHT never bootstraps — the swarm looks
  /// empty and streaming stalls at "Connecting to swarm…" forever.
  ///
  /// We probe rather than assume so a tunnel that DOES carry UDP (plain
  /// OpenVPN/WireGuard) keeps the better DHT-enabled path.
  static Future<bool> udpWorks({bool force = false}) async {
    // Current tunnel identity: a change means the path changed, so re-probe.
    final iface = await activeInterface();
    final fresh = _udpWorksAt != null &&
        DateTime.now().difference(_udpWorksAt!) < _udpCacheTtl;
    if (!force && _udpWorks != null && fresh && _udpWorksIface == iface) {
      return _udpWorks!;
    }
    _udpWorksAt = DateTime.now();
    _udpWorksIface = iface;
    // Minimal BEP-15 connect request: magic protocol id, action=0, random txn.
    final txn = DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF;
    final req = <int>[
      0, 0, 4, 23, 39, 16, 25, 128, // 0x41727101980 magic
      0, 0, 0, 0, // action = connect
      (txn >> 24) & 0xFF, (txn >> 16) & 0xFF, (txn >> 8) & 0xFF, txn & 0xFF,
    ];
    // Try several trackers: one being down must not be read as "UDP blocked",
    // which would needlessly disable DHT/uTP and cripple peer discovery.
    const probes = <(String, int)>[
      ('tracker.opentrackr.org', 1337),
      ('open.demonii.com', 1337),
      ('exodus.desync.com', 6969),
    ];

    for (final (host, port) in probes) {
      RawDatagramSocket? sock;
      try {
        // MUST resolve to IPv4 explicitly. InternetAddress.lookup() returns
        // IPv6 first on dual-stack devices (the ONN has several), and sending
        // to an IPv6 destination from a socket bound to anyIPv4 fails
        // silently — which read as "UDP blocked" even when UDP worked fine.
        final addrs = await InternetAddress.lookup(host,
            type: InternetAddressType.IPv4);
        if (addrs.isEmpty) continue;

        sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        final s = sock;
        final dest = addrs.first;

        // Drive send + receive off the socket's event stream. Calling send()
        // before the socket reports RawSocketEvent.write returns 0 (the
        // datagram is dropped, no exception), which previously made a working
        // UDP path look blocked. Re-send on each write event until accepted.
        final done = Completer<bool>();
        late final StreamSubscription<RawSocketEvent> sub;
        var sent = false;
        sub = s.listen((event) {
          if (event == RawSocketEvent.write && !sent) {
            if (s.send(req, dest, port) > 0) sent = true;
          } else if (event == RawSocketEvent.read) {
            final dg = s.receive();
            // A valid BEP-15 connect reply is >=16 bytes and echoes action=0.
            if (dg != null && dg.data.length >= 16 && !done.isCompleted) {
              done.complete(true);
            }
          }
        }, onError: (Object e) {
          if (!done.isCompleted) done.complete(false);
        }, onDone: () {
          if (!done.isCompleted) done.complete(false);
        });
        // Nudge the first send in case the write event already fired.
        if (!sent && s.send(req, dest, port) > 0) sent = true;

        final ok = await done.future
            .timeout(const Duration(seconds: 5), onTimeout: () => false);
        await sub.cancel();
        if (ok) {
          appLogger.i('VpnDetect: outbound UDP works (probe via $host)');
          return _udpWorks = true;
        }
        appLogger.w('VpnDetect: no UDP reply from $host:$port (sent=$sent)');
      } catch (e) {
        appLogger.w('VpnDetect: UDP probe to $host failed: $e');
      } finally {
        sock?.close();
      }
    }

    appLogger.i('VpnDetect: outbound UDP BLOCKED (all tracker probes failed)');
    return _udpWorks = false;
  }

  /// Human-readable name of the active tunnel interface, for the settings UI.
  static Future<String?> activeInterface() async {
    try {
      final ifaces = await NetworkInterface.list(includeLoopback: false);
      for (final i in ifaces) {
        final name = i.name.toLowerCase();
        if (_vpnPrefixes.any(name.startsWith) && i.addresses.isNotEmpty) {
          return i.name;
        }
      }
    } catch (_) {}
    return null;
  }
}
