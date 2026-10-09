import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/services/youtube/youtube_accounts.dart';

void main() {
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  Future<void> seed(String profile, String id, String token, List<String> history) async {
    final prefix = 'youtube.${Uri.encodeComponent(profile)}';
    await prefs.setString('$prefix.googleToken', token);
    await prefs.setString(
      '$prefix.googleLibrary',
      jsonEncode({'channelId': id, 'name': id, 'avatarUrl': 'https://example.com/$id.png'}),
    );
    for (final key in ['recent', 'saved', 'viewedChannels']) {
      await prefs.setStringList('$prefix.$key', history);
    }
  }

  test('adding and switching accounts preserves separate viewing histories', () async {
    await seed('tv', 'one', 'encrypted-one', ['first']);
    await seed('pending', 'two', 'encrypted-two', []);
    final accounts = YouTubeAccounts(prefs, 'tv');
    await accounts.adopt('pending');
    expect(accounts.activeId, 'two');
    expect(prefs.getStringList('youtube.tv.recent'), isEmpty);
    expect(prefs.containsKey('youtube.pending.googleToken'), isFalse);
    await prefs.setStringList('youtube.tv.recent', ['second']);
    await accounts.select('one');
    expect(prefs.getString('youtube.tv.googleToken'), 'encrypted-one');
    expect(prefs.getStringList('youtube.tv.recent'), ['first']);
    await accounts.select('two');
    expect(prefs.getStringList('youtube.tv.recent'), ['second']);
    expect(accounts.accounts.first.containsKey('token'), isFalse);
  });
  test('reconnecting the active account uses new credentials and keeps history', () async {
    await seed('tv', 'one', 'expired', ['played']);
    await seed('pending', 'one', 'fresh', []);
    final accounts = YouTubeAccounts(prefs, 'tv');
    await accounts.adopt('pending');
    expect(prefs.getString('youtube.tv.googleToken'), 'fresh');
    expect(prefs.getStringList('youtube.tv.recent'), ['played']);
    expect(accounts.accounts.length, 1);
  });
  test('canceling a new connection leaves the active account intact', () async {
    await seed('tv', 'one', 'encrypted', ['played']);
    await seed('pending', 'two', 'pending', []);
    await YouTubeAccounts(prefs, 'pending').clearPending();
    expect(YouTubeAccounts(prefs, 'tv').activeId, 'one');
    expect(prefs.getStringList('youtube.tv.recent'), ['played']);
  });
  test('removing an account selects another and never crosses Plezy profiles', () async {
    await seed('tv', 'one', 'one', []);
    await seed('pending', 'two', 'two', []);
    await seed('guest', 'guest', 'guest', []);
    final accounts = YouTubeAccounts(prefs, 'tv');
    await accounts.adopt('pending');
    await accounts.forgetCurrent();
    expect(accounts.activeId, 'one');
    expect(accounts.accounts.length, 1);
    expect(YouTubeAccounts(prefs, 'guest').activeId, 'guest');
    await accounts.forgetCurrent();
    expect(accounts.accounts, isEmpty);
    expect(prefs.containsKey('youtube.tv.googleToken'), isFalse);
  });
}
