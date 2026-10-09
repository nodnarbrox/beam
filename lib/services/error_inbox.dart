import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/log_redaction_manager.dart';

class ErrorInboxEntry {
  ErrorInboxEntry({
    required this.message,
    required this.source,
    required this.level,
    required this.firstSeen,
    required this.lastSeen,
    this.details = '',
    this.count = 1,
  });
  final String message;
  final String source;
  final String level;
  final String details;
  final DateTime firstSeen;
  DateTime lastSeen;
  int count;
  String get fingerprint => '$source|$level|$message|$details';

  Map<String, dynamic> toJson() => {
    'message': message,
    'source': source,
    'level': level,
    'details': details,
    'firstSeen': firstSeen.toIso8601String(),
    'lastSeen': lastSeen.toIso8601String(),
    'count': count,
  };
  factory ErrorInboxEntry.fromJson(Map<String, dynamic> json) => ErrorInboxEntry(
    message: json['message'] as String,
    source: json['source'] as String,
    level: json['level'] as String,
    details: json['details'] as String,
    firstSeen: DateTime.parse(json['firstSeen'] as String),
    lastSeen: DateTime.parse(json['lastSeen'] as String),
    count: json['count'] as int,
  );
}

/// Bounded, local, persistent diagnostics. Nothing is uploaded automatically.
/// This deliberately does not use appLogger, so storage failures cannot recurse.
class ErrorInbox extends ChangeNotifier {
  ErrorInbox();
  static final instance = ErrorInbox();
  static const storageKey = 'diagnostics.errorInbox.v1';
  static const maxEntries = 150;
  final List<ErrorInboxEntry> _entries = [];
  SharedPreferences? _preferences;
  Future<void>? _initialization;
  Future<void> _writes = Future.value();
  Timer? _timer;
  bool _notificationPending = false;
  bool _disposed = false;
  String? persistenceError;

  List<ErrorInboxEntry> get entries => List.unmodifiable(_entries.reversed);

  static String sanitize(String text) {
    final redacted = LogRedactionManager.redact(
      text,
    ).replaceAllMapped(RegExp(r'(https?://[^\s?]+)\?[^\s]+'), (match) => '${match[1]}?[redacted]');
    return redacted.length > 4000 ? '${redacted.substring(0, 4000)}…' : redacted;
  }

  void capture(String message, {String source = 'app', String level = 'error', Object? error, StackTrace? stackTrace}) {
    if (_disposed) return;
    final now = DateTime.now().toUtc();
    final entry = ErrorInboxEntry(
      message: sanitize(message),
      source: sanitize(source),
      level: level,
      firstSeen: now,
      lastSeen: now,
      details: sanitize([if (error != null) '$error', if (stackTrace != null) '$stackTrace'].join('\n')),
    );
    final index = _entries.indexWhere((e) => e.fingerprint == entry.fingerprint);
    if (index >= 0) {
      final previous = _entries.removeAt(index);
      previous.count++;
      previous.lastSeen = now;
      _entries.add(previous);
    } else {
      _entries.add(entry);
    }
    if (_entries.length > maxEntries) _entries.removeRange(0, _entries.length - maxEntries);
    _changed();
  }

  Future<void> initialize() => _initialization ??= _load();

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (_disposed) return;
      _preferences = preferences;
      final pending = List<ErrorInboxEntry>.of(_entries);
      final restored = <ErrorInboxEntry>[];
      for (final raw in preferences.getStringList(storageKey) ?? <String>[]) {
        try {
          final entry = ErrorInboxEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>);
          restored.add(
            ErrorInboxEntry(
              message: sanitize(entry.message),
              source: sanitize(entry.source),
              level: entry.level,
              firstSeen: entry.firstSeen,
              lastSeen: entry.lastSeen,
              details: sanitize(entry.details),
              count: entry.count,
            ),
          );
        } catch (_) {
          persistenceError = 'Some saved error records could not be read.';
        }
      }
      final combined = <String, ErrorInboxEntry>{};
      for (final entry in [...restored, ...pending]) {
        final previous = combined[entry.fingerprint];
        if (previous == null) {
          combined[entry.fingerprint] = entry;
        } else {
          previous.count += entry.count;
          if (entry.lastSeen.isAfter(previous.lastSeen)) previous.lastSeen = entry.lastSeen;
        }
      }
      _entries
        ..clear()
        ..addAll(combined.values);
      _entries.sort((a, b) => a.lastSeen.compareTo(b.lastSeen));
      if (_entries.length > maxEntries) _entries.removeRange(0, _entries.length - maxEntries);
      _changed();
    } catch (_) {
      persistenceError = 'Error history could not be loaded. New errors are available for this session.';
      _notifyLater();
    }
  }

  void _notifyLater() {
    if (_notificationPending || _disposed) return;
    _notificationPending = true;
    scheduleMicrotask(() {
      _notificationPending = false;
      if (!_disposed) notifyListeners();
    });
  }

  void _changed() {
    _notifyLater();
    _timer?.cancel();
    if (_preferences != null) _timer = Timer(const Duration(milliseconds: 250), () => unawaited(flush()));
  }

  Future<void> flush() {
    _timer?.cancel();
    final preferences = _preferences;
    if (preferences == null) return Future.value();
    final data = _entries.map((entry) => jsonEncode(entry.toJson())).toList();
    return _writes = _writes.then((_) async {
      try {
        if (!await preferences.setStringList(storageKey, data)) throw StateError('Write failed');
      } catch (_) {
        persistenceError = 'Error history could not be saved. Copy it before closing the app.';
        _notifyLater();
      }
    });
  }

  Future<void> clear() async {
    await initialize();
    _entries.clear();
    _notifyLater();
    await flush();
  }

  String export() => const JsonEncoder.withIndent('  ').convert(entries.map((entry) => entry.toJson()).toList());

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
