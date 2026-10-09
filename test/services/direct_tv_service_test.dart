import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/direct_tv_service.dart';

void main() {
  test('uses the chosen tuner address for playback and reads major networks', () async {
    final service = DirectTvService(
      'http://tv.home:8776',
      client: MockClient(
        (request) async => http.Response(
          jsonEncode(
            request.url.path == '/health'
                ? {
                    'preload_candidates': ['112', '20'],
                    'preloaded': ['112'],
                  }
                : [
                    {'GuideNumber': '112', 'GuideName': 'History', 'URL': 'http://192.0.2.10:8776/auto/v112'},
                  ],
          ),
          200,
        ),
      ),
    );
    addTearDown(service.close);
    final lineup = await service.load();
    expect(lineup.channels.single.stream.toString(), 'http://tv.home:8776/auto/v112');
    expect(lineup.majorNetworks, {'112', '20'});
    expect(lineup.preloaded, {'112'});
  });

  test('missing optional status does not block a working lineup', () async {
    final service = DirectTvService(
      'https://tv.home',
      client: MockClient(
        (request) async => request.url.path == '/health'
            ? http.Response('not found', 404)
            : http.Response(
                jsonEncode([
                  {'GuideNumber': '20', 'GuideName': 'A&E', 'URL': 'https://tv.home/auto/v20'},
                  {'GuideNumber': '20', 'GuideName': 'Duplicate', 'URL': 'https://tv.home/auto/v20'},
                  {'GuideNumber': '87', 'GuideName': 'Secret URL', 'URL': 'http://provider/live/user/password/87.ts'},
                  {'GuideNumber': '88', 'GuideName': 'File', 'URL': 'file:///auto/v88'},
                ]),
                200,
              ),
      ),
    );
    addTearDown(service.close);
    final lineup = await service.load();
    expect(lineup.channels.map((c) => c.name), ['A&E']);
    expect(lineup.majorNetworks, isEmpty);
  });

  test('invalid response fails instead of reporting a working empty TV service', () async {
    final service = DirectTvService('https://tv.home', client: MockClient((_) async => http.Response('{}', 200)));
    addTearDown(service.close);
    await expectLater(service.load(), throwsFormatException);
  });

  test('settings reject credentials, queries, paths and non-network addresses', () {
    for (final value in [
      'file:///tmp/tv',
      'http://user:password@tv',
      'http://tv/?token=secret',
      'http://tv/subdir',
      'bad',
    ]) {
      expect(() => DirectTvService.parseAddress(value), throwsFormatException);
    }
  });
}
