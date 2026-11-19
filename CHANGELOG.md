# Changelog

## [0.1.0] - 2026-11-19

First test release. This version consolidates the development builds into a single test baseline; the earlier 0.2.x and 0.3.x labels were development versions.

### Added

- Native macOS menu bar app that sends audio to a Discord bot in a server voice channel for playback on PS5 alongside game audio.
- Selectable **Playstation Airplay** stereo audio output with Mac volume-key and mute support.
- System-audio-only capture through Core Audio taps, without screen recording or microphone access.
- Bot setup guidance, channel permission checks, Keychain token storage and a saved stream level.
- Menu bar status indicator and background streaming when the window is closed.
- Approved PlayStation/AirPlay app icon with transparent outer corners.
- Guided app/driver installation and an uninstaller that preserves settings and the bot token.

### Performance

- Direct, on-demand Opus encoding without an intermediate encoder stream.
- Bounded local queues: two pending PCM frames and one encoded packet.
- 128-frame capture I/O where supported.

### Validation and limits

- Local PCM conversion, gain, mute, buffering, Opus encoding and driver-interface checks pass.
- Live capture and Discord connections verified with screen access disabled.
- User confirmed that the latency improvement is suitable for the first test phase.
- App installation/update and reopening verified with saved settings intact. Uninstaller confirmation and cancellation verified; actual driver/app removal still needs a dedicated test.
- Extended stability, sleep/wake, network recovery and PS5 playback remain part of testing. Discord and receiver latency are outside the app's control.
