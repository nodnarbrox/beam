import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';

import 'package:plezy/utils/app_logger.dart';

import 'beam_config.dart';
import 'vpn_detect.dart';

/// A free community OpenVPN server from VPN Gate.
class CommunityVpnServer {
  CommunityVpnServer({
    required this.hostName,
    required this.ip,
    required this.country,
    required this.countryShort,
    required this.speedBps,
    required this.pingMs,
    required this.ovpnConfig,
  });

  final String hostName;
  final String ip;
  final String country;
  final String countryShort;
  final int speedBps; // measured throughput, higher = better
  final int pingMs;
  final String ovpnConfig; // full inline .ovpn (CA + dummy cert/key, no auth)

  String get speedHuman => '${(speedBps / 1000000).toStringAsFixed(0)} Mbps';
  String get label => '$country · $speedHuman · ${pingMs}ms';
}

/// The app's OWN free community VPN (VPN Gate over OpenVPN).
///
/// WHY THIS EXISTS: a censoring device VPN (e.g. Surfshark) blackholes torrent
/// indexer domains via its DNS (CleanWeb) and drops the UDP that DHT needs, so
/// search fails and the swarm can't be found. This runs the app's own OpenVPN
/// tunnel to a free VPN Gate relay, which has NEITHER of those restrictions —
/// clean DNS + real UDP — so indexers resolve and the swarm connects.
///
/// ANDROID REALITY: only ONE VpnService can be active per profile. Starting this
/// tunnel REPLACES whatever VPN is currently up (the user turns their other VPN
/// off first; if it's "always-on", Android won't let this start and connect()
/// will report an error). It does not, and cannot, nest inside another VPN.
///
/// VPN Gate servers are volunteer/ephemeral — a server can die and a dead tunnel
/// blackholes traffic, so [connectBest] verifies the stage reaches "connected"
/// and [rotate] fetches a fresh server on failure.
class BeamCommunityVpn {
  BeamCommunityVpn._();
  @visibleForTesting
  BeamCommunityVpn.forTesting(OpenVPN engine) : _engine = engine, _initialized = true;
  static final BeamCommunityVpn instance = BeamCommunityVpn._();

  static const _vpnGateCsv = 'https://www.vpngate.net/api/iphone/';

  OpenVPN? _engine;
  bool _initialized = false;
  VpnStatus? _lastStatus;
  VPNStage _stage = VPNStage.disconnected;
  CommunityVpnServer? _current;
  int _connectionGeneration = 0;
  Completer<bool>? _pendingConnection;

  final _stageController = StreamController<VPNStage>.broadcast();

  /// Emits connection stage changes (connecting → connected → disconnected…).
  Stream<VPNStage> get stageStream => _stageController.stream;
  VPNStage get stage => _stage;
  CommunityVpnServer? get currentServer => _current;
  bool get isConnected => _stage == VPNStage.connected;

  void _ensureEngine() {
    if (_initialized) return;
    _engine = OpenVPN(
      onVpnStatusChanged: (s) => _lastStatus = s,
      onVpnStageChanged: (stage, raw) {
        _stage = stage;
        _lastRaw = raw.toString().toLowerCase();
        if (!_stageController.isClosed) _stageController.add(stage);
        appLogger.i('BeamCommunityVpn: stage=$stage ($raw)');
      },
    );
    // groupIdentifier/providerBundleIdentifier are iOS-only; harmless on Android.
    _engine!.initialize(
      groupIdentifier: 'group.com.edde746.plezy',
      providerBundleIdentifier: 'com.edde746.plezy.vpn',
      localizedDescription: 'MediaBeam VPN',
    );
    _initialized = true;
  }

