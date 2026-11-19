import SwiftUI
import AppKit
import Darwin

@MainActor
final class PlayLinkModel: ObservableObject {
    @Published var token = TokenStore.load()
    @Published var channelID = UserDefaults.standard.string(forKey: "channelID") ?? ""
    @Published var status = "Ready to connect"
    @Published var error = ""
    @Published var active = false
    @Published var transmitting = false
    @Published var level: Float = 0
    @Published var outputInstalled = VirtualOutput.deviceID() != nil
    @Published var systemVolumeAvailable = VirtualOutput.supportsSystemVolume()
    @Published var outputSelected = false
    @Published var volume: Double = UserDefaults.standard.object(forKey: "streamVolume") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "streamVolume")
            capture?.setGain(Float(volume))
        }
    }
    private var bridge: DiscordBridge?
    private var capture: AudioCapture?
    private var session = UUID()
    private var startup: Task<Void, Never>?

    func start() {
        guard !active else { return }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, channel.range(of: "^[0-9]{17,20}$", options: .regularExpression) != nil else {
            error = "Enter a bot token and a valid voice channel ID."; return
        }
        error = ""
        active = true
        status = "Preparing system audio…"
        let id = UUID()
        session = id
        let audio = AudioCapture()
        capture = audio
        audio.setGain(Float(volume))
        audio.onLevel = { [weak self] value in Task { @MainActor in
            guard self?.session == id else { return }; self?.level = value
        } }
        audio.onError = { [weak self] text in Task { @MainActor in
            guard self?.session == id else { return }; self?.fail(text)
        } }
        startup = Task { [self] in
            do {
                try TokenStore.save(token)
                UserDefaults.standard.set(channel, forKey: "channelID")
                try await audio.prepare()
                guard session == id, !Task.isCancelled else { await audio.stop(); return }
                let sender = DiscordBridge()
                bridge = sender
                sender.onEvent = { [weak self, weak sender] kind, text in Task { @MainActor in
                    guard let self, self.session == id else { return }
                    switch kind {
                    case "ready":
                        guard let sender else { return }
                        do {
                            try await audio.start(descriptor: sender.descriptor)
                            guard self.session == id else { await audio.stop(); return }
                            self.transmitting = true
                            self.status = "Streaming to \(text)"
                        } catch { if self.session == id { self.fail(error.localizedDescription) } }
                    case "error": self.fail(text)
                    case "reconnecting": self.transmitting = false; self.status = text
                    case "reconnected": self.transmitting = true; self.status = text
                    default: self.status = text
                    }
                } }
                sender.onExit = { [weak self] code in Task { @MainActor in
                    guard self?.session == id else { return }
                    // Let the final structured error reach the UI first.
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if self?.session == id { self?.fail("Discord sender stopped (\(code)). Check the token and channel permissions.") }
                } }
                try sender.start(token: token, channelID: channel)
            } catch {
                if session == id { fail(error.localizedDescription) }
            }
        }
    }

    func stop() {
        session = UUID()
        startup?.cancel()
        startup = nil
        let oldCapture = capture
        let oldBridge = bridge
        capture = nil
        bridge = nil
        // Stop callbacks before closing or terminating the pipe's reader.
        Task { await oldCapture?.stop(); oldBridge?.stop() }
        active = false
        transmitting = false
        level = 0
        status = "Stopped"
    }

    private func fail(_ text: String) {
        stop()
        error = text.replacingOccurrences(of: token, with: "[redacted]")
        status = "Unable to stream"
    }

    func forgetToken() { TokenStore.delete(); token = "" }

    func refreshOutput() {
        let device = VirtualOutput.deviceID()
        outputInstalled = device != nil
        systemVolumeAvailable = VirtualOutput.supportsSystemVolume()
        outputSelected = device != nil && VirtualOutput.defaultDevice() == device
    }

    func selectOutput() {
        do { try VirtualOutput.select(); refreshOutput() }
        catch { self.error = error.localizedDescription }
    }

    func installOutput() {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Playstation Airplay Audio Output.pkg"),
              FileManager.default.fileExists(atPath: url.path) else {
            error = "The audio output installer is missing. Rebuild the app."; return
        }
        NSWorkspace.shared.open(url)
    }
}

