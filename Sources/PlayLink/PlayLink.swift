import SwiftUI
import AppKit
import Darwin
import ServiceManagement

@MainActor
final class PlayLinkModel: ObservableObject {
    @Published var token = TokenStore.load()
    @Published var channelID = UserDefaults.standard.string(forKey: "channelID") ?? ""
    @Published var followUser = UserDefaults.standard.bool(forKey: "followUser")
    @Published var userID = UserDefaults.standard.string(forKey: "followUserID") ?? ""
    @Published var editingConnection = false
    @Published var settingsError = ""
    @Published var status = "Ready to connect"
    @Published var error = ""
    @Published var active = false
    @Published var transmitting = false
    @Published var level: Float = 0
    @Published var outputInstalled = VirtualOutput.driverBox() != nil
    @Published var outputAvailable = VirtualOutput.deviceID() != nil
    @Published var systemVolumeAvailable = VirtualOutput.supportsSystemVolume()
    @Published var outputSelected = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginApprovalRequired = false
    @Published var loginError = ""
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
    private var cleanup: Task<Void, Never>?
    private let outputObserver = OutputDeviceObserver()
    private var outputSelection = OutputSelection()
    private let outputRouting = AudioOutputRouting()
    var onPreviousOutput: ((String) -> Void)?
    var onOutputAvailable: (() -> Void)?

    init() {
        editingConnection = token.isEmpty
        outputRouting.onRemember = { [weak self] uid in self?.onPreviousOutput?(uid) }
    }

    func editConnection() { settingsError = ""; editingConnection = true }

    func cancelConnectionEditing() {
        token = TokenStore.load()
        channelID = UserDefaults.standard.string(forKey: "channelID") ?? ""
        userID = UserDefaults.standard.string(forKey: "followUserID") ?? ""
        followUser = UserDefaults.standard.bool(forKey: "followUser")
        settingsError = ""
        editingConnection = false
    }

    func saveConnection() {
        let savedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !savedToken.isEmpty else { settingsError = "Enter a bot token."; return }
        guard (followUser ? user : channel).range(of: "^[0-9]{17,20}$", options: .regularExpression) != nil else {
            settingsError = followUser ? "Enter a valid Discord user ID to follow." : "Enter a valid voice channel ID."
            return
        }
        do {
            try TokenStore.save(savedToken)
            UserDefaults.standard.set(channel, forKey: "channelID")
            UserDefaults.standard.set(user, forKey: "followUserID")
            UserDefaults.standard.set(followUser, forKey: "followUser")
            token = savedToken
            channelID = channel
            userID = user
            settingsError = ""
            error = ""
            status = "Ready to connect"
            editingConnection = false
        } catch { settingsError = "Could not save the bot settings to Keychain." }
    }