  /// Fetches the VPN Gate server list, best (fastest) first. Returns [] on
  /// failure (network/parse) so callers can surface a clean error.
  Future<List<CommunityVpnServer>> fetchServers({String? preferCountry}) async {
    final client = http.Client();
    try {
      final r = await client.get(Uri.parse(_vpnGateCsv)).timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) {
        appLogger.w('VPN Gate HTTP ${r.statusCode}');
        return const [];
      }
      return _parseCsv(r.body, preferCountry: preferCountry);
    } catch (e) {
      appLogger.w('VPN Gate fetch failed: $e');
      return const [];
    } finally {
      client.close();
    }
  }

  /// Column order (VPN Gate iphone CSV):
  /// HostName,IP,Score,Ping,Speed,CountryLong,CountryShort,NumVpnSessions,
  /// Uptime,TotalUsers,TotalTraffic,LogType,Operator,Message,OpenVPN_ConfigData_Base64
  List<CommunityVpnServer> _parseCsv(String body, {String? preferCountry}) {
    final out = <CommunityVpnServer>[];
    for (final line in const LineSplitter().convert(body)) {
      if (line.isEmpty || line.startsWith('*') || line.startsWith('#')) continue;
      final c = line.split(',');
      if (c.length < 15) continue;
      final b64 = c[14].trim();
      if (b64.isEmpty) continue;
      String config;
      try {
        config = utf8.decode(base64.decode(b64));
      } catch (_) {
        continue;
      }
      if (!config.contains('remote ')) continue;
      out.add(
        CommunityVpnServer(
          hostName: c[0],
          ip: c[1],
          pingMs: int.tryParse(c[3]) ?? 9999,
          speedBps: int.tryParse(c[4]) ?? 0,
          country: c[5],
          countryShort: c[6],
          ovpnConfig: config,
        ),
      );
    }
    // Fastest first; optionally float a preferred country to the top.
    out.sort((a, b) => b.speedBps.compareTo(a.speedBps));
    if (preferCountry != null && preferCountry.isNotEmpty) {
      final pref = preferCountry.toUpperCase();
      out.sort((a, b) {
        final ap = a.countryShort.toUpperCase() == pref ? 0 : 1;
        final bp = b.countryShort.toUpperCase() == pref ? 0 : 1;
        return ap != bp ? ap - bp : b.speedBps.compareTo(a.speedBps);
      });
    }
    return out;
  }

  /// Connects to a specific server and waits until it reaches "connected" (or
  /// times out). Returns true on success.
  Future<bool> connect(
    CommunityVpnServer server, {
    Duration timeout = const Duration(seconds: 40),
    Future<void>? cancelled,
  }) async {
    _ensureEngine();
    _current = server;
    appLogger.i(
      'BeamCommunityVpn: connecting ${server.hostName} '
      '(${server.country}, ${server.speedHuman})',
    );
    // VPN Gate configs embed a dummy cert; no user/pass needed.
    final done = Completer<bool>();
    final generation = ++_connectionGeneration;
    _pendingConnection = done;
    unawaited(
      cancelled?.then((_) {
        // An abandoned attempt must not tear down a newer connection or an
        // already established tunnel.
        if (generation == _connectionGeneration && !done.isCompleted) {
          unawaited(disconnect());
        }
      }),
    );
    unawaited(
      _engine!
          .connect(
            server.ovpnConfig,
            'MediaBeam · ${server.country}',
            username: '',
            password: '',
            certIsRequired: false,
          )
          .catchError((Object error, StackTrace stack) {
            appLogger.w('Community VPN start failed', error: error, stackTrace: stack);
            if (!done.isCompleted) done.complete(false);
          }),
    );
    // Wait for "connected", but bail EARLY on a dead server: VPN Gate relays
    // that are overloaded/dead enter a tcp_connect↔reconnect loop and never
    // finish the TLS handshake. Two reconnects without connecting = give up and
    // let connectBest try the next server, instead of burning the full timeout.
    var reconnects = 0;
    late final StreamSubscription<VPNStage> sub;
    sub = stageStream.listen((s) {
      if (s == VPNStage.connected) {
        if (!done.isCompleted) done.complete(true);
      } else if (_rawIsReconnect(s)) {
        reconnects++;
        if (reconnects >= 2 && !done.isCompleted) done.complete(false);
      } else if (s == VPNStage.disconnected && reconnects > 0) {
        if (!done.isCompleted) done.complete(false);
      }
    });
    try {
      return await done.future.timeout(timeout, onTimeout: () => false);
    } finally {
      await sub.cancel();
      if (identical(_pendingConnection, done)) _pendingConnection = null;
    }
  }

  // The plugin maps the "reconnect" raw stage to VPNStage.unknown; we track it
  // via the raw string in the stage callback (see _ensureEngine).
  bool _rawIsReconnect(VPNStage s) => s == VPNStage.unknown && _lastRaw == 'reconnect';
  String _lastRaw = '';

  /// Fetches servers and connects to the best that actually comes up, trying the
  /// next on failure (VPN Gate servers rot). Returns the connected server or
  /// null if none worked.
  Future<CommunityVpnServer?> connectBest({String? preferCountry, int maxAttempts = 8, Future<void>? cancelled}) async {
    var abandoned = false;
    unawaited(cancelled?.then((_) => abandoned = true));
    final servers = await fetchServers(preferCountry: preferCountry);
    if (abandoned) return null;
    if (servers.isEmpty) {
      appLogger.w('BeamCommunityVpn: no VPN Gate servers available');
      return null;
    }
    for (final s in servers.take(maxAttempts)) {
      // 25s per server: a healthy VPN Gate relay completes the handshake well
      // within this; a dead one is abandoned early by connect()'s reconnect
      // detector, so we move through rot quickly.
      if (abandoned) return null;
      final connected = await connect(s, timeout: const Duration(seconds: 25), cancelled: cancelled);
      if (abandoned) return null;
      if (connected) return s;
      // Tear the failed attempt down before trying the next.
      await disconnect();
    }
    appLogger.w('BeamCommunityVpn: all $maxAttempts attempts failed');
    return null;
  }

  /// Rotates to a fresh server (e.g. after the current one dies).
  Future<CommunityVpnServer?> rotate({String? preferCountry}) async {
    await disconnect();
    return connectBest(preferCountry: preferCountry);
  }

  Future<void> disconnect() async {
    ++_connectionGeneration;
    final pending = _pendingConnection;
    _pendingConnection = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
    if (!_initialized) return;
    try {
      _engine?.disconnect();
    } catch (e) {
      appLogger.w('BeamCommunityVpn: disconnect error: $e');
    }
    _current = null;
  }

  VpnStatus? get lastStatus => _lastStatus;

  /// Auto-connect hook for the search/play flow. Connects the community VPN ONLY
  /// when the user opted in (BeamConfig.autoCommunityVpn) AND nothing is already
  /// providing a tunnel — i.e. don't clobber a VPN the user already has up, and
  /// don't reconnect if we're already connected. Best-effort: never throws, so a
  /// failed VPN attempt can't block the search itself. Returns true if a tunnel
  /// is up (pre-existing or freshly connected) after the call.
  Future<bool> ensureConnectedIfEnabled({Future<void>? cancelled}) async {
    var abandoned = false;
    unawaited(cancelled?.then((_) => abandoned = true));
    try {
      await BeamConfig.init();
      if (abandoned) return false;
      if (!BeamConfig.autoCommunityVpn) return false;
      if (isConnected) return true;
      // Something else (e.g. Surfshark) already tunnels — leave it; the user
      // enabled auto-VPN for the no-VPN case, and we can't stack anyway.
      if (await VpnDetect.isVpnActive()) return true;
      if (abandoned) return false;
      final server = await connectBest(cancelled: cancelled);
      return server != null;
    } catch (e) {
      appLogger.w('BeamCommunityVpn: auto-connect skipped: $e');
      return false;
    }
  }
}