@main
@MainActor
struct PlayLinkApp {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = PlayLinkAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

struct ContentView: View {
    @ObservedObject var model: PlayLinkModel
    @State private var showSetup = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   let icon = NSImage(contentsOf: url) {
                    Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                } else {
                    Image(systemName: "waveform.path").font(.system(size: 30)).foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Playstation Airplay").font(.title2.bold())
                    Text("Mac audio → Discord → PlayStation").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showSetup = true } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain).help("Bot setup")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Bot token").font(.caption).foregroundStyle(.secondary)
                SecureField("Paste your Discord bot token", text: $model.token)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Saved in macOS Keychain when connecting.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget", action: model.forgetToken).font(.caption)
                }
                Text("Voice channel ID").font(.caption).foregroundStyle(.secondary)
                TextField("Right-click the Discord voice channel → Copy Channel ID", text: $model.channelID)
                    .textFieldStyle(.roundedBorder)
            }.disabled(model.active)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Audio output").font(.caption).foregroundStyle(.secondary)
                    Text(model.outputInstalled && !model.systemVolumeAvailable ? "Update output for Mac volume keys" :
                         model.outputSelected ? "Playstation Airplay selected" :
                         model.outputInstalled ? "Choose Playstation Airplay to silence Mac speakers" :
                         "Install once, then restart your Mac")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.outputInstalled && model.systemVolumeAvailable {
                    Button("Use as output", action: model.selectOutput).disabled(model.outputSelected)
                } else {
                    Button(model.outputInstalled ? "Update output…" : "Install output…", action: model.installOutput)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle().fill(model.transmitting ? .green : .secondary).frame(width: 7, height: 7)
                    Text(model.status).font(.callout).lineLimit(2)
                    Spacer()
                }
                ProgressView(value: Double(model.level)).tint(.green)
                HStack {
                    Image(systemName: "speaker.fill")
                    Slider(value: $model.volume, in: 0...1)
                    Text("\(Int(model.volume * 100))%").monospacedDigit().frame(width: 38)
                }
            }
            if !model.error.isEmpty {
                Text(model.error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            Text("Streams audio sent to the Playstation Airplay output, excluding Discord. Everyone in the selected voice channel can hear it. Choose another Mac output for local playback.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Bot setup…") { showSetup = true }
                Spacer()
                Button(model.active ? "Stop streaming" : "Start streaming") {
                    if model.active { model.stop() } else { model.start() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [])
                    .disabled(!model.active && !model.outputInstalled)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear { model.refreshOutput() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in model.refreshOutput() }
        .sheet(isPresented: $showSetup) { SetupView() }
    }
}

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var applicationID = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up your Discord bot").font(.title2.bold())
            Text("1. Create an application in the Discord Developer Portal. On its Bot page, get a bot token and paste it into Playstation Airplay. Keep it private.")
            Link("Open Discord Developer Portal", destination: URL(string: "https://discord.com/developers/applications")!)
            Text("2. Copy the Application ID from General Information. Invite the bot to your server with View Channels, Connect, and Speak. No privileged intents or Administrator permission are needed.")
            HStack {
                TextField("Application ID", text: $applicationID).textFieldStyle(.roundedBorder)
                Button("Invite bot") {
                    guard let url = URL(string: "https://discord.com/oauth2/authorize?client_id=\(applicationID)&scope=bot&permissions=3146752") else { return }
                    NSWorkspace.shared.open(url)
                }.disabled(applicationID.range(of: "^[0-9]{17,20}$", options: .regularExpression) == nil)
            }
            Text("3. In Discord, enable Settings → Advanced → Developer Mode. Create a private voice channel accessible to you and the bot. Right-click it → Copy Channel ID, then paste it into Playstation Airplay.")
            Text("4. Start streaming and allow macOS system audio recording only. Screen recording permission is not needed. If macOS asks, quit and reopen Playstation Airplay after granting audio access. Join the same voice channel on your PS5.")
            Text("Use Discord in the desktop app if you also run it on this Mac. Browser audio is included in the stream. Protected media may not be capturable.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 520)
    }
}
