import AppKit
import Combine
import SwiftUI
import OSLog

@MainActor
final class PlayLinkAppDelegate: NSObject, NSApplicationDelegate {
    private let model = PlayLinkModel()
    private var controller: MenuBarController?
    private let outputLifetime = OutputLifetime()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installAppMenu()
        controller = MenuBarController(model: model)
        model.onPreviousOutput = { [weak self] uid in self?.outputLifetime.remember(uid) }
        model.onOutputAvailable = { [weak self] in self?.outputLifetime.tuneBuffer() }
        outputLifetime.onFailure = { [weak self] in
            self?.model.stop()
            self?.model.error = "The audio output monitor stopped. Restart Playstation Airplay."
        }
        do { try outputLifetime.start() }
        catch { model.error = error.localizedDescription }
        model.beginObservingOutput()
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if !loginLaunch { controller?.showWindow() }
    }

    func applicationDidBecomeActive(_ notification: Notification) { model.refreshLoginStatus() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.stop()
        Task {
            await model.finishStopping()
            do { try outputLifetime.finish() }
            catch { model.error = error.localizedDescription }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func installAppMenu() {
        let menuBar = NSMenu()
        let application = NSMenuItem()
        menuBar.addItem(application)
        let appMenu = NSMenu(title: "Playstation Airplay")
        appMenu.addItem(withTitle: "Quit Playstation Airplay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = appMenu
        let edit = NSMenuItem()
        menuBar.addItem(edit)
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
        ] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        edit.submenu = editMenu
        NSApp.mainMenu = menuBar
    }
}

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let model: PlayLinkModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var window: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "de.raudzis.playlink", category: "MenuBar")
    private let appIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    init(model: PlayLinkModel) {
        self.model = model
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        model.$active.combineLatest(model.$transmitting, model.$error, model.$status)
            .sink { [weak self] active, transmitting, error, status in
                // @Published emits before assignment; use the emitted snapshot.
                self?.updateIcon(active: active, transmitting: transmitting, error: error, status: status)
            }.store(in: &subscriptions)
    }

    @objc func showWindow() {
        if window == nil {
            let hosting = NSHostingView(rootView: ContentView(model: model))
            hosting.sizingOptions = [.minSize, .maxSize]
            let size = hosting.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Playstation Airplay"
            window.setAccessibilityIdentifier("PlaystationAirplayMainWindow")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = hosting
            window.setContentSize(size)
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        logger.notice("Window hidden: visible=\(sender.isVisible) statusItemVisible=\(self.item.isVisible) activationPolicy=\(NSApp.activationPolicy().rawValue)")
        return false
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.refreshOutput()
        menu.removeAllItems()
        let status = NSMenuItem(title: model.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        add("Open Playstation Airplay…", action: #selector(showWindow), to: menu)
        let streaming = add(model.active ? "Stop streaming" : "Start streaming",
            action: #selector(toggleStream), to: menu)
        streaming.isEnabled = model.active || (model.outputAvailable && !model.editingConnection)
        menu.addItem(.separator())
        add("Quit Playstation Airplay", action: #selector(quit), key: "q", to: menu)
    }

    @discardableResult
    private func add(_ title: String, action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    @objc private func toggleStream() {
        if model.active { model.stop() }
        else {
            model.start()
            if !model.error.isEmpty { showWindow() }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func updateIcon(active: Bool, transmitting: Bool, error: String, status: String) {
        let color: NSColor
        let state: String
        if !error.isEmpty { color = .systemRed; state = "Error" }
        else if transmitting { color = .systemGreen; state = "Streaming" }
        else if active { color = .systemOrange; state = "Connecting" }
        else { color = .secondaryLabelColor; state = "Stopped" }

        let icon = appIcon
        let image = NSImage(size: NSSize(width: 27, height: 18), flipped: false) { _ in
            if let icon {
                icon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            } else {
                let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
                symbol?.draw(in: NSRect(x: 0, y: 1, width: 18, height: 16))
            }
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 21, y: 2, width: 5, height: 5)).fill()
            return true
        }
        image.isTemplate = false
        item.button?.image = image
        item.button?.toolTip = "Playstation Airplay — \(state): \(status)"
        item.button?.setAccessibilityLabel("Playstation Airplay — \(state)")
    }
}
