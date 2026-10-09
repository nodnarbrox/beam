import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plezy/utils/app_logger.dart';

import '../../../services/beam/beam_config.dart';
import '../../../services/beam/vpn_detect.dart';
import '../../../services/beam/beam_http.dart';
import '../../../services/beam/beam_media_center.dart';
import '../../../services/beam/proxy_profiles.dart';
import 'beam_community_vpn_screen.dart';
import 'proxy_settings_screen.dart';
import 'rclone_settings_screen.dart';
import 'realdebrid_settings_screen.dart';

/// Top-level Beam settings hub. Links to the proxy / Real-Debrid / rclone
/// sub-screens, exposes the two master toggles (proxy on-off, media-server
/// on-off), and shows a live "am I hidden?" proxy status tile.
class BeamSettingsScreen extends StatefulWidget {
  const BeamSettingsScreen({super.key});

  @override
  State<BeamSettingsScreen> createState() => _BeamSettingsScreenState();
}

class _BeamSettingsScreenState extends State<BeamSettingsScreen> {
  bool _loading = true;
  bool _proxyEnabled = false;
  bool _mediaServer = false;
  bool _torrentPlay = true;
  bool _allowCam = false;
  bool _vpnActive = false;
  String? _vpnIface;
  ProxyProfile? _activeProfile;
  SharedPreferences? _prefs;

  // Proxy status check state.
  bool _checking = false;
  String? _exitIp;
  bool _checkFailed = false;

