# Playstation Airplay

**0.1.0 · First test release**

Send your Mac's audio to a Discord server voice channel and listen on your PlayStation alongside game audio. A selectable **Playstation Airplay** output routes sound to the bot, while the native Mac app runs in the menu bar.

## Requirements

- macOS 14.2 or newer. The app and setup helpers target the architecture of the Mac used to build them; the audio driver supports Apple silicon and Intel.
- A Discord bot, a regular server voice channel, and a PlayStation account linked to Discord.
- Administrator authorization and a Mac restart for the audio driver installation or removal.

The app includes its Node runtime. Node and Xcode tools are only needed when building from source.

## Installation

Extract **Playstation Airplay-0.1.0.zip**, then open **Install Playstation Airplay.app**.

1. Select **1. Install app**. This installs to `~/Applications/Playstation Airplay.app`, preserving your settings and token. A replaced app is moved to Trash.
2. Select **2. Install audio output…** and complete the macOS installer. Restart your Mac to load the driver. Skip this step if your existing output already works with volume and mute controls.
3. Open the installed app with **Open app** or Finder.

The driver installs at `/Library/Audio/Plug-Ins/HAL/PlaystationAirplay.driver`. It adds no microphone input, kernel extension or persistent background service. Nothing restarts Core Audio automatically.

This test build's app, setup helpers and driver are signed with the local Apple Development identity. The driver installer package is unsigned, and the release is not notarized. It is intended for local testing.

## Discord setup

