// PortableLayout.swift
// Menu bar app: press Ctrl+Opt+Cmd+D to snap Messages, Claude and Spotify
// into a fixed layout on your second (non-primary) monitor.
//
// Build:  swiftc PortableLayout.swift -o PortableLayout
// Run:    ./PortableLayout
//
// Layout values are fractions of the target screen (0-1), origin top-left.

import Cocoa
import ApplicationServices
import Carbon.HIToolbox

struct Slot {
    let name: String          // app name as shown in /Applications (without .app)
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
}

// ---- EDIT YOUR LAYOUT HERE ----
let layout: [Slot] = [
    Slot(name: "Messages", x: 0.0, y: 0.0, w: 0.4, h: 1.0),   // left column
    Slot(name: "Claude",   x: 0.4, y: 0.0, w: 0.6, h: 0.7),   // top right
    Slot(name: "Spotify",  x: 0.4, y: 0.7, w: 0.6, h: 0.3),   // bottom right
]
// --------------------------------

/// The screen to arrange onto: first non-primary screen, else the primary.
func targetScreen() -> NSScreen {
    let screens = NSScreen.screens
    return screens.count > 1 ? screens[1] : screens[0]
}

/// Convert a Cocoa rect (origin bottom-left of primary) to Accessibility coords (origin top-left).
func axRect(for slot: Slot, in screen: NSScreen) -> CGRect {
    let primaryHeight = NSScreen.screens[0].frame.height
    let f = screen.visibleFrame
    let topLeftY = primaryHeight - f.maxY
    return CGRect(
        x: f.minX + f.width * slot.x,
        y: topLeftY + f.height * slot.y,
        width: f.width * slot.w,
        height: f.height * slot.h
    )
}

func setFrame(of window: AXUIElement, to rect: CGRect) {
    var pos = rect.origin
    var size = rect.size
    // Set size, then position, then size again: avoids clamping when moving across displays.
    if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
    if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) }
    if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
}

func firstWindow(of app: NSRunningApplication) -> AXUIElement? {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return nil }
    return windows.first
}

func launch(_ name: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", name]
    try? p.run()
}

/// Place one app; if it isn't running or has no window yet, launch it and retry.
func place(_ slot: Slot, attempt: Int = 0, launched: Bool = false) {
    let running = NSWorkspace.shared.runningApplications.first { $0.localizedName == slot.name }

    if let app = running, let window = firstWindow(of: app) {
        setFrame(of: window, to: axRect(for: slot, in: targetScreen()))
        return
    }

    guard attempt < 12 else { return }   // give up after ~12 seconds
    if running == nil && !launched { launch(slot.name) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        place(slot, attempt: attempt + 1, launched: true)
    }
}

func arrange() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    guard AXIsProcessTrustedWithOptions(opts) else { return }  // prompts for permission
    for slot in layout { place(slot) }
}

// MARK: - App setup

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▦"

        let menu = NSMenu()
        let arrangeItem = NSMenuItem(title: "Arrange windows (⌃⌥⌘D)", action: #selector(arrangeClicked), keyEquivalent: "")
        arrangeItem.target = self
        menu.addItem(arrangeItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        registerHotKey()
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    @objc func arrangeClicked() { arrange() }

    func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            arrange()
            return noErr
        }, 1, &eventType, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x504C4159), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_D),
                            UInt32(cmdKey | optionKey | controlKey),
                            id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()