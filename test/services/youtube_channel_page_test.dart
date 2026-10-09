// Validate the vendored parser against the channel format observed on YouTube.
// ignore_for_file: implementation_imports
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/src/channels/video_type.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/pages/channel_upload_page.dart';

void main() {
  test('channel video cards retain title and duration from current lockup metadata', () {
    final data = {
      'contents': {
        'twoColumnBrowseResultsRenderer': {
          'tabs': [
            {
              'tabRenderer': {
                'selected': true,
                'content': {
                  'richGridRenderer': {
                    'contents': [
                      {
                        'richItemRenderer': {
                          'content': {
                            'lockupViewModel': {
                              'contentType': 'LOCKUP_CONTENT_TYPE_VIDEO',
                              'rendererContext': {
                                'commandContext': {
                                  'onTap': {
                                    'innertubeCommand': {
                                      'watchEndpoint': {'videoId': 'pTHmtHXwVKY'},
                                    },
                                  },
                                },
                              },
                              'metadata': {
                                'lockupMetadataViewModel': {
                                  'title': {'content': 'The future of Blender'},
                                  'metadata': {
                                    'contentMetadataViewModel': {
                                      'metadataRows': [
                                        {
                                          'metadataParts': [
                                            {
                                              'text': {'content': '54K views'},
                                            },
                                            {
                                              'text': {'content': '3 days ago'},
                                            },
                                          ],
                                        },
                                      ],
                                    },
                                  },
                                },
                              },
                              'contentImage': {
                                'thumbnailViewModel': {
                                  'image': {
                                    'sources': [
                                      {'url': 'https://i.ytimg.com/vi/pTHmtHXwVKY/hq720.jpg'},
                                    ],
                                  },
                                  'overlays': [
                                    {
                                      'thumbnailBottomOverlayViewModel': {
                                        'badges': [
                                          {
                                            'thumbnailBadgeViewModel': {'text': '25:39'},
                                          },
                                        ],
                                      },
                                    },
                                  ],
                                },
                              },
                            },
                          },
                        },
                      },
                    ],
                  },
                },
              },
            },
          ],
        },
      },
    };
    final page = ChannelUploadPage.parse(
      '<script>var ytInitialData = ${jsonEncode(data)};</script>',
      'UCSMOQeBJ2RAnuFungnQOxLg',
      VideoType.normal,
    );
    final video = page.uploads.single;
    expect(video.videoId.value, 'pTHmtHXwVKY');
    expect(video.videoTitle, 'The future of Blender');
    expect(video.videoDuration, const Duration(minutes: 25, seconds: 39));
    expect(video.videoUploadDate, '3 days ago');
    expect(video.videoThumbnail, endsWith('/hq720.jpg'));
  });
}
