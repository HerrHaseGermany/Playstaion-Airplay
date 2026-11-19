import AppKit
import CoreAudio

@main
@MainActor
struct SetupMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = SetupDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class SetupDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var status: NSTextField!
    private let uninstall = Bundle.main.bundleIdentifier?.hasSuffix(".uninstall") == true
    private var appURL: URL { FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/Playstation Airplay.app") }
    private let driverPath = "/Library/Audio/Plug-Ins/HAL/PlaystationAirplay.driver"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let title = uninstall ? "Uninstall Playstation Airplay" : "Install Playstation Airplay"
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 21)
        stack.addArrangedSubview(heading)
        let description = NSTextField(wrappingLabelWithString: uninstall ?
            "Removes the app from your Applications folder and its audio output driver. Your bot token and settings are kept. Administrator authorization is needed to remove the driver. Restart your Mac afterward." :
            "Install the app in your own Applications folder, then install the audio output driver. The driver installer needs administrator authorization and a restart. Existing bot settings are kept.")
        stack.addArrangedSubview(description)
        status = NSTextField(wrappingLabelWithString: uninstall ?
            "If Playstation Airplay is selected as your output, sound will be switched to a built-in output before removal." :
            "App destination: \(appURL.path)")
        status.textColor = .secondaryLabelColor
        stack.addArrangedSubview(status)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        if uninstall {
            buttons.addArrangedSubview(NSButton(title: "Uninstall…", target: self, action: #selector(remove)))
        } else {
            buttons.addArrangedSubview(NSButton(title: "1. Install app", target: self, action: #selector(installApp)))
            buttons.addArrangedSubview(NSButton(title: "2. Install audio output…", target: self, action: #selector(installDriver)))
            buttons.addArrangedSubview(NSButton(title: "Open app", target: self, action: #selector(openApp)))
        }
        stack.addArrangedSubview(buttons)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        let menu = NSMenu()
        let item = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu
        menu.addItem(item)
        NSApp.mainMenu = menu
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func stopApp() throws {
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "de.raudzis.playlink" {
            guard app.terminate() else { throw failure("Quit Playstation Airplay and try again.") }
        }
    }

    @objc private func installApp() {
        do {
            guard let source = Bundle.main.resourceURL?.appendingPathComponent("Playstation Airplay.app"),
                  Bundle(url: source)?.bundleIdentifier == "de.raudzis.playlink" else {
                throw failure("The bundled app is missing.")
            }
            if FileManager.default.fileExists(atPath: appURL.path),
               Bundle(url: appURL)?.bundleIdentifier != "de.raudzis.playlink" {
                throw failure("Another app already uses the destination name. Nothing was replaced.")
            }
            let parent = appURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = parent.appendingPathComponent(".PlaystationAirplay-\(UUID().uuidString).app")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: source, to: staging)
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            check.arguments = ["--verify", "--deep", "--strict", staging.path]
            try check.run()
            check.waitUntilExit()
            guard check.terminationStatus == 0 else { throw failure("App signature verification failed.") }
            try stopApp()
            var previous: NSURL?
            if FileManager.default.fileExists(atPath: appURL.path) {
                try FileManager.default.trashItem(at: appURL, resultingItemURL: &previous)
            }
            do { try FileManager.default.moveItem(at: staging, to: appURL) }
            catch {
                if let previous { try? FileManager.default.moveItem(at: previous as URL, to: appURL) }
                throw error
            }
            status.stringValue = "App installed. Continue with the audio output installer if it is not installed yet."
        } catch { show(error) }
    }

    @objc private func installDriver() {
        guard let package = Bundle.main.resourceURL?.appendingPathComponent("Playstation Airplay Audio Output.pkg"),
              FileManager.default.fileExists(atPath: package.path) else {
            show(failure("The audio output installer is missing.")); return
        }
        NSWorkspace.shared.open(package)
    }

    @objc private func openApp() {
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            show(failure("Install the app first.")); return
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
    }

    @objc private func remove() {
        let confirmation = NSAlert()
        confirmation.messageText = "Uninstall Playstation Airplay?"
        confirmation.informativeText = "The app will be moved to Trash. Its audio driver will be removed from /Library/Audio/Plug-Ins/HAL. Your token and preferences will stay. A restart is needed afterward."
        confirmation.addButton(withTitle: "Uninstall")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        do {
            if FileManager.default.fileExists(atPath: appURL.path),
               Bundle(url: appURL)?.bundleIdentifier != "de.raudzis.playlink" {
                throw failure("The app at the destination is not Playstation Airplay. Nothing was removed.")
            }
            try routeToBuiltInOutputIfNeeded()
            try stopApp()
            if FileManager.default.fileExists(atPath: driverPath) {
                // Only this fixed, identity-checked driver path is removed with elevation.
                let command = "set -eu; driver='/Library/Audio/Plug-Ins/HAL/PlaystationAirplay.driver'; test ! -L \"$driver\"; test \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$driver/Contents/Info.plist\")\" = 'de.raudzis.playlink.audio'; /bin/rm -rf \"$driver\"; /usr/sbin/pkgutil --forget de.raudzis.playlink.audio.pkg >/dev/null || true"
                let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                var error: NSDictionary?
                NSAppleScript(source: "do shell script \"\(literal)\" with administrator privileges with prompt \"Remove the Playstation Airplay audio driver.\"")?
                    .executeAndReturnError(&error)
                if let error { throw failure(error[NSAppleScript.errorMessage] as? String ?? "Driver removal was cancelled.") }
                guard !FileManager.default.fileExists(atPath: driverPath) else { throw failure("The audio driver was not removed.") }
            }
            if FileManager.default.fileExists(atPath: appURL.path) {
                try FileManager.default.trashItem(at: appURL, resultingItemURL: nil)
            }
            status.stringValue = "Uninstalled. Token and settings were kept. Restart your Mac to unload the audio driver."
        } catch { show(error) }
    }

    private func routeToBuiltInOutputIfNeeded() throws {
        func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
            .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        }
        func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
            var property = address(selector)
            var size = UInt32(MemoryLayout<CFString>.size)
            var result: CFString = "" as CFString
            let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0) }
            return status == noErr ? result as String : nil
        }
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var current: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &current) == noErr,
              string(current, kAudioDevicePropertyDeviceUID) == "de.raudzis.playlink.output" else { return }
        var listProperty = address(kAudioHardwarePropertyDevices)
        try check(AudioObjectGetPropertyDataSize(system, &listProperty, 0, nil, &size))
        guard size > 0 else { throw failure("Choose another Mac sound output before uninstalling.") }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &listProperty, 0, nil, &size, $0.baseAddress!) }
        try check(status)
        for var device in devices {
            var transportProperty = address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var streamsProperty = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyData(device, &transportProperty, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn,
                  AudioObjectGetPropertyDataSize(device, &streamsProperty, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0 else { continue }
            try check(AudioObjectSetPropertyData(system, &property, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device))
            return
        }
        throw failure("Choose another Mac sound output before uninstalling.")
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw failure("Could not switch the sound output (\(status)). Choose another output and try again.") }
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "PlaystationAirplaySetup", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func show(_ error: Error) { let alert = NSAlert(error: error); alert.runModal() }
}