  // The media-server toggle isn't a BeamConfig field (we must not modify that
  // service), so it lives in SharedPreferences directly under this key.
  static const _kMediaServerKey = 'beam_media_server_enabled';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await BeamConfig.init();
      await ProxyProfiles.init();
      _prefs = await SharedPreferences.getInstance();
      final active = await ProxyProfiles.active();
      // Device-VPN status (Surfshark etc.) — this alone permits torrenting.
      final vpnOn = await VpnDetect.isVpnActive();
      final vpnIface = vpnOn ? await VpnDetect.activeInterface() : null;
      if (!mounted) return;
      setState(() {
        _proxyEnabled = BeamConfig.proxyEnabled;
        _mediaServer = _readMediaServerFlag();
        _torrentPlay = BeamConfig.torrentPlayEnabled;
        _allowCam = BeamConfig.allowCamReleases;
        _vpnActive = vpnOn;
        _vpnIface = vpnIface;
        _activeProfile = active;
        _loading = false;
      });
    } catch (e, st) {
      appLogger.e('Beam settings load failed', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Failed to load Beam settings: $e');
    }
  }

  bool _readMediaServerFlag() =>
      BeamMediaCenter.instance.isRunning ||
      (_prefs?.getBool(_kMediaServerKey) ?? false);

  Future<void> _setProxyEnabled(bool on) async {
    setState(() {
      _proxyEnabled = on;
      _exitIp = null;
      _checkFailed = false;
    });
    try {
      if (on) {
        // Enable by selecting the active (or first complete) profile.
        final active = await ProxyProfiles.active();
        if (active != null && active.isComplete) {
          await ProxyProfiles.select(active.id);
        } else {
          await BeamConfig.setProxyEnabled(true);
          if (!mounted) return;
          _snack('Pick a proxy network to actually route traffic.');
        }
      } else {
        await ProxyProfiles.disable();
      }
      if (!mounted) return;
      setState(() => _proxyEnabled = BeamConfig.proxyEnabled);
    } catch (e) {
      appLogger.w('toggle proxy failed: $e');
      _snack('Could not change proxy: $e');
    }
  }

  Future<void> _refreshVpn() async {
    final active = await VpnDetect.isVpnActive();
    final iface = active ? await VpnDetect.activeInterface() : null;
    if (!mounted) return;
    setState(() {
      _vpnActive = active;
      _vpnIface = iface;
    });
    _snack(
      active
          ? 'VPN detected on ${iface ?? 'tunnel'} — torrent streaming allowed'
          : 'No VPN detected — turn on Surfshark to allow torrent streaming',
    );
  }

  Future<void> _setAllowCam(bool on) async {
    setState(() => _allowCam = on);
    await BeamConfig.setAllowCamReleases(on);
    if (!mounted) return;
    _snack(
      on
          ? 'Cam/telesync releases allowed — they still rank last'
          : 'Cam/telesync releases blocked from auto-pick',
    );
  }

  Future<void> _setTorrentPlay(bool on) async {
    setState(() => _torrentPlay = on);
    await BeamConfig.setTorrentPlayEnabled(on);
    if (!mounted) return;
    _snack(
      on
          ? 'Torrent fallback enabled (VPN or verified proxy still required)'
          : 'Torrent fallback disabled; Real-Debrid only',
    );
  }

  Future<void> _setMediaServer(bool on) async {
    setState(() => _mediaServer = on);
    await _prefs?.setBool(_kMediaServerKey, on);
    try {
      if (on) {
        await BeamMediaCenter.instance.start();
        if (!mounted) return;
        final m = BeamMediaCenter.instance.mapping;
        _snack(
          m != null
              ? 'Media server on — reachable at ${m.externalIp ?? '?'}:${m.externalPort}'
              : 'Media server on (LAN only): ${BeamMediaCenter.instance.server.baseUrl}',
        );
      } else {
        await BeamMediaCenter.instance.stop();
      }
    } catch (e) {
      appLogger.w('media server toggle failed: $e');
      if (mounted) _snack('Media server error: $e');
    }
  }

  Future<void> _checkHidden() async {
    setState(() {
      _checking = true;
      _exitIp = null;
      _checkFailed = false;
    });
    final ip = await BeamHttp.checkProxyExitIp();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _exitIp = ip;
      _checkFailed = ip == null;
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    // Refresh on return (active profile / enabled state may have changed).
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Beam')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _sectionHeader(context, 'Privacy'),
                SwitchListTile(
                  secondary: const Icon(Icons.vpn_lock_rounded),
                  title: const Text('Route through proxy'),
                  subtitle: Text(
                    _proxyEnabled
                        ? (_activeProfile?.name ?? 'Proxy on')
                        : 'Direct connection (not hidden)',
                  ),
                  value: _proxyEnabled,
                  onChanged: (v) => unawaited(_setProxyEnabled(v)),
                ),
                _proxyStatusTile(theme),
                ListTile(
                  leading: const Icon(Icons.lan_rounded),
                  title: const Text('Proxy networks'),
                  subtitle: const Text('Choose or add a proxy / VPN endpoint'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => unawaited(_push(const ProxySettingsScreen())),
                ),
                ListTile(
                  leading: const Icon(Icons.public_rounded),
                  title: const Text('Free community VPN'),
                  subtitle: const Text(
                    'Built-in OpenVPN (VPN Gate) so trackers connect — '
                    'replaces any other VPN while on',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => unawaited(_push(const BeamCommunityVpnScreen())),
                ),
                const Divider(height: 24),
                _sectionHeader(context, 'Sources'),
                ListTile(
                  leading: const Icon(Icons.cloud_download_rounded),
                  title: const Text('Real-Debrid'),
                  subtitle: const Text('Premium link resolver'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () =>
                      unawaited(_push(const RealDebridSettingsScreen())),
                ),
                ListTile(
                  leading: const Icon(Icons.storage_rounded),
                  title: const Text('rclone remotes'),
                  subtitle: const Text('Cloud / network storage mounts'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => unawaited(_push(const RcloneSettingsScreen())),
                ),
                const Divider(height: 24),
                _sectionHeader(context, 'Playback'),
                SwitchListTile(
                  secondary: const Icon(Icons.play_circle_outline_rounded),
                  title: const Text('Instant torrent fallback'),
                  subtitle: const Text(
                    'After Real-Debrid fails, stream the best seeded source '
                    'through your active VPN or verified proxy',
                  ),
                  value: _torrentPlay,
                  onChanged: (v) => unawaited(_setTorrentPlay(v)),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.dvr_rounded),
                  title: const Text('Media server'),
                  subtitle: const Text(
                    'Expose resolved streams to the local media server',
                  ),
                  value: _mediaServer,
                  onChanged: (v) => unawaited(_setMediaServer(v)),
                ),
                const Divider(height: 24),
                _sectionHeader(context, 'Privacy status'),
                ListTile(
                  leading: Icon(
                    _vpnActive
                        ? Icons.vpn_lock_rounded
                        : Icons.vpn_key_off_rounded,
                    color: _vpnActive ? Colors.green : null,
                  ),
                  title: Text(
                    _vpnActive
                        ? 'Device VPN active${_vpnIface != null ? ' ($_vpnIface)' : ''}'
                        : 'No device VPN detected',
                  ),
                  subtitle: Text(
                    _vpnActive
                        ? 'Torrent streaming allowed — all traffic (incl. DHT) is '
                              'tunnelled, so no SOCKS5 proxy is needed.'
                        : 'Turn on your VPN (e.g. Surfshark) to allow torrent '
                              'streaming, or set a SOCKS5 proxy above.',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh_rounded),
                    tooltip: 'Re-check',
                    onPressed: () => unawaited(_refreshVpn()),
                  ),
                ),
                const Divider(height: 24),
                _sectionHeader(context, 'Release quality'),
                SwitchListTile(
                  secondary: const Icon(Icons.videocam_off_rounded),
                  title: const Text('Allow cam / telesync releases'),
                  subtitle: const Text(
                    'Off: camcorder rips are never auto-picked. On: they rank '
                    'last but can play when a new release has nothing better.',
                  ),
                  value: _allowCam,
                  onChanged: (v) => unawaited(_setAllowCam(v)),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _proxyStatusTile(ThemeData theme) {
    if (!_proxyEnabled) return const SizedBox.shrink();
    final Widget trailing;
    if (_checking) {
      trailing = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else {
      trailing = FilledButton.tonal(
        onPressed: () => unawaited(_checkHidden()),
        child: const Text("Check I'm hidden"),
      );
    }

    Widget? status;
    if (_exitIp != null) {
      status = Text(
        'Hidden — exit IP $_exitIp',
        style: TextStyle(color: theme.colorScheme.primary),
      );
    } else if (_checkFailed) {
      status = Text(
        'proxy not working',
        style: TextStyle(
          color: theme.colorScheme.error,
          fontWeight: FontWeight.w600,
        ),
      );
    }

    return ListTile(
      leading: Icon(
        _exitIp != null ? Icons.shield_rounded : Icons.shield_outlined,
        color: _exitIp != null ? theme.colorScheme.primary : null,
      ),
      title: const Text('Proxy status'),
      subtitle: status,
      trailing: trailing,
    );
  }

  Widget _sectionHeader(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
