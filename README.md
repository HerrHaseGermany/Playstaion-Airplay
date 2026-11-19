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

The driver installs at `/Library/Audio/Plug-Ins/HAL/PlaystationAirplay.driver`. It adds no microphone input, kernel extension or background service. Nothing restarts Core Audio automatically.

This test build's app, setup helpers and driver are signed with the local Apple Development identity. The driver installer package is unsigned, and the release is not notarized. It is intended for local testing.

## Discord setup

1. Create an application in the [Discord Developer Portal](https://discord.com/developers/applications), then obtain a token on its **Bot** page.
2. Enter the token in the app. It is stored in macOS Keychain when connecting. **Forget** removes it. Do not share the token or commit it to source control.
3. Copy your application's **Application ID** from **General Information**. Use **Bot setup…** in the app to invite the bot with **View Channels**, **Connect** and **Speak**. Privileged intents are not needed.
4. Allow the bot and your PlayStation Discord account to join your server voice channel. For a private channel, grant the bot access explicitly. DM calls and Stage channels are not supported.
5. Enable Discord **Developer Mode** under **Settings → Advanced**, then right-click the voice channel and copy its channel ID into the app.

## Listening and volume

1. Choose **Playstation Airplay** in macOS **Sound → Output**, or select **Use as output** in the app.
2. Select **Start streaming**. Allow **System Audio Recording Only** if requested, then relaunch the app if macOS requires it. Screen and microphone access are not needed.
3. Join the same voice channel on your PlayStation. Audio playing on the Mac is sent as the bot's voice.

Mac volume keys, system volume and mute control the outgoing audio. The app's own stream level is an additional gain control and is saved between launches. If the app shows **Update output…**, install the bundled driver and restart to load its volume controls.

The virtual output is silent locally. Switch to your Mac speakers or headphones when you want local playback. If the virtual output remains selected while streaming is stopped, sound stays silent.

Closing the window keeps the app and stream running without a Dock icon. Use the menu bar icon to reopen the window, start/stop or quit. Its status dot is gray when stopped, orange while connecting/reconnecting, green while streaming, and red on error.

## Privacy and limitations

- The app uses a Core Audio process tap for audio routed to its virtual output. It does not capture the screen or microphone. If an earlier development build has screen access, disable that permission and retain only system-audio access in macOS Privacy & Security.
- The Discord desktop app and Playstation Airplay are excluded to prevent feedback. Browser-based Discord is not excluded.
- Everyone in the voice channel can hear the stream. The bot deafens itself and does not record participants. Audio travels through Discord.
- Audio is converted to 48 kHz stereo PCM and encoded as Opus, capped at the channel bitrate and 128 kbps. Discord and PlayStation may affect quality and playback behavior.
- Local buffering is bounded: two pending PCM frames (40 ms) and one encoded packet (20 ms). Capture requests 128-frame I/O where supported. These values do not describe total latency; network, Discord and receiver buffers still apply.
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
