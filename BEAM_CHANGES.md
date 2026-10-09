# Changes in Beam

Beam is an independently maintained fork of Plezy, licensed under the included GPLv3 license. This snapshot preserves upstream copyright and dependency license notices.

The application name is Beam. The separate Beam search navigation tab was removed; the existing Search tab remains. Streaming configuration is available under Settings → Beam streaming. Old startup preferences targeting the removed tab fall back to the store.

The store uses the Halloween Blockbusta redesign: haunted props, a seasonal rack, scrolling library racks and a bounded poster cache. D-pad turns follow the engine's camera orientation. Holding OK does not advance multiple pickup/play stages. Back exits one stage at a time. Empty stores and the 2D fallback return focus to the sidebar.

Public source starts with fresh Git history. Personal API keys, OAuth registrations, private server defaults, signing keys, device logs and account data are excluded. Optional service registrations use build configuration rather than bundled credentials. No private Git history, emulator cores, firmware or retail game files are distributed.

Four pinned Git dependencies are included as local source snapshots, with repository and revision recorded in each `BEAM_PROVENANCE.json`. This avoids unavailable Git-cache revisions without silently upgrading dependencies. The YouTube library's embedded web-client API key query parameters were removed; those client variants require renewed live validation.

Android beta packaging targets the 32-bit Onn architecture. The patched torrent bridge and rclone are freshly compiled from identified source. LibretroDroid matches its official release byte for byte. The companion native source archive contains upstream sources, exact submodules and build instructions; native license notices are bundled with the app. The unused old standalone FFmpeg executable is excluded; client playback still uses libmpv's FFmpeg.

The Windows build uses Gradle's ZIP extraction instead of requiring an external unzip executable. Native ABI selection is explicit, and rclone no longer logs generated authentication credentials.

APK packaging verifies exact source/native inputs, notices and corresponding-source delivery. These checks are automated and do not claim human or legal review. See release notes for the observed device tests and remaining physical remote/performance limits.
