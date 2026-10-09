import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  test('implicit Android TV passthrough follows actual backend, not global Exo preference', () {
    expect(resolveAudioPassthrough(storedValue: null, isAndroidTv: true, useExoPlayer: false), isFalse);
    expect(resolveAudioPassthrough(storedValue: null, isAndroidTv: true, useExoPlayer: true), isTrue);
    expect(resolveAudioPassthrough(storedValue: null, isAndroidTv: false, useExoPlayer: true), isFalse);
  });

  for (final stored in [true, false]) {
    test('explicit saved $stored choice survives either backend', () async {
      resetSharedPreferencesForTest(initialAsync: {'audio_passthrough': stored, 'use_exoplayer': true});
      final settings = await SettingsService.getInstance();
      for (final exo in [true, false]) {
        expect(resolveAudioPassthrough(storedValue: stored, isAndroidTv: true, useExoPlayer: exo), stored);
        expect(settings.audioPassthroughForBackend(useExoPlayer: exo), stored);
      }
      expect(settings.prefs.getBool(SettingsService.audioPassthrough.key), stored);
      expect(settings.read(SettingsService.useExoPlayer), isTrue);
    });
  }

  test('forced mpv uses decode default without rewriting global preference or storing an override', () async {
    resetSharedPreferencesForTest(initialAsync: {'use_exoplayer': true});
    final settings = await SettingsService.getInstance();
    expect(settings.audioPassthroughForBackend(useExoPlayer: false), isFalse);
    expect(settings.read(SettingsService.useExoPlayer), isTrue);
    expect(settings.prefs.containsKey(SettingsService.audioPassthrough.key), isFalse);
  });
}
