# Playstation Airplay virtual output

This output-only HAL plug-in is adapted from Apple's MIT-licensed NullAudio sample. The original source is preserved under `Vendor/`; `PlaystationAirplay.c` publishes a stereo output stream with standard output volume and mute controls, without microphone inputs or sample data-source controls.

Source: https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in

Archive: https://docs-assets.developer.apple.com/published/430ad6501f6f/CreatingAnAudioServerDriverPlugIn.zip

The app publishes this output on launch and releases it on exit through the driver's existing box-acquisition property (`kAudioBoxPropertyAcquired`). A short-lived app-owned process monitor handles unexpected host termination as well. The driver remains installed while its device is unpublished; no Core Audio restart or reinstallation is required to show it again.

The output discards hardware writes. The Mac app captures process audio routed to this device through an audio-only Core Audio tap and sends it to Discord. No physical speakers or microphone are used by this device.

The app observes the HAL output volume and mute properties and applies them to PCM before Opus encoding, in addition to the app's stream level. The process tap captures upstream of the driver's output controls, so exposing controls alone would not change the transmitted audio. The output volume is persisted by the Core Audio host; its dB mapping matches the app's linear amplitude gain.

The installer writes only `/Library/Audio/Plug-Ins/HAL/PlaystationAirplay.driver` and requests a restart. It does not restart Core Audio during installation. To remove it, delete that driver bundle with administrator authorization, then restart macOS. Select another output before uninstalling.
