import 'dart:async';

import 'package:flutter/material.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';

import '../../../services/beam/beam_community_vpn.dart';
import '../../../services/beam/beam_config.dart';

/// Connect the app's OWN free community VPN (VPN Gate over OpenVPN) so torrent
/// indexers/trackers resolve and the swarm connects even when the phone's other
/// VPN censors them. Honest about the Android one-VPN limit: turning this on
/// replaces whatever VPN is currently active.
class BeamCommunityVpnScreen extends StatefulWidget {
  const BeamCommunityVpnScreen({super.key});

  @override
  State<BeamCommunityVpnScreen> createState() => _BeamCommunityVpnScreenState();
}

class _BeamCommunityVpnScreenState extends State<BeamCommunityVpnScreen> {
  final _vpn = BeamCommunityVpn.instance;
  StreamSubscription<VPNStage>? _sub;
  VPNStage _stage = VPNStage.disconnected;
  bool _busy = false;
  String? _error;
  bool _auto = false;

  @override
  void initState() {
    super.initState();
    _auto = BeamConfig.autoCommunityVpn;
    _stage = _vpn.stage;
    _sub = _vpn.stageStream.listen((s) {
      if (mounted) setState(() => _stage = s);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final server = await _vpn.connectBest();
      if (!mounted) return;
      if (server == null) {
        setState(() => _error =
            'No community server would connect. Tap Connect to retry, or turn '
            'off your other VPN first (only one VPN can run at a time).');
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    await _vpn.disconnect();
    if (mounted) setState(() => _busy = false);
  }

  bool get _connected => _stage == VPNStage.connected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final server = _vpn.currentServer;
    return Scaffold(
      appBar: AppBar(title: const Text('Free community VPN')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Icon(
            _connected ? Icons.verified_user_rounded : Icons.public_rounded,
            size: 64,
            color: _connected ? Colors.green : theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              _connected
                  ? 'Connected'
                  : _busy
                      ? _stageLabel(_stage)
                      : 'Not connected',
              style: theme.textTheme.titleLarge,
            ),
          ),
          if (_connected && server != null) ...[
            const SizedBox(height: 4),
            Center(
              child: Text(server.label,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy
                ? null
                : (_connected ? _disconnect : _connect),
            icon: Icon(_connected ? Icons.link_off_rounded : Icons.bolt_rounded),
            label: Text(_connected ? 'Disconnect' : 'Connect'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
          if (_busy && !_connected) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.autorenew_rounded),
            title: const Text('Auto-connect before searching'),
            subtitle: const Text(
              'Only needed if trackers still fail. Beam already resolves '
              'indexers via secure DNS (1.1.1.1) through your existing VPN, so '
              'you normally keep Surfshark on. When on, this connects the '
              'community VPN before a search — but only if no other VPN is up '
              '(Android allows just one).',
            ),
            value: _auto,
            onChanged: (v) async {
              await BeamConfig.setAutoCommunityVpn(v);
              if (mounted) setState(() => _auto = v);
            },
          ),
          const SizedBox(height: 12),
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.info_outline_rounded, size: 20),
                    const SizedBox(width: 8),
                    Text('How this works',
                        style: theme.textTheme.titleSmall),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    'This routes the app through a free community VPN (VPN Gate) '
                    'that does not block torrent indexers or the peer swarm — so '
                    'search and streaming work where a filtering VPN fails.\n\n'
                    'Android only allows one VPN at a time, so turning this on '
                    'replaces any other VPN you have running (e.g. Surfshark). '
                    'Free servers are volunteer-run and can be slow or drop; '
                    'Connect just grabs a fresh fast one.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _stageLabel(VPNStage s) {
    switch (s) {
      case VPNStage.connecting:
      case VPNStage.prepare:
      case VPNStage.authenticating:
      case VPNStage.wait_connection:
      case VPNStage.vpn_generate_config:
      case VPNStage.get_config:
      case VPNStage.tcp_connect:
      case VPNStage.udp_connect:
      case VPNStage.assign_ip:
      case VPNStage.resolve:
        return 'Connecting…';
      case VPNStage.connected:
        return 'Connected';
      case VPNStage.disconnected:
      case VPNStage.disconnecting:
        return 'Disconnected';
      default:
        return 'Connecting…';
    }
  }
}
