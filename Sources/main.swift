// main.swift
// App entry: one dashboard window that fills your external display.

import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let settings = SettingsStore()
    let spotify = SpotifyController()
    let messages = MessagesStore()
    let web = WebSessions()
    let calendar = CalendarStore()
    let stocks = StockStore()
    private var hotKeyRef: EventHotKeyRef?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "PortableDash"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 420, height: 400)
        window.backgroundColor = .black
        let host = NSHostingView(rootView:
            DashboardView()
                .environmentObject(settings)
                .environmentObject(spotify)
                .environmentObject(messages)
                .environmentObject(web)
                .environmentObject(calendar)
                .environmentObject(stocks))
        host.sizingOptions = []   // content never forces the window bigger than the screen
        window.contentView = host

        fill(preferredScreen())
        settings.windowSize = window.frame.size
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        registerHotKey()
        setUpMenuBarIcon()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    /// Closing the window just hides it, so Claude stays logged in and loaded.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // MARK: Screens

    /// The external display if one is connected, otherwise the screen we're on.
    func preferredScreen() -> NSScreen {
        let external = NSScreen.screens.first { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return CGDisplayIsBuiltin(id) == 0
        }
        if settings.s.autoMoveToExternal, let external { return external }
        return window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func fill(_ screen: NSScreen) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        window.setFrame(screen.visibleFrame, display: true, animate: window.isVisible)
    }

    /// Monitor plugged in, unplugged or rotated: (re)fill the right screen.
    private func screensChanged() {
        guard window.isVisible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            let target = self.settings.s.autoMoveToExternal ? self.preferredScreen()
                                                            : (self.window.screen ?? self.preferredScreen())
            if self.window.frame != target.visibleFrame { self.fill(target) }
        }
    }

    func windowDidResize(_ notification: Notification) {
        settings.windowSize = window.frame.size
    }

    @objc func moveToNextDisplay() {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }
        let i = screens.firstIndex(of: window.screen ?? screens[0]) ?? 0
        fill(screens[(i + 1) % screens.count])
    }

    @objc func fillDisplay() { fill(window.screen ?? preferredScreen()) }

    func showDashboard() {
        if !window.isVisible { fill(preferredScreen()) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleDashboard() {
        if window.isVisible && NSApp.isActive && window.isKeyWindow { window.orderOut(nil) } else { showDashboard() }
    }

    // MARK: Menu actions

    @objc func toggleCustomize() { settings.showCustomize.toggle() }
    @objc func togglePrivacy() { settings.s.privacyMode.toggle() }
    @objc func toggleLock() { settings.s.lockLayout.toggle() }
    @objc func reloadClaude() { web.claude?.reload() }
    @objc func newClaudeChat() { web.claude?.goHome() }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func buildMenu() {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command,
                  target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }

        submenu("PortableDash", [
            item("About PortableDash", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Customize…", #selector(toggleCustomize), ",", target: self),
            .separator(),
            item("Hide PortableDash", #selector(NSApplication.hide(_:)), "h"),
            item("Quit PortableDash", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("View", [
            item("Privacy Mode", #selector(togglePrivacy), "p", [.command, .shift], target: self),
            item("Lock Layout", #selector(toggleLock), "l", [.command, .shift], target: self),
            .separator(),
            item("Reload Claude", #selector(reloadClaude), "r", target: self),
            item("New Claude Chat", #selector(newClaudeChat), "n", [.command, .shift], target: self),
            .separator(),
            item("Fill Display", #selector(fillDisplay), "f", [.command, .shift], target: self),
            item("Move to Next Display", #selector(moveToNextDisplay), "m", [.command, .shift], target: self),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.mainMenu = main
    }

    // MARK: Menu bar icon

    private func setUpMenuBarIcon() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarImage()
        item.button?.toolTip = "PortableDash"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// A tiny version of the dashboard layout; template images tint themselves for light/dark menu bars.
    static func menuBarImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let side = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2.5, width: 5.5, height: 13), xRadius: 1.6, yRadius: 1.6)
            let top = NSBezierPath(roundedRect: NSRect(x: 8.5, y: 7.5, width: 8, height: 8), xRadius: 1.6, yRadius: 1.6)
            let bottom = NSBezierPath(roundedRect: NSRect(x: 8.5, y: 2.5, width: 8, height: 3.5), xRadius: 1.2, yRadius: 1.2)
            side.fill(); top.fill(); bottom.fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: Global hotkey ⌃⌥⌘D

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { appDelegate.toggleDashboard() } }
            return noErr
        }, 1, &eventType, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5044_4153), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(cmdKey | optionKey | controlKey),
                            id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

let appDelegate = MainActor.assumeIsolated { AppDelegate() }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = appDelegate
app.run()

// The menu bar icon's menu is rebuilt each time it opens, so checkmarks are always current.
extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = [],
                 on: Bool = false) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            i.state = on ? .on : .off
            menu.addItem(i)
        }
        let visible = window.isVisible
        add(visible ? "Hide Dashboard" : "Show Dashboard", #selector(toggleFromMenuBar),
            key: "d", mods: [.control, .option, .command])
        menu.addItem(.separator())
        add("Privacy Mode", #selector(togglePrivacy), on: settings.s.privacyMode)
        add("Lock Layout", #selector(toggleLock), on: settings.s.lockLayout)
        menu.addItem(.separator())
        add("Fill Display", #selector(fillFromMenuBar))
        if NSScreen.screens.count > 1 { add("Move to Next Display", #selector(moveFromMenuBar)) }
        add("Customize…", #selector(customizeFromMenuBar))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit PortableDash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func toggleFromMenuBar() { window.isVisible ? window.orderOut(nil) : showDashboard() }
    @objc func fillFromMenuBar() { showDashboard(); fillDisplay() }
    @objc func moveFromMenuBar() { showDashboard(); moveToNextDisplay() }
    @objc func customizeFromMenuBar() { showDashboard(); settings.showCustomize = true }
}
