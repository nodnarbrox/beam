import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:plezy/utils/app_logger.dart';

/// The result of a successful port-forward attempt.
///
/// [externalIp] is the gateway-reported WAN address (may be null if the router
/// didn't hand one back on NAT-PMP; UPnP fills it via GetExternalIPAddress).
/// [externalPort] is what a remote peer dials; [internalPort] is the on-device
/// listener. [method] is 'natpmp' or 'upnp'.
class PortMapping {
  PortMapping({
    required this.externalPort,
    required this.internalPort,
    required this.protocol,
    required this.method,
    required this.lifetime,
    this.externalIp,
    this.controlUrl,
    this.serviceType,
    this.gateway,
  });

  final String? externalIp;
  final int externalPort;
  final int internalPort;
  final String protocol; // 'TCP' | 'UDP'
  final String method; // 'natpmp' | 'upnp'
  final int lifetime; // seconds
  final String? controlUrl; // UPnP: full URL used to (re)issue SOAP
  final String? serviceType; // UPnP: WANIPConnection service type
  final InternetAddress? gateway; // NAT-PMP: gateway we mapped through

  @override
  String toString() =>
      'PortMapping($method $protocol ${externalIp ?? '?'}:$externalPort -> :$internalPort, ${lifetime}s)';
}

/// Automatic NAT traversal / port-forwarding in pure Dart — zero user router
/// setup. Tries NAT-PMP (fast, RFC 6886) first, then UPnP-IGD (SSDP + SOAP).
/// PCP (RFC 6887) is stubbed — see [_pcpMap]. Everything is best-effort with
/// tight timeouts; on failure [lastDiagnostic] carries a human-readable reason
/// so a higher layer can decide to fall back to a relay.
class PortForwardService {
  PortForwardService({this.timeout = const Duration(seconds: 4)});

  final Duration timeout;

  /// Last human-readable reason for a failure / notable condition.
  String? lastDiagnostic;

  static const _ssdpAddr = '239.255.255.250';
  static const _ssdpPort = 1900;
  static const _natPmpPort = 5351;
  static const _ipEcho = 'https://api.ipify.org';

  String? _upnpServiceType; // cached so close/renew can reuse discovery

  // --- Public API -----------------------------------------------------------

  Future<PortMapping?> openPort({
    required int internalPort,
    int? externalPort,
    String protocol = 'TCP',
    int lifetimeSeconds = 3600,
    String description = 'MediaBeam',
  }) async {
    lastDiagnostic = null;
    final ext = externalPort ?? internalPort;
    try {
      final m = await _natPmpMap(internalPort, ext, protocol, lifetimeSeconds);
      if (m != null) {
        appLogger.i('Port opened via NAT-PMP: $m');
        return m;
      }
    } catch (e) {
      appLogger.d('NAT-PMP map failed: $e');
    }
    try {
      final m = await _upnpMap(internalPort, ext, protocol, lifetimeSeconds, description);
      if (m != null) {
        appLogger.i('Port opened via UPnP-IGD: $m');
        return m;
      }
    } catch (e) {
      appLogger.d('UPnP map failed: $e');
    }
    lastDiagnostic ??= 'No NAT-PMP or UPnP-IGD gateway responded; router likely '
        'has UPnP/NAT-PMP disabled or is CGNAT — fall back to a relay.';
    appLogger.w('openPort failed: $lastDiagnostic');
    return null;
  }

  Future<void> closePort(PortMapping m) async {
    try {
      if (m.method == 'natpmp' && m.gateway != null) {
        // Delete a NAT-PMP mapping == map with external 0 & lifetime 0.
        await _natPmpRequest(m.gateway!, m.protocol, m.internalPort, 0, 0);
      } else if (m.method == 'upnp' && m.controlUrl != null) {
        await _upnpSoap(
          m.controlUrl!,
          m.serviceType ?? _upnpServiceType ?? 'urn:schemas-upnp-org:service:WANIPConnection:1',
          'DeletePortMapping',
          '<NewRemoteHost></NewRemoteHost>'
              '<NewExternalPort>${m.externalPort}</NewExternalPort>'
              '<NewProtocol>${m.protocol}</NewProtocol>',
        );
      }
      appLogger.i('Closed mapping $m');
    } catch (e) {
      appLogger.w('closePort failed for $m: $e');
    }
  }

