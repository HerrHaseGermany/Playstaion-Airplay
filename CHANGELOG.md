# Changelog

## Unreleased

- Use Opus restricted-low-delay encoding with the existing stereo bitrate cap and 20 ms Discord packets. A controlled comparison through the production stream measured codec signal delay at 120 samples instead of 312 (4 ms less at 48 kHz); end-to-end PS5 latency is not inferred from that test.
- Request a supported 128-frame buffer on the virtual output while the app runs, retaining already smaller buffers. Restore its original size on exit/crash unless another client changed it; forward the rollback value to the monitor before tuning. Physical outputs are unchanged.
- Latency validation: 39 automated tests pass, including an encode/decode signal comparison against the previous encoder mode. The installed app accepted a 512-to-128-frame virtual output change and streamed to Discord; normal exit and a controlled SIGKILL both restored 512 frames. End-to-end PS5 delay and perceptual audio quality still require a listening test.

- Publish the virtual output only while the app runs. A separate process monitor restores the previous output and unpublishes Airplay after an unexpected app exit, using the installed driver's existing acquisition support.
- Live validation confirmed output selection on Start, restoration on Stop/Quit, preservation of manual selections, disappearance/reappearance with app lifetime, and restoration/unpublishing after SIGKILL during an active Discord stream. Missing-device fallback is covered by routing tests; no physical device was unplugged for this test.

- Start streaming selects Playstation Airplay and remembers the previous audio output. Stop, quit and stream failures restore it, with a built-in output fallback for missing devices. Manual output changes take priority.

- Lock saved bot token, channel ID, user ID and follow mode until Edit is selected. Save validates and persists changes; Cancel restores the saved values. Unsaved settings cannot start streaming.

- Stop audio immediately, then wait for Discord to acknowledge the bot leaving voice before logging out. Bound acknowledgement/logout waits and wait for the sender to exit before reconnecting or quitting the app.
- Shutdown tests cover acknowledgement filtering, synchronous responses, missing responses and failure cleanup. Settings lock, validation, Save and Cancel were verified in the installed UI. Live Stop streaming received Discord departure acknowledgement in 139 ms and the sender exited; quitting during an active stream received acknowledgement in 158 ms and exited cleanly.

- Optional Follow user switch with a saved Discord user ID. Follow shared server voice-channel changes and leave when the user disconnects; keep the fixed channel setting available when following is off.
- Inline information tooltips explain where to find the bot token, voice channel ID, Discord user ID and application ID.
- Follow validation: automated tests cover initial voice state, channel moves, leaving, unrelated/mute events and cross-server availability. Installed UI verified for the optional switch, field enablement and all four information icons. Following a real user's Discord channel changes still needs a live test after entering their user ID.

- Start streaming when the Playstation Airplay output is selected, including at app launch; stop streaming and disconnect the bot when another output is selected.
- Observe audio output changes while the window is closed. Manual stops and errors remain stopped until an explicit retry or a new output selection.
- Add a Launch at login switch using macOS login items, with approval status and background login launches.
- Validation: real output changes started Discord streaming and stopped the sender, including a restart with the window hidden. Login-item registration and removal passed on the installed signed app; an actual logout/login launch remains untested.

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
