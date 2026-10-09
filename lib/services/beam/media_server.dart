import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:plezy/utils/app_logger.dart';

import 'beam_http.dart';

/// A single playable entry the on-device server exposes to LAN clients.
///
/// [streamUrl] is the upstream source — a Real-Debrid direct HTTPS link OR a
/// local torrent-stream URL (e.g. http://127.0.0.1:xxxx/...). LAN clients never
/// see this URL; they fetch `/stream/<id>` and the server proxies to it.
class MediaItem {
  MediaItem({
    required this.id,
    required this.title,
    required this.streamUrl,
    this.mimeType = 'video/mp4',
    this.sizeBytes,
    this.posterUrl,
    this.durationMs,
  });

  final String id;
  final String title;
  String streamUrl; // mutable so the adaptive controller can swap it
  final String mimeType;
  final int? sizeBytes;
  final String? posterUrl;
  final int? durationMs;

  bool get _isLocal {
    final u = Uri.tryParse(streamUrl);
    final h = u?.host ?? '';
    return h == '127.0.0.1' || h == 'localhost' || h == '0.0.0.0';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'mimeType': mimeType,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        if (posterUrl != null) 'posterUrl': posterUrl,
        if (durationMs != null) 'durationMs': durationMs,
      };
}

/// Lightweight on-device media server so OTHER LAN devices (TVs, phones) can
/// browse + play what this app has stream URLs for. Full Plex Media Server
/// can't run on 32-bit Android, so this implements a tiny HTTP index, a
/// range-aware streaming proxy, and a minimal DLNA/UPnP presence (device
/// description + SSDP responder) so DLNA browsers discover the device.
///
/// This server is LAN-facing and must NOT be reached through the SOCKS proxy.
/// The UPSTREAM fetch inside `/stream` DOES go proxy-aware for RD links
/// (BeamHttp.client) and direct for localhost torrent URLs
/// (BeamHttp.directClient).
class BeamMediaServer {
  BeamMediaServer({this.port = 32469});

  int port;
  static const String _uuid = 'uuid:beam-plezy-0001-0001-0001-000000000001';

  HttpServer? _http;
  RawDatagramSocket? _ssdp;
  final Map<String, MediaItem> _catalog = {};
  String? _lanIp;

  /// Called periodically while serving `/stream/<id>` with the measured
  /// delivery rate. A higher-level controller can use this to decide to swap
  /// an item to a lower-bitrate source via [swapStreamUrl].
  void Function(String itemId, int clientDownRateBytesPerSec)? onClientRate;

  // ---- catalog -------------------------------------------------------------

  void addItem(MediaItem item) => _catalog[item.id] = item;
  void removeItem(String id) => _catalog.remove(id);
  void clear() => _catalog.clear();

  /// Point an item at a new (e.g. lower-bitrate) upstream URL mid-session.
  /// Subsequent range requests use the new URL; in-flight pipes finish on the
  /// old one until the client issues its next range request.
  void swapStreamUrl(String itemId, String newUrl) {
    final it = _catalog[itemId];
    if (it == null) {
      appLogger.w('swapStreamUrl: unknown item $itemId');
      return;
    }
    it.streamUrl = newUrl;
    appLogger.i('swapStreamUrl: $itemId -> $newUrl');
  }

  // ---- lifecycle -----------------------------------------------------------

  String get baseUrl => 'http://${_lanIp ?? '0.0.0.0'}:$port';

  Future<void> start() async {
    _lanIp = await _findLanIp();
    _http = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _http!.listen(_handle, onError: (Object e) => appLogger.w('http err: $e'));
    appLogger.i('BeamMediaServer listening on $baseUrl');
    await _startSsdp();
  }

  Future<void> stop() async {
    try {
      _ssdp?.close();
    } catch (_) {}
    _ssdp = null;
    try {
      await _http?.close(force: true);
    } catch (_) {}
    _http = null;
    appLogger.i('BeamMediaServer stopped');
  }

