import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/services/youtube/youtube_account.dart';
import 'package:plezy/services/youtube/youtube_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  YouTubeAccount account(http.Client client, {String profile = 'first'}) => YouTubeAccount(
    prefs,
    profile,
    client: client,
    clientId: 'plezy-test-client',
    clientSecret: 'test-client-secret',
    protect: (s) async => base64Encode(utf8.encode(s)),
    reveal: (s) async => utf8.decode(base64Decode(s)),
  );
  http.Response response(Object data, {int status = 200}) => http.Response(jsonEncode(data), status);
  Map<String, Object> tokens({int expires = 3600}) => {
    'access_token': 'test-access',
    'refresh_token': 'test-refresh',
    'expires_in': expires,
  };
  YouTubeDeviceCode code({Duration interval = Duration.zero}) => YouTubeDeviceCode(
    'test-device',
    'ABCD',
    'https://www.google.com/device',
    DateTime.now().add(const Duration(minutes: 5)),
    interval,
  );

  test('device registration requests only read-only access and validates the Google URL', () async {
    final service = account(
      MockClient((request) async {
        expect(request.url.host, 'oauth2.googleapis.com');
        expect(request.bodyFields['scope'], 'https://www.googleapis.com/auth/youtube.readonly');
        expect(request.bodyFields['client_id'], 'plezy-test-client');
        return response({
          'device_code': 'd',
          'user_code': 'ABCD',
          'verification_url': 'https://example.com/login',
          'expires_in': 90,
        });
      }),
    );
    addTearDown(service.close);
    await expectLater(service.begin(), throwsA(isA<YouTubeAccountFailure>()));
    expect(service.connected, isFalse);
  });

  test('malformed token responses never expose response contents in errors', () async {
    final service = account(MockClient((_) async => http.Response('{"access_token":"private-token",broken', 200)));
    addTearDown(service.close);
    await expectLater(
      service.finish(code()),
      throwsA(
        isA<YouTubeAccountFailure>().having(
          (error) => error.toString(),
          'safe error',
          isNot(contains('private-token')),
        ),
      ),
    );
    expect(service.connected, isFalse);
  });

  testWidgets('pending and slow-down polling obey intervals, cancellation stops further requests', (tester) async {
    var calls = 0;
    final service = account(
      MockClient((request) async {
        calls++;
        return response({'error': calls == 1 ? 'authorization_pending' : 'slow_down'}, status: 400);
      }),
    );
    final finished = service.finish(code(interval: const Duration(seconds: 1)));
    final expectation = expectLater(finished, throwsA(isA<YouTubeAccountFailure>()));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
    await tester.pump(const Duration(seconds: 5));
    expect(calls, 2);
    service.close();
    await tester.pump();
    await expectation;
    expect(service.connected, isFalse);
  });

  test('sign-in protects tokens, syncs likes/uploads/channels, and isolates profiles', () async {
    final service = account(
      MockClient((request) async {
        if (request.url.path == '/token') return response(tokens());
        expect(request.headers['Authorization'], 'Bearer test-access');
        switch (request.url.path.split('/').last) {
          case 'videos':
            return response({
              'items': [
                {
                  'id': 'liked',
                  'snippet': {'title': 'Favorite', 'channelTitle': 'Maker', 'channelId': 'maker'},
                },
              ],
            });
          case 'channels':
            return response({
              'items': [
                {
                  'snippet': {'title': 'My channel'},
                  'contentDetails': {
                    'relatedPlaylists': {'uploads': 'uploads-list'},
                  },
                },
              ],
            });
          case 'subscriptions':
            return response({
              'items': [
                {
                  'snippet': {
                    'title': 'Subscribed channel',
                    'resourceId': {'channelId': 'subscribed'},
                  },
                },
              ],
            });
          case 'playlistItems':
            expect(request.url.queryParameters['playlistId'], 'uploads-list');
            return response({
              'items': [
                {
                  'snippet': {
                    'title': 'My upload',
                    'resourceId': {'videoId': 'upload'},
                    'videoOwnerChannelTitle': 'Me',
                    'videoOwnerChannelId': 'mine',
                  },
                },
              ],
            });
          default:
            fail('Unexpected endpoint');
        }
      }),
    );
    addTearDown(service.close);
    await service.finish(code());
    expect(service.connected, isTrue);
    expect(prefs.getString('youtube.first.googleToken'), isNot(contains('test-access')));
    await service.sync();
    expect(service.snapshot?['name'], 'My channel');
    expect((service.snapshot?['uploads'] as List).single['id'], 'upload');
    expect((service.snapshot?['subscriptions'] as List).single['id'], 'subscribed');
    expect(YouTubeLibrary(prefs, 'first').recommendationSeeds.single.id, 'liked');
    final other = account(MockClient((_) async => response({})), profile: 'second');
    addTearDown(other.close);
    expect(other.connected, isFalse);
    expect(other.snapshot, isNull);
    await service.disconnect();
    expect(service.connected, isFalse);
    expect(service.snapshot, isNull);
    expect(YouTubeLibrary(prefs, 'first').recommendationSeeds, isEmpty);
  });

  test('expired access tokens refresh and failed library sync preserves the previous snapshot', () async {
    var tokenCalls = 0;
    final service = account(
      MockClient((request) async {
        if (request.url.path == '/token') {
          tokenCalls++;
          if (tokenCalls == 1) return response(tokens(expires: 1));
          expect(request.bodyFields['grant_type'], 'refresh_token');
          expect(request.bodyFields['refresh_token'], 'test-refresh');
          return response({'access_token': 'refreshed', 'expires_in': 3600});
        }
        expect(request.headers['Authorization'], 'Bearer refreshed');
        return response({'error': 'quotaExceeded'}, status: 403);
      }),
    );
    addTearDown(service.close);
    await service.finish(code());
    await prefs.setString('youtube.first.googleLibrary', jsonEncode({'name': 'Previous'}));
    await expectLater(service.sync(), throwsA(isA<YouTubeAccountFailure>()));
    expect(tokenCalls, 2);
    expect(service.snapshot?['name'], 'Previous');
  });

  test('disconnect prevents an in-flight sync from restoring account data', () async {
    final gate = Completer<http.Response>();
    final service = account(
      MockClient((request) async {
        if (request.url.path == '/token') return response(tokens());
        return gate.future;
      }),
    );
    addTearDown(service.close);
    await service.finish(code());
    final syncing = service.sync();
    final expectation = expectLater(syncing, throwsA(isA<YouTubeAccountFailure>()));
    await Future<void>.delayed(Duration.zero);
    await service.disconnect();
    gate.complete(response({'items': []}));
    await expectation;
    expect(service.snapshot, isNull);
    expect(service.connected, isFalse);
  });

  test('existing subscription snapshots gain avatars once and retain likes', () async {
    var subscriptions = 0;
    final service = account(
      MockClient((request) async {
        if (request.url.path == '/token') return response(tokens());
        if (request.url.pathSegments.last == 'channels') return response({'items': []});
        expect(request.url.pathSegments.last, 'subscriptions');
        subscriptions++;
        return response({
          'items': [
            {
              'snippet': {
                'title': 'Creator',
                'resourceId': {'channelId': 'creator'},
                'thumbnails': {
                  'high': {'url': 'https://yt3.ggpht.com/avatar'},
                },
              },
            },
            {
              'snippet': {
                'title': 'No avatar',
                'resourceId': {'channelId': 'other'},
              },
            },
          ],
        });
      }),
    );
    addTearDown(service.close);
    await service.finish(code());
    await prefs.setString(
      'youtube.first.googleLibrary',
      jsonEncode({
        'liked': ['keep'],
        'name': 'Me',
      }),
    );
    await service.refreshSubscriptionAvatars();
    expect((service.snapshot?['subscriptions'] as List).first['avatarUrl'], 'https://yt3.ggpht.com/avatar');
    expect((service.snapshot?['subscriptions'] as List).last['avatarUrl'], isNull);
    expect(service.snapshot?['liked'], ['keep']);
    expect(service.snapshot?['name'], 'Me');
    await service.refreshSubscriptionAvatars();
    expect(subscriptions, 1);
  });
}
