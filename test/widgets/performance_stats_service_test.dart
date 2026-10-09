import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/widgets/video_controls/widgets/performance_overlay/performance_stats_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final nativeStats in [false, true]) {
    final backend = nativeStats ? 'Android native stats' : 'MPV property queries';
    for (final sample in <(String?, String)>[('0.240', '+240ms'), ('-0.035', '-35ms'), (null, 'N/A')]) {
      test('$backend displays current A/V difference ${sample.$2}, not accumulated correction', () async {
        final player = _StatsPlayer(nativeStats, {
          'avsync': sample.$1,
          // This historical correction must neither replace the current
          // difference nor masquerade as one when audio/video is absent.
          'total-avsync-change': '8.3',
        });
        final service = PerformanceStatsService(player);
        addTearDown(service.dispose);
        final nextStats = service.statsStream.first;

        service.startPolling();
        final stats = await nextStats;

        expect(stats.avsyncFormatted, sample.$2);
        if (!nativeStats) {
          expect(player.propertyQueries, contains('avsync'));
          expect(player.propertyQueries, isNot(contains('total-avsync-change')));
        }
      });
    }
  }
}

class _StatsPlayer implements Player {
  _StatsPlayer(this.providesNativeStats, this.properties);

  @override
  final bool providesNativeStats;
  final Map<String, String?> properties;
  final propertyQueries = <String>[];

  @override
  PlayerStreams get streams => _StatsStreams();

  @override
  Future<String> runtimePlayerType() async => 'mpv';

  @override
  Future<Map<String, dynamic>> getStats() async => {'playerType': 'mpv', ...properties};

  @override
  Future<String?> getProperty(String name) async {
    propertyQueries.add(name);
    return properties[name];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StatsStreams implements PlayerStreams {
  @override
  Stream<void> get backendSwitched => const Stream<void>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