  // ---- request routing -----------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Server', 'Plezy-BeamMediaServer/1.0 DLNADOC/1.50 UPnP/1.0');
    try {
      final segs = req.uri.pathSegments;
      if (segs.isEmpty) {
        await _index(req);
      } else if (segs.length == 2 && segs[0] == 'item') {
        _itemMeta(req, segs[1]);
      } else if (segs.length == 2 && segs[0] == 'stream') {
        await _stream(req, segs[1]);
      } else if (segs.length == 2 && segs[0] == 'dlna' &&
          segs[1] == 'description.xml') {
        _dlnaDescription(req);
      } else {
        res.statusCode = HttpStatus.notFound;
        await res.close();
      }
    } catch (e) {
      appLogger.w('handle ${req.uri}: $e');
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _index(HttpRequest req) async {
    final res = req.response;
    final wantsJson =
        (req.headers.value('accept') ?? '').contains('application/json') ||
            req.uri.queryParameters['format'] == 'json';
    if (wantsJson) {
      res.headers.contentType = ContentType('application', 'json');
      res.write(jsonEncode({
        'server': 'plezy-beam',
        'items': _catalog.values.map((i) => {
              ...i.toJson(),
              'stream': '$baseUrl/stream/${i.id}',
            }).toList(),
      }));
    } else {
      res.headers.contentType = ContentType.html;
      final rows = _catalog.values
          .map((i) => '<li><a href="/stream/${i.id}">${_esc(i.title)}</a></li>')
          .join();
      res.write('<!doctype html><html><head><meta charset="utf-8">'
          '<title>Plezy Beam</title></head><body>'
          '<h1>Plezy Beam Library</h1><ul>$rows</ul></body></html>');
    }
    await res.close();
  }

  void _itemMeta(HttpRequest req, String id) {
    final res = req.response;
    final it = _catalog[id];
    if (it == null) {
      res.statusCode = HttpStatus.notFound;
      res.close();
      return;
    }
    res.headers.contentType = ContentType('application', 'json');
    res.write(jsonEncode({
      ...it.toJson(),
      'stream': '$baseUrl/stream/${it.id}',
    }));
    res.close();
  }

  // ---- ranged streaming proxy ---------------------------------------------

  /// Proxies `/stream/<id>` to the item's upstream URL. HTTP Range support is
  /// the priority: we parse the client's `Range: bytes=start-end`, forward an
  /// equivalent range to the upstream, and reply 206 Partial Content with a
  /// `Content-Range` header, piping the upstream body straight to the client.
  /// A no-range request replies 200 and forwards the full body. Client
  /// disconnects are caught and abort the upstream leg so we don't leak it.
  Future<void> _stream(HttpRequest req, String id) async {
    final res = req.response;
    final it = _catalog[id];
    if (it == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }

    // Parse "bytes=start-end". end may be empty (open-ended).
    int? start;
    int? end;
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final spec = rangeHeader.substring(6).split('-');
      if (spec.isNotEmpty && spec[0].isNotEmpty) start = int.tryParse(spec[0]);
      if (spec.length > 1 && spec[1].isNotEmpty) end = int.tryParse(spec[1]);
    }

    // Upstream client: proxy-aware for remote (RD), direct for localhost.
    final http.Client client =
        it._isLocal ? BeamHttp.directClient() : await BeamHttp.client();
    http.StreamedResponse? up;
    StreamSubscription<List<int>>? sub;
    final completer = Completer<void>();
    try {
      final upReq = http.Request('GET', Uri.parse(it.streamUrl));
      if (start != null || end != null) {
        final s = start ?? 0;
        upReq.headers[HttpHeaders.rangeHeader] =
            'bytes=$s-${end?.toString() ?? ''}';
      }
      up = await client.send(upReq);

      final upStatus = up.statusCode;
      if (upStatus >= 400) {
        res.statusCode = upStatus;
        await res.close();
        return;
      }

      // Total size: prefer upstream Content-Range total, else Content-Length.
      final totalBytes = _upstreamTotal(up) ?? it.sizeBytes;
      final contentLen = up.contentLength;

      res.headers.contentType = ContentType.parse(it.mimeType);
      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      final ranged = start != null || end != null || upStatus == 206;
      if (ranged) {
        final s = start ?? 0;
        // Prefer upstream's own Content-Range if it echoed one.
        final upCr = up.headers[HttpHeaders.contentRangeHeader.toLowerCase()];
        if (upCr != null) {
          res.headers.set(HttpHeaders.contentRangeHeader, upCr);
        } else {
          final e = end ?? (totalBytes != null ? totalBytes - 1 : null);
          final t = totalBytes?.toString() ?? '*';
          res.headers
              .set(HttpHeaders.contentRangeHeader, 'bytes $s-${e ?? ''}/$t');
        }
        res.statusCode = HttpStatus.partialContent; // 206
      } else {
        res.statusCode = HttpStatus.ok; // 200
      }
      if (contentLen != null && contentLen > 0) {
        res.headers.set(HttpHeaders.contentLengthHeader, contentLen);
      }

      // Pipe upstream -> client, sampling the delivery rate for onClientRate.
      var sent = 0;
      var window = 0;
      final sw = Stopwatch()..start();
      sub = up.stream.listen(
        (chunk) {
          res.add(chunk);
          sent += chunk.length;
          window += chunk.length;
          if (sw.elapsedMilliseconds >= 1000) {
            final rate =
                (window * 1000 / sw.elapsedMilliseconds).round();
            try {
              onClientRate?.call(id, rate);
            } catch (e) {
              appLogger.w('onClientRate cb: $e');
            }
            window = 0;
            sw.reset();
          }
        },
        onError: (Object e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: true,
      );

      await completer.future;
      await res.flush();
      await res.close();
      appLogger.d('stream $id done ($sent bytes)');
    } catch (e) {
      // Most commonly the LAN client seeked/closed the socket. Abort upstream.
      appLogger.d('stream $id aborted: $e');
      try {
        await sub?.cancel();
      } catch (_) {}
      try {
        await res.close();
      } catch (_) {}
    } finally {
      // Closing the client aborts any in-flight upstream connection.
      client.close();
    }
  }

  int? _upstreamTotal(http.StreamedResponse up) {
    final cr = up.headers[HttpHeaders.contentRangeHeader.toLowerCase()];
    if (cr != null) {
      final slash = cr.lastIndexOf('/');
      if (slash >= 0) {
        final t = cr.substring(slash + 1).trim();
        if (t != '*') return int.tryParse(t);
      }
    }
    return null;
  }

  // ---- DLNA / UPnP ---------------------------------------------------------

  /// Minimal but REAL UPnP MediaServer device description. Enough for DLNA
  /// browsers to recognize the device and its friendly name. The embedded
  /// ContentDirectory/ConnectionManager SCPD URLs are declared but NOT
  /// implemented (SOAP browsing is stubbed) — clients that only need presence
  /// + a friendly name see the device; full SOAP Browse() is future work.
  void _dlnaDescription(HttpRequest req) {
    final res = req.response;
    res.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
    res.write('<?xml version="1.0" encoding="utf-8"?>'
        '<root xmlns="urn:schemas-upnp-org:device-1-0">'
        '<specVersion><major>1</major><minor>0</minor></specVersion>'
        '<device>'
        '<deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>'
        '<friendlyName>Plezy Beam</friendlyName>'
        '<manufacturer>Plezy</manufacturer>'
        '<modelName>BeamMediaServer</modelName>'
        '<UDN>$_uuid</UDN>'
        // NOTE: SOAP ContentDirectory Browse() is STUBBED. These service
        // entries advertise the type; the control/SCPD endpoints are not
        // served yet. Clients relying on the HTTP index (/) still work.
        '<serviceList>'
        '<service>'
        '<serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>'
        '<serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>'
        '<SCPDURL>/dlna/ContentDirectory.xml</SCPDURL>'
        '<controlURL>/dlna/control/ContentDirectory</controlURL>'
        '<eventSubURL>/dlna/event/ContentDirectory</eventSubURL>'
        '</service>'
        '</serviceList>'
        '</device>'
        '</root>');
    res.close();
  }

  // ---- SSDP discovery ------------------------------------------------------

  static final InternetAddress _ssdpAddr = InternetAddress('239.255.255.250');
  static const int _ssdpPort = 1900;

  /// Minimal SSDP responder. REAL parts: binds the 1900 UDP socket, joins the
  /// 239.255.255.250 multicast group, sends initial NOTIFY alive announcements,
  /// and unicasts a proper HTTP/1.1 200 OK response to M-SEARCH requests whose
  /// ST matches MediaServer / rootdevice / ssdp:all. STUBBED: periodic re-NOTIFY
  /// refresh and byebye-on-stop are omitted (single announce burst at start).
  Future<void> _startSsdp() async {
    try {
      _ssdp = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, _ssdpPort,
          reuseAddress: true, reusePort: false);
      _ssdp!.broadcastEnabled = true;
      try {
        _ssdp!.joinMulticast(_ssdpAddr);
      } catch (e) {
        appLogger.w('ssdp joinMulticast: $e');
      }
      _ssdp!.listen(_onSsdp, onError: (Object e) => appLogger.w('ssdp: $e'));
      _sendNotifyAlive();
      appLogger.i('SSDP responder up on :$_ssdpPort');
    } catch (e) {
      appLogger.w('SSDP bind failed (discovery disabled): $e');
      _ssdp = null;
    }
  }

