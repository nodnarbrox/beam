import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/error_inbox.dart';
import '../../utils/snackbar_helper.dart';

class ErrorInboxScreen extends StatefulWidget {
  const ErrorInboxScreen({super.key});
  @override
  State<ErrorInboxScreen> createState() => _ErrorInboxScreenState();
}

class _ErrorInboxScreenState extends State<ErrorInboxScreen> {
  final _inbox = ErrorInbox.instance;
  @override
  void initState() {
    super.initState();
    unawaited(_inbox.initialize());
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _inbox.export()));
    if (mounted) showAppSnackBar(context, 'Error history copied');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _inbox,
    builder: (context, _) {
      final entries = _inbox.entries;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Error inbox'),
          actions: [
            IconButton(
              tooltip: 'Copy error history',
              onPressed: entries.isEmpty ? null : _copy,
              icon: const Icon(Icons.copy),
            ),
            IconButton(
              tooltip: 'Clear error history',
              onPressed: entries.isEmpty ? null : _inbox.clear,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _inbox.persistenceError ??
                    'Background failures and warnings are saved here, including errors with no popup. Repeats are grouped. History stays on this device.',
              ),
            ),
            Expanded(
              child: entries.isEmpty
                  ? const Center(child: Text('No recorded errors'))
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return ExpansionTile(
                          leading: Icon(entry.level == 'warning' ? Icons.warning_amber_rounded : Icons.error_outline),
                          title: Text(entry.message, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${entry.source} · ${entry.lastSeen.toLocal()} · ${entry.count} occurrence${entry.count == 1 ? '' : 's'}',
                          ),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: SelectableText(
                                '${entry.message}\n${entry.details}\nFirst seen: ${entry.firstSeen.toLocal()}',
                              ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );
}
