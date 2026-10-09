import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:plezy/utils/app_logger.dart';

import '../../../services/beam/beam_config.dart';
import '../../../services/beam/beam_http.dart';

/// Minimal rclone remotes manager. Talks to the rclone remote-control (rc)
/// daemon at [BeamConfig.rcloneUrl]. Because rclone needs its native binary
/// running, every call is guarded: if the daemon URL is unset or unreachable
/// we surface a clear "not started" state rather than crashing.
class RcloneSettingsScreen extends StatefulWidget {
  const RcloneSettingsScreen({super.key});

  @override
  State<RcloneSettingsScreen> createState() => _RcloneSettingsScreenState();
}

enum _RcState { loading, notStarted, ready, error }

class _RcloneSettingsScreenState extends State<RcloneSettingsScreen> {
  _RcState _state = _RcState.loading;
  List<String> _remotes = const [];
  String _detail = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _state = _RcState.loading);
    try {
      await BeamConfig.init();
    } catch (_) {}
    final url = BeamConfig.rcloneUrl;
    if (url.isEmpty) {
      if (!mounted) return;
      setState(() {
        _state = _RcState.notStarted;
        _detail = 'No rclone daemon URL configured.';
      });
      return;
    }
    try {
      final remotes = await _listRemotes(url);
      if (!mounted) return;
      setState(() {
        _remotes = remotes;
        _state = _RcState.ready;
      });
    } catch (e) {
      appLogger.w('rclone listremotes failed: $e');
      if (!mounted) return;
      setState(() {
        _state = _RcState.notStarted;
        _detail = 'rclone not reachable at $url';
      });
    }
  }

  Future<Map<String, String>> _authHeaders() async {
    final user = BeamConfig.rcloneUser;
    final pass = await BeamConfig.getRclonePass();
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (user.isNotEmpty) {
      final basic = base64Encode(utf8.encode('$user:$pass'));
      headers['Authorization'] = 'Basic $basic';
    }
    return headers;
  }

  // rclone rc endpoints are LAN/localhost — never proxy them.
  Future<List<String>> _listRemotes(String url) async {
    final client = BeamHttp.directClient();
    try {
      final r = await client
          .post(Uri.parse('$url/config/listremotes'),
              headers: await _authHeaders())
          .timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) {
        throw http.ClientException('HTTP ${r.statusCode}');
      }
      final body = jsonDecode(r.body);
      final list = (body is Map && body['remotes'] is List)
          ? (body['remotes'] as List).map((e) => '$e').toList()
          : <String>[];
      return list;
    } finally {
      client.close();
    }
  }

  Future<void> _createRemote(String name, String type,
      Map<String, dynamic> params) async {
    final url = BeamConfig.rcloneUrl;
    if (url.isEmpty) {
      _snack('Configure the rclone daemon URL first.');
      return;
    }
    final client = BeamHttp.directClient();
    try {
      final r = await client
          .post(
            Uri.parse('$url/config/create'),
            headers: await _authHeaders(),
            body: jsonEncode({
              'name': name,
              'type': type,
              'parameters': params,
            }),
          )
          .timeout(const Duration(seconds: 12));
      if (r.statusCode == 200) {
        _snack('Remote "$name" created.');
        await _load();
      } else {
        _snack('Create failed: HTTP ${r.statusCode}');
      }
    } catch (e) {
      appLogger.w('rclone create remote failed: $e');
      _snack('Create failed: $e');
    } finally {
      client.close();
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addRemoteDialog() async {
    final result = await showDialog<_NewRemote>(
      context: context,
      builder: (_) => const _RcloneAddDialog(),
    );
    if (result == null) return;
    await _createRemote(result.name, result.type, result.params);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('rclone remotes')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => unawaited(_addRemoteDialog()),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add remote'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    switch (_state) {
      case _RcState.loading:
        return const Center(child: CircularProgressIndicator());
      case _RcState.notStarted:
      case _RcState.error:
        return ListView(children: [
          const SizedBox(height: 80),
          Icon(Icons.cloud_off_rounded,
              size: 56, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Center(
              child: Text('rclone not started',
                  style: theme.textTheme.titleMedium)),
          const SizedBox(height: 6),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _detail.isEmpty
                    ? 'Start the rclone rc daemon to manage remotes.'
                    : _detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton.icon(
              onPressed: () => unawaited(_load()),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ),
        ]);
      case _RcState.ready:
        if (_remotes.isEmpty) {
          return ListView(children: [
            const SizedBox(height: 80),
            Center(
                child: Text('No remotes configured yet.',
                    style: theme.textTheme.bodyMedium)),
          ]);
        }
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: _remotes.length,
          itemBuilder: (context, i) => ListTile(
            leading: const Icon(Icons.folder_shared_rounded),
            title: Text(_remotes[i]),
            subtitle: const Text('rclone remote'),
          ),
        );
    }
  }
}

class _NewRemote {
  _NewRemote(this.name, this.type, this.params);
  final String name;
  final String type;
  final Map<String, dynamic> params;
}

/// Collects a remote name, type, and a freeform key=value params block.
class _RcloneAddDialog extends StatefulWidget {
  const _RcloneAddDialog();

  @override
  State<_RcloneAddDialog> createState() => _RcloneAddDialogState();
}

class _RcloneAddDialogState extends State<_RcloneAddDialog> {
  final _name = TextEditingController();
  final _type = TextEditingController(text: 'webdav');
  final _params = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _type.dispose();
    _params.dispose();
    super.dispose();
  }

  Map<String, dynamic> _parseParams() {
    final out = <String, dynamic>{};
    for (final line in _params.text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final idx = t.indexOf('=');
      if (idx <= 0) continue;
      out[t.substring(0, idx).trim()] = t.substring(idx + 1).trim();
    }
    return out;
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(
      _NewRemote(name, _type.text.trim(), _parseParams()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add rclone remote'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Remote name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _type,
              decoration: const InputDecoration(
                  labelText: 'Type', hintText: 'webdav, drive, s3, sftp…'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _params,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Parameters',
                hintText: 'one per line:\nurl=https://…\nuser=me\npass=…',
                border: OutlineInputBorder(),
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
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