1. Create an application in the [Discord Developer Portal](https://discord.com/developers/applications), then obtain a token on its **Bot** page.
2. Select **Edit** under **Bot settings**, enter the token and the channel/user ID, then select **Save**. The token is stored in macOS Keychain, and the fields are locked against accidental edits. **Cancel** restores the saved configuration without applying drafts. **Forget** is available while editing and removes the saved token. Do not share the token or commit it to source control.
3. Copy your application's **Application ID** from **General Information**. Use **Bot setup…** in the app to invite the bot with **View Channels**, **Connect** and **Speak**. Privileged intents are not needed.
4. Allow the bot and your PlayStation Discord account to join your server voice channel. For a private channel, grant the bot access explicitly. DM calls and Stage channels are not supported.
5. Enable Discord **Developer Mode** under **Settings → Advanced**, then right-click the voice channel and copy its channel ID into the app.

## Listening and volume

1. Save your bot settings, then select **Start streaming**. The app remembers your current audio output and selects **Playstation Airplay** automatically. Alternatively, choose **Playstation Airplay** in macOS **Sound → Output**, or select **Use as output** in the app.
2. Selecting this output also starts streaming automatically while the app is running, including if it is already selected when the app launches. Allow **System Audio Recording Only** if requested, then relaunch the app if macOS requires it. Screen and microphone access are not needed.
3. Join the same voice channel on your PlayStation. Audio playing on the Mac is sent as the bot's voice.

Mac volume keys, system volume and mute control the outgoing audio. The app's own stream level is an additional gain control and is saved between launches. If the app shows **Update output…**, install the bundled driver and restart to load its volume controls.

The virtual output is silent locally. **Stop streaming**, quitting the app, or a streaming failure restores the previous audio output if Playstation Airplay is still selected. If the previous device is unavailable, the app uses an available built-in output. If the app launched with Playstation Airplay already selected and has not observed another output, it also uses that built-in fallback. If no suitable output is available, the app reports an error so you can select one manually.

Switching to speakers or headphones yourself stops streaming and disconnects the bot. The app keeps your manual choice and never replaces it during cleanup. Selecting Playstation Airplay again reconnects the bot. A stopped or failed stream stays stopped until you select **Start streaming**, select Playstation Airplay again, or relaunch with it selected.

The **Playstation Airplay** audio output is published while the app runs, including with its window closed. Quitting restores local output first, then removes Playstation Airplay from the sound output list. A separate lightweight monitor watches the app process; if it crashes or is force-quit, the monitor restores the last known available output (or a built-in fallback) and removes the virtual output. The monitor exits afterward. If no safe output is available, the virtual output stays visible so you can choose one manually.

Enable **Launch at login** to open the app automatically when you sign in to your Mac. Login launches stay in the menu bar without opening the window. If macOS requires approval, use **Allow in Login Items…**. The switch reflects the macOS login-item status.

By default the bot joins your saved **Voice channel ID**. Select **Edit** to change the bot settings. Optionally enable **Follow user**, then enter your **Discord user ID** in the now-active field and select **Save**. Enable Discord Developer Mode, right-click your profile and select **Copy User ID**; use the Discord account linked to your PlayStation. The fixed channel field is disabled while following, but its value is kept. Streaming cannot start while you have unsaved bot settings; save or cancel first. Hover over the **ⓘ** icons beside token/ID fields for instructions.

While streaming is enabled, the bot joins your current regular server voice channel, follows channel changes, and disconnects when you leave. While you are outside voice, it waits without broadcasting; audio received during waiting or channel changes is discarded. The bot must already be a member of each server and have **View Channel**, **Connect** and **Speak** in each destination. DM calls and Stage channels are not supported. If a destination is inaccessible, the app shows a waiting message; switch channels or stop/start to retry. Ambiguous voice states across multiple servers cause the bot to wait rather than choose an arbitrary channel. Changing the Mac audio output away from Playstation Airplay ends following and streaming.

Closing the window keeps the app and stream running without a Dock icon. Use the menu bar icon to reopen the window, start/stop or quit. Its status dot is gray when stopped, orange while connecting/reconnecting, green while streaming, and red on error.

Stopping cuts audio immediately, asks Discord to remove the bot from voice, and waits up to three seconds for the server acknowledgement before logging out. Logout is bounded to five seconds overall; if the sender becomes unresponsive, the app ends it after seven seconds. With a healthy connection, the bot should leave promptly. During network failures, Discord may still show it until its own timeout.

## Privacy and limitations

- The app uses a Core Audio process tap for audio routed to its virtual output. It does not capture the screen or microphone. If an earlier development build has screen access, disable that permission and retain only system-audio access in macOS Privacy & Security.
- The Discord desktop app and Playstation Airplay are excluded to prevent feedback. Browser-based Discord is not excluded.
- Everyone in the voice channel can hear the stream. The bot deafens itself and does not record participants. Audio travels through Discord.
- Audio is converted to 48 kHz stereo PCM and encoded using Opus restricted-low-delay mode, capped at the channel bitrate and 128 kbps. Discord's 20 ms packet cadence is preserved. This mode removes speech-mode lookahead; it uses CELT rather than the speech-optimized codec modes.
- A deterministic encode/decode signal comparison measured codec delay dropping from 312 to 120 samples (6.5 to 2.5 ms). This is a 4 ms codec-only improvement, not a measurement of total Mac-to-PlayStation latency. Run `node scripts/measure-codec-delay.mjs` to repeat it.
- Local buffering is bounded: two pending PCM frames (40 ms) and one encoded packet (20 ms). Capture requests 128-frame I/O where supported. The app also requests 128 frames for its own virtual output if its existing buffer is larger and the device supports it. The original value is forwarded to the process monitor before changing it and restored on app exit/crash unless another client changed it afterward. Physical outputs are not tuned. These buffer sizes do not describe total latency; network, Discord and receiver buffers still apply.
- DRM-protected audio may be unavailable. Stop before sleeping the Mac; after network or device changes, reconnect if needed.

The installer has been exercised on the development Mac. The uninstaller confirmation/cancel flow has been checked; actual removal still needs a dedicated test.

The initial listening test confirmed a substantial latency improvement. Extended stability, sleep/wake, reconnect behavior and long sessions are part of this test phase.

## Uninstallation

Open **Uninstall Playstation Airplay.app** from the extracted test release and select **Uninstall…**. Review its confirmation before proceeding.

The uninstaller quits the app, moves `~/Applications/Playstation Airplay.app` to Trash, and removes only its identity-checked audio driver. If the virtual output is selected, it switches to a built-in output first; if none is available, select another output manually. Administrator authorization is requested for driver removal. Restart afterward to unload it.

The bot token and preferences are kept for reinstallation. To remove the token, select **Forget** in the main app before uninstalling. The Discord bot and server permissions are not removed. You can delete the extracted setup apps after use.

## Building and checks

Requires Xcode command-line tools and Node.js 22.12 or newer.

```sh
npm run build
```

By default this builds the app into `~/Applications`, outside the synced Documents folder. Set `PLAYLINK_BUILD_DIR` to stage elsewhere. `CODE_SIGN_IDENTITY` overrides the automatically selected Apple Development identity; without one, the build uses ad hoc signing.

Outputs:

- `dist/Playstation Airplay-0.1.0.zip`: installer, uninstaller, README and changelog.
- `dist/Playstation Airplay.zip`: standalone app.
- `dist/Playstation Airplay Audio Output.pkg`: driver installer.

The helper apps are staged under `~/Library/Developer/PlayLink/Distribution/0.1.0`; override with `PLAYLINK_DISTRIBUTION_DIR`. Installation/removal must be exercised deliberately on a test system; the build never runs the uninstaller.

```sh
npm test
npm run doctor
swift test
bash scripts/build-driver.sh
xcrun clang -O2 -fblocks -framework CoreAudio -framework CoreFoundation Driver/TestDriver.c -o .build/driver/TestDriver
.build/driver/TestDriver
```

Checks cover PCM conversion, app/system gain and mute, backpressure, bounded queues, Opus encoding and the driver's interface. `doctor` checks voice/DAVE dependencies. The backend receives its token and channel configuration over stdin rather than command-line arguments. FFmpeg is not required.

See [CHANGELOG.md](CHANGELOG.md) for the test baseline and [Driver/README.md](Driver/README.md) for the audio driver's design and Apple's MIT-licensed sample provenance.
