import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:socks5_proxy/socks_client.dart';

import 'package:plezy/utils/app_logger.dart';

import 'beam_config.dart';
import 'vpn_detect.dart';

/// Builds the `http.Client` instances the Beam module uses, transparently
/// routing traffic through the configured private proxy so the swarm/RD
/// activity is hidden.
///
/// Dart's `HttpClient` supports an HTTP proxy natively (via `findProxy`) but
/// NOT SOCKS5, so for SOCKS we attach a connection factory from the
/// `socks5_proxy` package. HTTP-scheme proxies use `findProxy`. When the proxy
/// is disabled we return a plain client.
class BeamHttp {
  BeamHttp._();

  /// Returns a client honoring the current proxy settings. Callers own the
  /// returned client and should `close()` it when done. Because attaching a
  /// SOCKS factory requires resolving the proxy host, this is async.
  static Future<http.Client> client({Duration? idleTimeout}) async {
    // Defensively ensure config is loaded: every getter below throws if
    // BeamConfig.init() hasn't been awaited, and callers (e.g. indexer search
    // fired straight from a fresh screen) don't all guarantee it. init() is
    // idempotent, so this is a cheap no-op once warmed.
    await BeamConfig.init();
    if (!BeamConfig.proxyEnabled) {
      return _dohClient(idleTimeout: idleTimeout);
    }

    // A device VPN already tunnels everything, so stacking a SOCKS5 proxy on
    // top adds nothing but failure: a stale/dead proxy entry silently breaks
    // every indexer lookup even though the user is fully protected. When a VPN
    // is up, go direct through the tunnel.
    if (await VpnDetect.isVpnActive()) {
      appLogger.i('BeamHttp: device VPN active — bypassing SOCKS5 proxy');
      return _dohClient(idleTimeout: idleTimeout);
    }
    final hostPort = BeamConfig.proxyHostPort;
    if (hostPort == null) {
      appLogger.w('Beam proxy enabled but unconfigured; using direct client');
      return http.Client();
    }

    final scheme = BeamConfig.proxyScheme.toLowerCase();
    final host = BeamConfig.proxyHost;
    final port = BeamConfig.proxyPort;
    final user = BeamConfig.proxyUser.trim();
    final pass = (await BeamConfig.getProxyPass()).trim();

    final inner = HttpClient();
    if (idleTimeout != null) inner.idleTimeout = idleTimeout;

    if (scheme == 'http' || scheme == 'https') {
      // Native HTTP proxy path. Credentials must go through
      // addProxyCredentials — Dart's findProxy "PROXY host:port" directive has
      // no userinfo form, so embedding user:pass@ there does NOT authenticate
      // (the server answers 407 and the request just fails), besides putting
      // the password into a string that can end up in logs.
      inner.findProxy = (uri) => 'PROXY $host:$port';
      if (user.isNotEmpty) {
        inner.addProxyCredentials(
          host,
          port,
          '', // any realm
          HttpClientBasicCredentials(user, pass),
        );
      }
      return IOClient(inner);
    }

    // SOCKS5 (default). Resolve the proxy host to an InternetAddress.
    final addr = await _resolve(host);
    if (addr == null) {
      appLogger.e('Beam proxy host $host did not resolve; using direct client');
      return http.Client();
    }
    SocksTCPClient.assignToHttpClient(inner, [
      ProxySettings(
        addr,
        port,
        username: user.isEmpty ? null : user,
        password: pass.isEmpty ? null : pass,
      ),
    ]);
    return IOClient(inner);
  }

  /// A client that never uses the proxy — for strictly-LAN endpoints (rclone rc
  /// on localhost, on-device Plex server) where proxying would be wrong.
  static http.Client directClient() => http.Client();

  // ---- DNS-over-HTTPS (public DNS: Cloudflare 1.1.1.1 + Google 8.8.8.8) ----
  //
  // The device/VPN resolver (e.g. Surfshark CleanWeb) BLACKHOLES torrent-indexer
  // domains, so plain lookups return NXDOMAIN/sinkholes and every search fails.
  // We instead resolve indexer hostnames over HTTPS against public resolvers
  // (reached by literal IP, so no bootstrap DNS is needed), then connect to the
  // resolved address with the correct SNI/Host. This bypasses DNS censorship
  // regardless of what tunnel is up.

  /// DoH endpoints, by LITERAL IP (host header/SNI = the DoH provider). 1.1.1.1
  /// (Cloudflare) first, 8.8.8.8 (Google) as fallback.
  static const _dohEndpoints = <(String ip, String host)>[
    ('1.1.1.1', 'cloudflare-dns.com'),
    ('8.8.8.8', 'dns.google'),
  ];

  /// hostname -> resolved IPv4, cached for the process (indexer hosts are stable).
  static final Map<String, String> _dohCache = {};