  /// Re-open the same mapping to reset its lifetime. Mappings expire; a caller
  /// should invoke this on a timer at ~half the lifetime.
  Future<void> renew(PortMapping m) => openPort(
        internalPort: m.internalPort,
        externalPort: m.externalPort,
        protocol: m.protocol,
        lifetimeSeconds: m.lifetime,
      );

  /// The WAN address the gateway believes it has, via UPnP GetExternalIPAddress
  /// or NAT-PMP. Falls back to an HTTP ip-echo — but that observed IP is what
  /// the echo server saw, NOT necessarily an address you can map a port on.
  Future<String?> externalIp() async {
    try {
      final ep = await _discoverUpnp();
      if (ep != null) {
        final ip = _extractTag(await _upnpSoap(ep.$1, ep.$2, 'GetExternalIPAddress', ''), 'NewExternalIPAddress');
        if (ip != null && ip.isNotEmpty) return ip;
      }
    } catch (e) {
      appLogger.d('UPnP GetExternalIPAddress failed: $e');
    }
    try {
      final gw = await defaultGateway();
      if (gw != null) {
        final ip = await _natPmpExternalIp(gw);
        if (ip != null) return ip;
      }
    } catch (e) {
      appLogger.d('NAT-PMP external IP failed: $e');
    }
    try {
      final r = await http.get(Uri.parse(_ipEcho)).timeout(timeout);
      if (r.statusCode == 200) {
        lastDiagnostic = 'externalIp is HTTP-observed ($_ipEcho), not necessarily '
            'a mappable/reachable address.';
        return r.body.trim();
      }
    } catch (e) {
      appLogger.d('ip-echo failed: $e');
    }
    return null;
  }

  /// True when the gateway's WAN address is private/CGNAT, OR differs from the
  /// public ip-echo (another NAT sits above us). Either way an opened port won't
  /// be publicly reachable and a relay is required.
  Future<bool> isBehindCgnat() async {
    String? gwIp;
    try {
      final ep = await _discoverUpnp();
      if (ep != null) {
        gwIp = _extractTag(await _upnpSoap(ep.$1, ep.$2, 'GetExternalIPAddress', ''), 'NewExternalIPAddress');
      }
      if (gwIp == null) {
        final gw = await defaultGateway();
        gwIp = gw == null ? null : await _natPmpExternalIp(gw);
      }
    } catch (_) {}
    if (gwIp != null && _isPrivateOrCgnat(gwIp)) {
      lastDiagnostic = 'Gateway WAN address $gwIp is RFC1918/CGNAT — not publicly reachable; use a relay.';
      return true;
    }
    String? echoIp;
    try {
      final r = await http.get(Uri.parse(_ipEcho)).timeout(timeout);
      if (r.statusCode == 200) echoIp = r.body.trim();
    } catch (_) {}
    if (gwIp != null && echoIp != null && gwIp != echoIp) {
      lastDiagnostic = 'Gateway WAN ($gwIp) differs from public IP ($echoIp) — carrier NAT above router; use a relay.';
      return true;
    }
    if (echoIp != null && _isPrivateOrCgnat(echoIp)) {
      lastDiagnostic = 'Public-observed IP $echoIp is CGNAT — use a relay.';
      return true;
    }
    return false;
  }

