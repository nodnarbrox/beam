import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item_types.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player/widgets/player_prompt_overlays.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:provider/provider.dart';

void main() {
  const first = BeamEpisodeIdentity(showId: 'pioneer-one', showTitle: 'Pioneer One', season: 1, episode: 1);
  const second = BeamEpisodeIdentity(showId: 'pioneer-one', showTitle: 'Pioneer One', season: 1, episode: 2);

  test('direct player keeps episode metadata, content key and explicit resume', () {
    final player = VideoPlayerScreen.direct(
      url: 'http://localhost/episode2',
      title: 'Pioneer.One.Complete.Season',
      beamInfoHash: 'pack',
      beamEpisode: second,
      beamResumeMs: 42000,
    );
    expect(player.metadata.isEpisode, isTrue);
    expect(player.metadata.grandparentTitle, 'Pioneer One');
    expect(player.metadata.parentIndex, 1);
    expect(player.metadata.index, 2);
    expect(player.beamContentKey, second.contentKey);
    expect(player.beamContentKey, isNot(first.contentKey));
    expect(player.beamInfoHash, 'pack');
    expect(player.beamResumeMs, 42000);
  });

  testWidgets('reachable play-next prompt passes exact next episode to the direct player contract', (tester) async {
    final chrome = PlayerChromeController();
    final cancel = FocusNode();
    final confirm = FocusNode();
    addTearDown(chrome.dispose);
    addTearDown(cancel.dispose);
    addTearDown(confirm.dispose);
    VideoPlayerScreen? launched;
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => PlaybackStateProvider(),
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                VideoPlayerPlayNextOverlay(
                  visible: true,
                  nextEpisode: second.playerMetadata,
                  autoPlayCountdown: -1,
                  cancelFocusNode: cancel,
                  confirmFocusNode: confirm,
                  chromeController: chrome,
                  onCancel: () {},
                  onPlayNext: () {
                    final target = first.forEpisode(second.playerMetadata);
                    launched = VideoPlayerScreen.direct(
                      url: 'http://localhost/episode2',
                      beamInfoHash: 'same-pack',
                      beamEpisode: target,
                      beamResumeMs: 42000,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('S1 E2'), findsOneWidget);
    await tester.tap(find.text('Play Next'));
    await tester.pump();
    expect(launched, isNotNull);
    expect(launched!.metadata.index, 2);
    expect(launched!.beamContentKey, second.contentKey);
    expect(launched!.beamResumeMs, 42000);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
