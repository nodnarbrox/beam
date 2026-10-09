import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:plezy/utils/app_logger.dart';

import '../../../services/beam/beam_config.dart';
import '../../../services/beam/beam_http.dart';
import '../../../services/beam/realdebrid_client.dart';

/// Real-Debrid token entry + verification. Saves the token, then calls
/// user() once and shows the account username + premium expiry.
class RealDebridSettingsScreen extends StatefulWidget {
  const RealDebridSettingsScreen({super.key});

  @override
  State<RealDebridSettingsScreen> createState() =>
      _RealDebridSettingsScreenState();
}

class _RealDebridSettingsScreenState extends State<RealDebridSettingsScreen> {
  static const _tokenUrl = 'https://real-debrid.com/apitoken';

  final _token = TextEditingController();
  bool _loading = true;
  bool _obscure = true;
  bool _testing = false;
  String? _statusOk;
  String? _statusErr;
  RealDebridClient? _testClient;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await BeamConfig.init();
      final tok = await BeamConfig.getRdToken();
      if (!mounted) return;
      setState(() {
        _token.text = tok;
        _loading = false;
      });
    } catch (e, st) {
      appLogger.e('RD settings load failed', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _testClient?.close();
    _token.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      setState(() => _token.text = text);
    }
  }

  Future<void> _save() async {
    await BeamConfig.setRdToken(_token.text.trim());
    _snack('Token saved.');
  }

  /// Saves the token then verifies it: premium flag + account details.
  Future<void> _test() async {
    setState(() {
      _testing = true;
      _statusOk = null;
      _statusErr = null;
    });
    await BeamConfig.setRdToken(_token.text.trim());

    if (!mounted) return;
    final http = await BeamHttp.client();
    if (!mounted) {
      http.close();
      return;
    }
    final client = RealDebridClient(httpClient: http);
    _testClient = client;
    try {
      final acct = await client.user();
      final premium = acct['type'] == 'premium' || ((acct['premium'] as num?) ?? 0) > 0;
      final username = '${acct['username'] ?? acct['email'] ?? 'account'}';
      final expiryRaw = '${acct['expiration'] ?? ''}';
      final expiry = _formatExpiry(expiryRaw);
      if (!mounted) return;
      setState(() {
        _statusOk = premium
            ? '$username — premium${expiry.isEmpty ? '' : ' until $expiry'}'
            : '$username — NOT premium (RD features limited)';
      });
    } catch (e) {
      appLogger.w('RD test failed: $e');
      if (!mounted) return;
      setState(() => _statusErr = 'Test failed: $e');
    } finally {
      client.close();
      if (identical(_testClient, client)) _testClient = null;
      if (mounted) setState(() => _testing = false);
    }
  }

  String _formatExpiry(String raw) {
    if (raw.isEmpty) return '';
    final dt = DateTime.tryParse(raw);
    if (dt == null) return raw;
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Real-Debrid')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _token,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'API token',
                    border: const OutlineInputBorder(),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Paste',
                          icon: const Icon(Icons.content_paste_rounded),
                          onPressed: () => unawaited(_paste()),
                        ),
                        IconButton(
                          tooltip: _obscure ? 'Show' : 'Hide',
                          icon: Icon(_obscure
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded),
                          onPressed: () =>
                              setState(() => _obscure = !_obscure),
                        ),
                      ],
                    ),
                  ),
                  onSubmitted: (_) => unawaited(_save()),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  'Get your token at $_tokenUrl',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => unawaited(_save()),
                        icon: const Icon(Icons.save_rounded),
                        label: const Text('Save'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _testing ? null : () => unawaited(_test()),
                        icon: _testing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.wifi_tethering_rounded),
                        label: const Text('Test'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_statusOk != null)
                  _StatusCard(
                    icon: Icons.check_circle_rounded,
                    color: theme.colorScheme.primary,
                    text: _statusOk!,
                  ),
                if (_statusErr != null)
                  _StatusCard(
                    icon: Icons.error_rounded,
                    color: theme.colorScheme.error,
                    text: _statusErr!,
                  ),
              ],
            ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard(
      {required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(text, style: TextStyle(color: color)),
      ),
    );
  }
}
