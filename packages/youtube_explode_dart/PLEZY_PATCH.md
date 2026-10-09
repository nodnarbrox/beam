# YouTube extraction source

Vendored from https://github.com/Hexer10/youtube_explode_dart at
`44a39a65d8e274806247d52af8f0bacd77691d38` (3.1.0).
The upstream BSD-3-Clause LICENSE is included.

The compatibility patch is the `xml` constraint, raised from `^6.1.0`
to `^7.0.1` to match Plezy's existing dependency. Validate with the application
analyzer and `dart run tools/youtube_probe.dart` when updating this snapshot.

`StringUtility2.toDateTime` returns null for unknown relative dates instead of
throwing. A live related-video response containing `Streamed` in the quantity
position otherwise aborted the entire recommendations result.

Channel pages now read the current `lockupMetadataViewModel` title/date and
`contentImage/thumbnailViewModel` thumbnail/duration fields, with legacy fallbacks.
Verified against Blender's public channel on September 14, 2026 and the fixture
in `test/services/youtube_channel_page_test.dart`. Plezy falls back to the Videos
page when YouTube returns an empty uploads playlist for an active channel.

Plezy resolves media streams for its native player; it does not embed the
YouTube web player or launch a separate application. Extraction may need
updates when YouTube changes its service. Account-restricted content is not
supported by this library.