  /// Best-effort default gateway. Android has no public routing-table API, so we
  /// derive it from the device's own LAN IPv4 by replacing the host octet with
  /// `.1` (near-universal consumer-router convention). This is a HEURISTIC — the
  /// SSDP-discovered UPnP location host is preferred and authoritative when
  /// available; NAT-PMP callers should treat this as a guess.
  Future<InternetAddress?> defaultGateway() async {
    try {
      final ifaces = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback || !_isPrivate(addr.address)) continue;
          final p = addr.address.split('.');
          if (p.length == 4) return InternetAddress('${p[0]}.${p[1]}.${p[2]}.1');
        }
      }
    } catch (e) {
      appLogger.d('defaultGateway derivation failed: $e');
    }
    return null;
  }

  // --- NAT-PMP (RFC 6886) ---------------------------------------------------
  //
  // MAP request (12 bytes) to gateway:5351 —
  //   [0]     version = 0
  //   [1]     opcode  = 1 (map UDP) | 2 (map TCP)
  //   [2..3]  reserved = 0
  //   [4..5]  internal port           (big-endian u16)
  //   [6..7]  suggested external port  (big-endian u16)
  //   [8..11] requested lifetime secs  (big-endian u32)
  // MAP response (16 bytes) —
  //   [0] version=0  [1] opcode+128 (129/130)  [2..3] result (u16, 0=ok)
  //   [4..7] epoch secs (u32)  [8..9] internal port  [10..11] mapped ext port
  //   [12..15] granted lifetime secs (u32)
  // External-address request (2 bytes): version=0, opcode=0.
  // Response (12 bytes): [0]=0 [1]=128 [2..3]=result [4..7]=epoch [8..11]=IPv4.

  Future<PortMapping?> _natPmpMap(int internal, int external, String protocol, int lifetime) async {
    final gw = await defaultGateway();
    if (gw == null) {
      lastDiagnostic = 'Could not determine default gateway for NAT-PMP.';
      return null;
    }
    final resp = await _natPmpRequest(gw, protocol, internal, external, lifetime);
    if (resp == null) return null;
    final result = (resp[2] << 8) | resp[3];
    if (result != 0) {
      lastDiagnostic = 'NAT-PMP result code $result (non-zero = refused).';
      return null;
    }
    final mappedExt = (resp[10] << 8) | resp[11];
    return PortMapping(
      externalIp: await _natPmpExternalIp(gw),
      externalPort: mappedExt,
      internalPort: internal,
      protocol: protocol.toUpperCase(),
      method: 'natpmp',
      lifetime: _u32(resp, 12),
      gateway: gw,
    );
  }

  /// Sends a MAP (opcode 1/2) request; returns the raw 16-byte response.
  Future<Uint8List?> _natPmpRequest(InternetAddress gw, String protocol, int internal, int external, int lifetime) {
    final opcode = protocol.toUpperCase() == 'UDP' ? 1 : 2;
    final req = Uint8List(12);
    req[0] = 0; // version
    req[1] = opcode;
    req[4] = (internal >> 8) & 0xff;
    req[5] = internal & 0xff;
    req[6] = (external >> 8) & 0xff;
    req[7] = external & 0xff;
    req[8] = (lifetime >> 24) & 0xff;
    req[9] = (lifetime >> 16) & 0xff;
    req[10] = (lifetime >> 8) & 0xff;
    req[11] = lifetime & 0xff;
    return _natPmpSend(gw, req, expectOpcode: opcode + 128);
  }

  Future<String?> _natPmpExternalIp(InternetAddress gw) async {
    final resp = await _natPmpSend(gw, Uint8List(2), expectOpcode: 128); // v=0, op=0
    if (resp == null || resp.length < 12) return null;
    if (((resp[2] << 8) | resp[3]) != 0) return null;
    return '${resp[8]}.${resp[9]}.${resp[10]}.${resp[11]}';
  }

  Future<Uint8List?> _natPmpSend(InternetAddress gw, Uint8List req, {required int expectOpcode}) async {
    RawDatagramSocket? sock;
    final completer = Completer<Uint8List?>();
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = sock!.receive();
        if (dg == null) return;
        final data = dg.data;
        if (data.length >= 4 && data[1] == expectOpcode && !completer.isCompleted) {
          completer.complete(Uint8List.fromList(data));
        }
      });
      sock.send(req, gw, _natPmpPort);
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } catch (e) {
      appLogger.d('NAT-PMP send error: $e');
      return null;
    } finally {
      sock?.close();
    }
  }

  // --- PCP (RFC 6887) — STUBBED ---------------------------------------------
  //
  // PCP shares :5351 and is a superset of NAT-PMP. A MAP request is a 24-byte
  // header (version=2, opcode=1, lifetime u32, 128-bit client IP) + a 36-byte
  // MAP payload (12-byte nonce, protocol, 3 reserved, internal port, suggested
  // external port, 128-bit suggested external IP). Filling the client-IP/nonce
  // fields and handling EPOCH/error result codes correctly is non-trivial; since
  // virtually every PCP-capable gateway also answers NAT-PMP, we prefer NAT-PMP
  // and leave PCP unimplemented.
  // ignore: unused_element
  Future<PortMapping?> _pcpMap(int internal, int external, String protocol, int lifetime) async {
    lastDiagnostic = 'PCP (RFC 6887) not implemented — using NAT-PMP.';
    return null;
  }

  // --- UPnP-IGD (SSDP + SOAP) -----------------------------------------------

  Future<PortMapping?> _upnpMap(int internal, int external, String protocol, int lifetime, String description) async {
    final ep = await _discoverUpnp();
    if (ep == null) {
      lastDiagnostic ??= 'No UPnP InternetGatewayDevice discovered via SSDP.';
      return null;
    }
    final (controlUrl, serviceType, lanIp) = ep;
    final body = '<NewRemoteHost></NewRemoteHost>'
        '<NewExternalPort>$external</NewExternalPort>'
        '<NewProtocol>${protocol.toUpperCase()}</NewProtocol>'
        '<NewInternalPort>$internal</NewInternalPort>'
        '<NewInternalClient>$lanIp</NewInternalClient>'
        '<NewEnabled>1</NewEnabled>'
        '<NewPortMappingDescription>${_xmlEscape(description)}</NewPortMappingDescription>'
        '<NewLeaseDuration>$lifetime</NewLeaseDuration>';
    final resp = await _upnpSoap(controlUrl, serviceType, 'AddPortMapping', body);
    if (resp == null) {
      lastDiagnostic ??= 'AddPortMapping got no/invalid response.';
      return null;
    }
    if (resp.contains('errorCode')) {
      lastDiagnostic = 'AddPortMapping SOAP fault: ${_extractTag(resp, 'errorCode') ?? resp}';
      return null;
    }
    String? extIp;
    try {
      extIp = _extractTag(await _upnpSoap(controlUrl, serviceType, 'GetExternalIPAddress', ''), 'NewExternalIPAddress');
    } catch (_) {}
    return PortMapping(
      externalIp: extIp,
      externalPort: external,
      internalPort: internal,
      protocol: protocol.toUpperCase(),
      method: 'upnp',
      lifetime: lifetime,
      controlUrl: controlUrl,
      serviceType: serviceType,
    );
  }

  /// Returns (controlUrl, serviceType, ourLanIp) for the WAN connection service.
  Future<(String, String, String)?> _discoverUpnp() async {
    final location = await _ssdpSearch();
    if (location == null) return null;
    final locUri = Uri.tryParse(location);
    if (locUri == null) return null;
    String descXml;
    try {
      final r = await http.get(locUri).timeout(timeout);
      if (r.statusCode != 200) return null;
      descXml = r.body;
    } catch (e) {
      appLogger.d('Fetch device description failed: $e');
      return null;
    }
    // Regex the WANIPConnection/WANPPPConnection <service> block for controlURL.
    final svc = _findWanService(descXml);
    if (svc == null) {
      lastDiagnostic = 'IGD device description has no WANIP/WANPPPConnection service.';
      return null;
    }
    final (serviceType, controlPath) = svc;
    // controlURL may be relative → resolve against URLBase or the location origin.
    final base = _extractTag(descXml, 'URLBase') ?? '${locUri.scheme}://${locUri.host}:${locUri.port}';
    final controlUrl = Uri.parse(base).resolve(controlPath).toString();
    _upnpServiceType = serviceType;
    return (controlUrl, serviceType, await _lanIpToward(locUri.host) ?? '');
  }

  /// SSDP M-SEARCH for an InternetGatewayDevice; returns the LOCATION header.
  Future<String?> _ssdpSearch() async {
    RawDatagramSocket? sock;
    final completer = Completer<String?>();
    const target = 'urn:schemas-upnp-org:device:InternetGatewayDevice:1';
    final msearch = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $_ssdpAddr:$_ssdpPort\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: $target\r\n\r\n';
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = sock!.receive();
        if (dg == null) return;
        final loc = _extractHeader(utf8.decode(dg.data, allowMalformed: true), 'LOCATION');
        if (loc != null && !completer.isCompleted) completer.complete(loc);
      });
      final bytes = utf8.encode(msearch);
      sock.send(bytes, InternetAddress(_ssdpAddr), _ssdpPort);
      sock.send(bytes, InternetAddress(_ssdpAddr), _ssdpPort); // 2nd burst: lossy Wi-Fi
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } catch (e) {
      appLogger.d('SSDP search error: $e');
      return null;
    } finally {
      sock?.close();
    }
  }

  /// POST a SOAP action to a UPnP control URL; returns the response body or null.
  Future<String?> _upnpSoap(String controlUrl, String serviceType, String action, String innerBody) async {
    final envelope = '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$serviceType">$innerBody</u:$action></s:Body></s:Envelope>';
    try {
      final r = await http.post(
        Uri.parse(controlUrl),
        headers: {
          'Content-Type': 'text/xml; charset="utf-8"',
          'SOAPAction': '"$serviceType#$action"',
          'Connection': 'close',
        },
        body: envelope,
      ).timeout(timeout);
      // 200 = success; 500 carries a SOAP fault we still parse for errorCode.
      if (r.statusCode == 200 || r.statusCode == 500) return r.body;
      appLogger.d('SOAP $action status ${r.statusCode}');
      return r.body.isNotEmpty ? r.body : null;
    } catch (e) {
      appLogger.d('SOAP $action error: $e');
      return null;
    }
  }

  // --- Parsing / helpers (regex-based, no xml package) ----------------------

  /// Extracts the first `<tag>...</tag>` (namespace-agnostic) inner text.
  String? _extractTag(String? xml, String tag) {
    if (xml == null) return null;
    final m = RegExp('<(?:[\\w-]+:)?$tag\\b[^>]*>(.*?)</(?:[\\w-]+:)?$tag>', dotAll: true).firstMatch(xml);
    return m?.group(1)?.trim();
  }

  String? _extractHeader(String httpText, String header) {
    for (final line in httpText.split(RegExp(r'\r?\n'))) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      if (line.substring(0, idx).trim().toUpperCase() == header.toUpperCase()) {
        return line.substring(idx + 1).trim();
      }
    }
    return null;
  }

  /// Finds a WANIPConnection/WANPPPConnection `service` block → (serviceType, controlURL).
  (String, String)? _findWanService(String xml) {
    for (final match in RegExp(r'<service>(.*?)</service>', dotAll: true).allMatches(xml)) {
      final block = match.group(1)!;
      final st = _extractTag(block, 'serviceType');
      if (st == null) continue;
      if (st.contains('WANIPConnection') || st.contains('WANPPPConnection')) {
        final ctrl = _extractTag(block, 'controlURL');
        if (ctrl != null && ctrl.isNotEmpty) return (st, ctrl);
      }
    }
    return null;
  }

  /// Local IPv4 on the same /24 as [gatewayHost] if possible, else first private
  /// IPv4. Used as NewInternalClient in AddPortMapping.
  Future<String?> _lanIpToward(String gatewayHost) async {
    try {
      final gwParts = gatewayHost.split('.');
      final ifaces = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      String? fallback;
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (addr.isLoopback || !_isPrivate(ip)) continue;
          fallback ??= ip;
          final ipParts = ip.split('.');
          if (gwParts.length == 4 &&
              ipParts.length == 4 &&
              ipParts[0] == gwParts[0] &&
              ipParts[1] == gwParts[1] &&
              ipParts[2] == gwParts[2]) {
            return ip;
          }
        }
      }
      return fallback;
    } catch (e) {
      appLogger.d('_lanIpToward failed: $e');
      return null;
    }
  }

  int _u32(List<int> b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  String _xmlEscape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  bool _isPrivate(String ip) {
    final p = ip.split('.');
    if (p.length != 4) return false;
    final a = int.tryParse(p[0]) ?? 0;
    final b = int.tryParse(p[1]) ?? 0;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 169 && b == 254) return true; // link-local
    return false;
  }

  /// RFC1918 private OR RFC6598 CGNAT (100.64.0.0/10).
  bool _isPrivateOrCgnat(String ip) {
    if (_isPrivate(ip)) return true;
    final p = ip.split('.');
    if (p.length != 4) return false;
    final a = int.tryParse(p[0]) ?? 0;
    final b = int.tryParse(p[1]) ?? 0;
    return a == 100 && b >= 64 && b <= 127; // 100.64.0.0/10
  }
}
