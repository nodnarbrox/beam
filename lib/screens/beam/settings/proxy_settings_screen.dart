import 'dart:async';

import 'package:flutter/material.dart';

import 'package:plezy/utils/app_logger.dart';

import '../../../services/beam/beam_config.dart';
import '../../../services/beam/proxy_profiles.dart';

/// Lists the saved proxy profiles as selectable radio tiles, lets the user add
/// custom ones and edit/delete non-builtin entries. Selecting a complete
/// profile activates it (which also flips BeamConfig.proxyEnabled on).
class ProxySettingsScreen extends StatefulWidget {
  const ProxySettingsScreen({super.key});

  @override
  State<ProxySettingsScreen> createState() => _ProxySettingsScreenState();
}

class _ProxySettingsScreenState extends State<ProxySettingsScreen> {
  bool _loading = true;
  List<ProxyProfile> _profiles = const [];
  String? _activeId;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await BeamConfig.init();
      await ProxyProfiles.init();
      final list = await ProxyProfiles.all();
      final active = await ProxyProfiles.activeId();
      if (!mounted) return;
      setState(() {
        _profiles = list;
        _activeId = active;
        _loading = false;
      });
    } catch (e, st) {
      appLogger.e('proxy list load failed', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Failed to load proxies: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _select(ProxyProfile p) async {
    if (!p.isComplete) {
      _snack('Add a host and port before selecting "${p.name}".');
      unawaited(_edit(p));
      return;
    }
    try {
      await ProxyProfiles.select(p.id);
      if (!mounted) return;
      setState(() => _activeId = p.id);
      _snack('Now routing through ${p.name}.');
    } catch (e) {
      _snack('Could not select proxy: $e');
    }
  }

  Future<void> _delete(ProxyProfile p) async {
    await ProxyProfiles.remove(p.id);
    await _load();
  }

  Future<void> _edit(ProxyProfile? existing) async {
    final result = await showDialog<ProxyProfile>(
      context: context,
      builder: (_) => _ProxyEditDialog(existing: existing),
    );
    if (result == null) return;
    try {
      await ProxyProfiles.upsert(result);
      await _load();
      _snack('Saved "${result.name}".');
    } catch (e) {
      _snack('Save failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Proxy networks')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => unawaited(_edit(null)),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add proxy'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RadioGroup<String>(
              groupValue: _activeId,
              onChanged: (id) {
                if (id == null) return;
                final p = _profiles.firstWhere((e) => e.id == id);
                unawaited(_select(p));
              },
              child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: _profiles.length,
              itemBuilder: (context, i) {
                final p = _profiles[i];
                final active = p.id == _activeId;
                final endpoint = p.isComplete
                    ? '${p.scheme}://${p.host}:${p.port}'
                    : 'Not configured';
                return Card(
                  margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                  color: active
                      ? theme.colorScheme.primaryContainer
                      : null,
                  child: RadioListTile<String>(
                    value: p.id,
                    title: Text(p.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(endpoint),
                        if (p.note.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              p.note,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                    secondary: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_rounded),
                          tooltip: 'Edit',
                          onPressed: () => unawaited(_edit(p)),
                        ),
                        if (!p.builtIn)
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded),
                            tooltip: 'Delete',
                            onPressed: () => unawaited(_delete(p)),
                          ),
                      ],
                    ),
                    isThreeLine: p.note.isNotEmpty,
                  ),
                );
              },
            ),
            ),
    );
  }
}

/// Add/edit dialog. Builds a new ProxyProfile (preserving id/builtIn/note when
/// editing an existing one) from the entered fields.
class _ProxyEditDialog extends StatefulWidget {
  const _ProxyEditDialog({this.existing});
  final ProxyProfile? existing;

  @override
  State<_ProxyEditDialog> createState() => _ProxyEditDialogState();
}

class _ProxyEditDialogState extends State<_ProxyEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  String _scheme = 'socks5';
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: (e?.port ?? 1080).toString());
    _user = TextEditingController(text: e?.username ?? '');
    _pass = TextEditingController(text: e?.password ?? '');
    _scheme = e?.scheme ?? 'socks5';
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _save() {
    final e = widget.existing;
    final id = e?.id ??
        'usr_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final profile = ProxyProfile(
      id: id,
      name: _name.text.trim().isEmpty ? 'Custom proxy' : _name.text.trim(),
      scheme: _scheme,
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 1080,
      username: _user.text.trim(),
      password: _pass.text,
      builtIn: e?.builtIn ?? false, // editing a template keeps it a template
      note: e?.note ?? '',
    );
    Navigator.of(context).pop(profile);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add proxy' : 'Edit proxy'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _scheme,
              decoration: const InputDecoration(labelText: 'Scheme'),
              items: const [
                DropdownMenuItem(value: 'socks5', child: Text('SOCKS5')),
                DropdownMenuItem(value: 'http', child: Text('HTTP')),
              ],
              onChanged: (v) => setState(() => _scheme = v ?? 'socks5'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _host,
              decoration: const InputDecoration(
                  labelText: 'Host', hintText: '10.64.0.1 or proxy.example.com'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _port,
              decoration: const InputDecoration(labelText: 'Port'),
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _user,
              decoration:
                  const InputDecoration(labelText: 'Username (optional)'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _pass,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Password (optional)',
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
