import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/services/error_inbox.dart';
import 'package:plezy/utils/log_redaction_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('captures before initialization and survives reopening', () async {
    final inbox = ErrorInbox();
    inbox.capture('Background fetch failed', source: 'search', error: StateError('offline'));
    await inbox.initialize();
    await inbox.flush();
    inbox.dispose();
    final reopened = ErrorInbox();
    await reopened.initialize();
    expect(reopened.entries.single.message, 'Background fetch failed');
    expect(reopened.entries.single.details, contains('offline'));
    await reopened.clear();
    reopened.dispose();
    final cleared = ErrorInbox();
    await cleared.initialize();
    expect(cleared.entries, isEmpty);
    cleared.dispose();
  });

  test('repeats are grouped and history is bounded', () async {
    final inbox = ErrorInbox();
    for (var i = 0; i < 10; i++) {
      inbox.capture('Retry failed');
    }
    expect(inbox.entries.length, 1);
    expect(inbox.entries.single.count, 10);
    for (var i = 0; i < ErrorInbox.maxEntries + 20; i++) {
      inbox.capture('Failure $i');
    }
    expect(inbox.entries.length, ErrorInbox.maxEntries);
    expect(inbox.entries.first.message, 'Failure ${ErrorInbox.maxEntries + 19}');
    inbox.dispose();
  });

  test('redacts credentials and signed URLs before storage and export', () async {
    LogRedactionManager.registerToken('private-test-credential');
    final inbox = ErrorInbox();
    await inbox.initialize();
    inbox.capture(
      'Failed https://media.example/video?sig=secret-signature&other=secret-value',
      error: 'Authorization: Bearer private-test-credential',
    );
    await inbox.flush();
    final prefs = await SharedPreferences.getInstance();
    for (final text in [inbox.export(), prefs.getStringList(ErrorInbox.storageKey).toString()]) {
      expect(text, isNot(contains('secret-signature')));
      expect(text, isNot(contains('secret-value')));
      expect(text, isNot(contains('private-test-credential')));
      expect(text, contains('https://media.example/video'));
    }
    inbox.dispose();
  });

  test('a damaged saved record does not hide later errors', () async {
    SharedPreferences.setMockInitialValues({
      ErrorInbox.storageKey: ['not json'],
    });
    final inbox = ErrorInbox();
    await inbox.initialize();
    inbox.capture('Still available');
    expect(inbox.entries.single.message, 'Still available');
    expect(inbox.persistenceError, isNotNull);
    inbox.dispose();
  });
}
