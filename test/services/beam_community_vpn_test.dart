import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';
import 'package:plezy/services/beam/beam_community_vpn.dart';

class _Engine extends OpenVPN {
  int starts = 0;
  int stops = 0;
  final started = Completer<void>();

  @override
  Future<void> connect(
    String config,
    String name, {
    String? username,
    String? password,
    List<String>? bypassPackages,
    bool certIsRequired = false,
  }) async {
    starts++;
    if (!started.isCompleted) started.complete();
  }

  @override
  void disconnect() => stops++;
}

class _Vpn extends BeamCommunityVpn {
  _Vpn(super.engine) : super.forTesting();
  final servers = Completer<List<CommunityVpnServer>>();

  @override
  Future<List<CommunityVpnServer>> fetchServers({String? preferCountry}) => servers.future;
}

CommunityVpnServer server() => CommunityVpnServer(
  hostName: 'test',
  ip: '192.0.2.1',
  country: 'Test',
  countryShort: 'XX',
  speedBps: 1000000,
  pingMs: 1,
  ovpnConfig: 'remote 192.0.2.1',
);

void main() {
  test('cancel while fetching servers prevents a late VPN start', () async {
    final engine = _Engine();
    final vpn = _Vpn(engine);
    final cancel = Completer<void>();
    final result = vpn.connectBest(cancelled: cancel.future);
    cancel.complete();
    await Future<void>.delayed(Duration.zero);
    vpn.servers.complete([server()]);
    expect(await result, isNull);
    expect(engine.starts, 0);
  });

  test('cancel during handshake stops it and prevents server rotation', () async {
    final engine = _Engine();
    final vpn = _Vpn(engine);
    vpn.servers.complete([server(), server()]);
    final cancel = Completer<void>();
    final result = vpn.connectBest(cancelled: cancel.future);
    await engine.started.future;
    cancel.complete();
    expect(await result, isNull);
    expect(engine.starts, 1);
    expect(engine.stops, 1);
  });

  test('late cancellation cannot disconnect a newer attempt', () async {
    final engine = _Engine();
    final vpn = _Vpn(engine);
    final oldCancel = Completer<void>();
    final old = vpn.connect(server(), cancelled: oldCancel.future);
    await engine.started.future;
    await vpn.disconnect();
    expect(await old, isFalse);
    final newCancel = Completer<void>();
    final next = vpn.connect(server(), cancelled: newCancel.future);
    oldCancel.complete();
    await Future<void>.delayed(Duration.zero);
    expect(engine.stops, 1);
    newCancel.complete();
    expect(await next, isFalse);
    expect(engine.stops, 2);
  });
}