  /// Builds an http.Client whose DNS goes through public DoH resolvers instead of
  /// the (possibly poisoned) system resolver. Falls back to a plain client if
  /// the custom connection path can't be set up.
  static http.Client _dohClient({Duration? idleTimeout}) {
    final inner = HttpClient();
    if (idleTimeout != null) inner.idleTimeout = idleTimeout;
    inner.connectionFactory = (uri, proxyHost, proxyPort) async {
      final host = uri.host;
      final port = uri.port > 0 ? uri.port : (uri.scheme == 'https' ? 443 : 80);
      // Literal IPs and localhost need no resolution.
      final ip = _isLiteralIp(host) ? host : await _dohResolve(host);
      final target = ip ?? host; // fall back to system resolve if DoH failed
      if (uri.scheme == 'https') {
        // Connect to the resolved IP, then TLS-upgrade with SNI + cert
        // validation against the REAL hostname (not the IP).
        final raw = await Socket.connect(target, port,
            timeout: const Duration(seconds: 12));
        final secure = await SecureSocket.secure(raw, host: host);
        return ConnectionTask.fromSocket(
            Future.value(secure), () => secure.destroy());
      }
      final s = await Socket.connect(target, port,
          timeout: const Duration(seconds: 12));
      return ConnectionTask.fromSocket(Future.value(s), () => s.destroy());
    };
    return IOClient(inner);
  }

  static bool _isLiteralIp(String h) {
    if (h == 'localhost') return true;
    try {
      InternetAddress(h);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Resolves [host] to an IPv4 via DoH (RFC 8484 JSON), trying each public
  /// resolver. Cached. Returns null if all fail (caller then uses system DNS).
  static Future<String?> _dohResolve(String host) async {
    final cached = _dohCache[host];
    if (cached != null) return cached;
    for (final (ip, providerHost) in _dohEndpoints) {
      HttpClient? c;
      try {
        c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
        // Connect to the resolver by IP with SNI = provider host.
        final uri = Uri.parse(
            'https://$ip/dns-query?name=${Uri.encodeQueryComponent(host)}&type=A');
        final req = await c.getUrl(uri);
        req.headers.set('accept', 'application/dns-json');
        req.headers.set('host', providerHost);
        final resp = await req.close().timeout(const Duration(seconds: 8));
        if (resp.statusCode != 200) continue;
        final body = await resp.transform(utf8.decoder).join();
        final json = jsonDecode(body);
        final answers = (json is Map) ? json['Answer'] : null;
        if (answers is List) {
          for (final a in answers.whereType<Map>()) {
            // type 1 = A record.
            if (a['type'] == 1) {
              final data = a['data']?.toString();
              if (data != null && _isLiteralIp(data)) {
                _dohCache[host] = data;
                appLogger.i('DoH: $host -> $data (via $providerHost)');
                return data;
              }
            }
          }
        }
      } catch (e) {
        appLogger.w('DoH resolve $host via $providerHost failed: $e');
      } finally {
        c?.close();
      }
    }
    appLogger.w('DoH: all resolvers failed for $host — using system DNS');
    return null;
  }

  static Future<InternetAddress?> _resolve(String host) async {
    // Literal IP fast-path.
    try {
      return InternetAddress(host);
    } catch (_) {
      // Not a literal; DNS-resolve.
    }
    try {
      final results = await InternetAddress.lookup(host);
      if (results.isNotEmpty) return results.first;
    } catch (e) {
      appLogger.w('proxy host lookup failed for $host: $e');
    }
    return null;
  }

  /// Verifies the proxy actually works by fetching an ip-echo through it and
  /// returning the exit IP (so the user can confirm they are hidden). Returns
  /// null on failure.
  static Future<String?> checkProxyExitIp() async {
    // Try several echo endpoints. Some free SOCKS5 proxies only do REMOTE DNS
    // (socks5h) and fail hostname targets resolved locally, so we also try a
    // Cloudflare trace by IP (1.1.1.1) which needs no target DNS at all — if
    // ANY of these returns, the proxy carries traffic and the user is hidden.
    const endpoints = <String>[
      'https://api.ipify.org?format=text',
      'https://icanhazip.com',
      'https://1.1.1.1/cdn-cgi/trace', // by IP — no target hostname to resolve
    ];
    for (final url in endpoints) {
      http.Client? c;
      try {
        c = await client(idleTimeout: const Duration(seconds: 10));
        final r =
            await c.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
        if (r.statusCode == 200) {
          final body = r.body.trim();
          // cdn-cgi/trace returns key=value lines; pull ip=.
          if (url.contains('cdn-cgi/trace')) {
            final m = RegExp(r'ip=([0-9a-fA-F:.]+)').firstMatch(body);
            if (m != null) return m.group(1);
          } else if (body.isNotEmpty && body.length < 60) {
            return body;
          }
        }
      } catch (e) {
        appLogger.w('proxy exit-ip check via $url failed: $e');
      } finally {
        c?.close();
      }
    }
    return null;
  }
}