    func beginObservingOutput() {
        refreshLoginStatus()
        do {
            try outputObserver.start { [weak self] in
                Task { @MainActor in self?.refreshOutput() }
            }
            refreshOutput()
        } catch { self.error = error.localizedDescription }
    }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginApprovalRequired = status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginError = ""
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { loginError = error.localizedDescription }
        refreshLoginStatus()
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    func start() {
        guard !active else { return }
        guard !editingConnection else {
            error = "Save or cancel your bot settings before starting."; return
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let following = followUser
        guard !token.isEmpty else { error = "Enter a bot token."; return }
        guard (following ? user : channel).range(of: "^[0-9]{17,20}$", options: .regularExpression) != nil else {
            error = following ? "Enter a valid Discord user ID to follow." : "Enter a valid voice channel ID."
            return
        }
        error = ""
        active = true
        do {
            try outputRouting.start()
            refreshOutput()
        } catch {
            fail(error.localizedDescription)
            return
        }
        status = "Preparing system audio…"
        let id = UUID()
        session = id
        let audio = AudioCapture()
        capture = audio
        audio.setGain(Float(volume))
        audio.onLevel = { [weak self] value in Task { @MainActor in
            guard self?.session == id else { return }
            self?.level = self?.transmitting == true ? value : 0
        } }
        audio.onError = { [weak self] text in Task { @MainActor in
            guard self?.session == id else { return }; self?.fail(text)
        } }
        startup = Task { [self] in
            do {
                await cleanup?.value
                guard session == id, !Task.isCancelled else { return }
                try await audio.prepare()
                guard session == id, !Task.isCancelled else { await audio.stop(); return }
                let sender = DiscordBridge()
                bridge = sender
                var audioStarted = false
                var voiceRevision = 0
                sender.onEvent = { [weak self, weak sender] kind, text in Task { @MainActor in
                    guard let self, self.session == id else { return }
                    switch kind {
                    case "ready":
                        guard let sender else { return }
                        voiceRevision += 1
                        let revision = voiceRevision
                        do {
                            if !audioStarted {
                                audioStarted = true
                                try await audio.start(descriptor: sender.descriptor)
                            }
                            guard self.session == id else { await audio.stop(); return }
                            guard voiceRevision == revision else { return }
                            self.transmitting = true
                            self.status = "Streaming to \(text)"
                        } catch { if self.session == id { self.fail(error.localizedDescription) } }
                    case "error": self.fail(text)
                    case "waiting":
                        voiceRevision += 1
                        self.transmitting = false
                        self.level = 0
                        self.status = text
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
                try sender.start(token: token, channelID: channel, followUser: following, userID: user)
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
        let previousCleanup = cleanup
        cleanup = Task {
            await previousCleanup?.value
            await oldCapture?.stop()
            await oldBridge?.stop()
        }
        active = false
        transmitting = false
        level = 0
        status = "Stopped"
        do { try outputRouting.restore() }
        catch { self.error = error.localizedDescription }
        refreshOutput()
    }

    func finishStopping() async { await cleanup?.value }

    private func fail(_ text: String) {
        stop()
        error = text.replacingOccurrences(of: token, with: "[redacted]")
        status = "Unable to stream"
    }

    func forgetToken() { TokenStore.delete(); token = ""; editingConnection = true }

    func refreshOutput() {
        outputRouting.observe()
        let device = VirtualOutput.deviceID()
        outputInstalled = VirtualOutput.driverBox() != nil
        outputAvailable = device != nil
        if outputAvailable { onOutputAvailable?() }
        systemVolumeAvailable = VirtualOutput.supportsSystemVolume()
        outputSelected = device != nil && VirtualOutput.defaultDevice() == device
        switch outputSelection.update(selected: outputSelected) {
        case .start: start()
        case .stop:
            if active { stop() }
        case nil: break
        }
    }

    func selectOutput() {
        do { try outputRouting.start(); refreshOutput() }
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
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == OutputLifetime.argument,
           let parent = pid_t(CommandLine.arguments[2]), parent > 1 {
            OutputLifetime.runMonitor(parent: parent)
        }
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
                HStack {
                    Text("Bot settings").font(.headline)
                    Spacer()
                    if model.editingConnection {
                        Button("Cancel", action: model.cancelConnectionEditing)
                        Button("Save", action: model.saveConnection).buttonStyle(.borderedProminent)
                    } else {
                        Button("Edit", action: model.editConnection)
                    }
                }.disabled(model.active)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 5) {
                        Text("Bot token").font(.caption).foregroundStyle(.secondary)
                        InfoTip(text: "Discord Developer Portal → Applications → your application → Bot → Reset Token / Copy. Use the bot token, never your personal Discord token.")
                    }
                    SecureField("Paste your Discord bot token", text: $model.token)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.active || !model.editingConnection)
                    HStack {
                        Text("Saved in macOS Keychain with Save.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Forget", action: model.forgetToken).font(.caption)
                            .disabled(model.active || !model.editingConnection)
                    }
                    HStack(spacing: 5) {
                        Text("Voice channel ID").font(.caption).foregroundStyle(.secondary)
                        InfoTip(text: "In Discord, enable Settings → Advanced → Developer Mode. Right-click a server voice channel → Copy Channel ID. The bot needs View Channel, Connect and Speak there.")
                    }
                    TextField("Right-click the Discord voice channel → Copy Channel ID", text: $model.channelID)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.followUser || model.active || !model.editingConnection)
                    Toggle("Follow user", isOn: $model.followUser).toggleStyle(.switch)
                        .disabled(model.active || !model.editingConnection)
                    HStack(spacing: 5) {
                        Text("Discord user ID").font(.caption).foregroundStyle(.secondary)
                        InfoTip(text: "In Discord, enable Settings → Advanced → Developer Mode. Right-click your profile → Copy User ID. Use the Discord account linked to your PlayStation. The bot can follow only in servers it has joined.")
                    }
                    TextField("Right-click your Discord profile → Copy User ID", text: $model.userID)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.followUser || model.active || !model.editingConnection)
                }
                if !model.settingsError.isEmpty {
                    Text(model.settingsError).font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Audio output").font(.caption).foregroundStyle(.secondary)
                    Text(model.outputInstalled && !model.outputAvailable ? "Preparing audio output…" :
                         model.outputInstalled && !model.systemVolumeAvailable ? "Update output for Mac volume keys" :
                         model.outputSelected ? "Playstation Airplay selected" :
                         model.outputInstalled ? "Start streaming to use Playstation Airplay" :
                         "Install once, then restart your Mac")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.outputInstalled && !model.outputAvailable {
                    ProgressView().controlSize(.small)
                } else if model.outputInstalled && model.systemVolumeAvailable {
                    Button("Use as output", action: model.selectOutput).disabled(model.outputSelected)
                } else {
                    Button(model.outputInstalled ? "Update output…" : "Install output…", action: model.installOutput)
                }
            }
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
            if model.loginApprovalRequired {
                Button("Allow in Login Items…", action: model.openLoginSettings)
            }
            if !model.loginError.isEmpty {
                Text(model.loginError).font(.caption).foregroundStyle(.red)
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
            Text(model.followUser
                 ? "Start streaming selects Playstation Airplay and follows your Discord account. Stop or quit restores your previous audio output. Your manual output changes take priority. Everyone in your voice channel can hear the stream."
                 : "Start streaming selects Playstation Airplay. Stop or quit restores your previous audio output. Selecting another output stops the stream and keeps your choice. Everyone in the selected voice channel can hear it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Bot setup…") { showSetup = true }
                Spacer()
                Button(model.active ? "Stop streaming" : "Start streaming") {
                    if model.active { model.stop() } else { model.start() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [])
                    .disabled(!model.active && !model.outputAvailable)
                    .disabled(!model.active && model.editingConnection)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear { model.refreshOutput(); model.refreshLoginStatus() }
        .sheet(isPresented: $showSetup) { SetupView() }
    }
}

struct InfoTip: View {
    let text: String
    var body: some View {
        Image(systemName: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .help(text).accessibilityLabel(text)
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
                InfoTip(text: "Discord Developer Portal → Applications → your application → General Information → Application ID → Copy. This identifies the bot application for its invite link; it is different from your user ID and channel ID.")
                Button("Invite bot") {
                    guard let url = URL(string: "https://discord.com/oauth2/authorize?client_id=\(applicationID)&scope=bot&permissions=3146752") else { return }
                    NSWorkspace.shared.open(url)
                }.disabled(applicationID.range(of: "^[0-9]{17,20}$", options: .regularExpression) == nil)
            }
            Text("3. In Discord, enable Settings → Advanced → Developer Mode. For a fixed channel, right-click a server voice channel → Copy Channel ID. To follow your account instead, enable Follow user and paste your profile's Copy User ID. The bot needs View Channel, Connect and Speak in every channel you use.")
            Text("4. Start streaming and allow macOS system audio recording only. Screen recording permission is not needed. If macOS asks, quit and reopen Playstation Airplay after granting audio access. Join the same voice channel on your PS5.")
            Text("Use Discord in the desktop app if you also run it on this Mac. Browser audio is included in the stream. Protected media may not be capturable.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 520)
    }
}