  void _onSsdp(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _ssdp?.receive();
    if (dg == null) return;
    final msg = utf8.decode(dg.data, allowMalformed: true);
    if (!msg.startsWith('M-SEARCH')) return;
    final lower = msg.toLowerCase();
    if (!(lower.contains('ssdp:all') ||
        lower.contains('upnp:rootdevice') ||
        lower.contains('device:mediaserver') ||
        lower.contains('mediaserver:1'))) {
      return;
    }
    final loc = '$baseUrl/dlna/description.xml';
    final resp = 'HTTP/1.1 200 OK\r\n'
        'CACHE-CONTROL: max-age=1800\r\n'
        'EXT:\r\n'
        'LOCATION: $loc\r\n'
        'SERVER: Plezy/1.0 UPnP/1.0 BeamMediaServer/1.0\r\n'
        'ST: urn:schemas-upnp-org:device:MediaServer:1\r\n'
        'USN: $_uuid::urn:schemas-upnp-org:device:MediaServer:1\r\n'
        '\r\n';
    try {
      _ssdp?.send(utf8.encode(resp), dg.address, dg.port);
    } catch (e) {
      appLogger.w('ssdp reply: $e');
    }
  }

  void _sendNotifyAlive() {
    final loc = '$baseUrl/dlna/description.xml';
    final notify = 'NOTIFY * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'CACHE-CONTROL: max-age=1800\r\n'
        'LOCATION: $loc\r\n'
        'NT: urn:schemas-upnp-org:device:MediaServer:1\r\n'
        'NTS: ssdp:alive\r\n'
        'SERVER: Plezy/1.0 UPnP/1.0 BeamMediaServer/1.0\r\n'
        'USN: $_uuid::urn:schemas-upnp-org:device:MediaServer:1\r\n'
        '\r\n';
    try {
      _ssdp?.send(utf8.encode(notify), _ssdpAddr, _ssdpPort);
    } catch (e) {
      appLogger.w('ssdp notify: $e');
    }
  }

  // ---- helpers -------------------------------------------------------------

  Future<String?> _findLanIp() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      // Prefer a private RFC1918 address (the actual LAN NIC).
      for (final ni in ifaces) {
        for (final a in ni.addresses) {
          final ip = a.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              _is172Private(ip)) {
            return ip;
          }
        }
      }
      // Fallback: first non-loopback IPv4.
      for (final ni in ifaces) {
        for (final a in ni.addresses) {
          if (!a.isLoopback) return a.address;
        }
      }
    } catch (e) {
      appLogger.w('LAN IP lookup failed: $e');
    }
    return null;
  }

  bool _is172Private(String ip) {
    if (!ip.startsWith('172.')) return false;
    final parts = ip.split('.');
    if (parts.length < 2) return false;
    final second = int.tryParse(parts[1]) ?? 0;
    return second >= 16 && second <= 31;
  }

  String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
