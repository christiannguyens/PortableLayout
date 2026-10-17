// Settings.swift
// Everything the user can customize, persisted to UserDefaults as JSON.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Panels & layout

/// Panels are identified by string: a built-in's raw value, or a web panel's id.
typealias PanelID = String

/// The three built-in panels.
enum PanelKind: String, Codable, CaseIterable, Identifiable {
    case messages, claude, spotify
    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: return "Messages"
        case .claude: return "Claude"
        case .spotify: return "Spotify"
        }
    }

    var symbol: String {
        switch self {
        case .messages: return "message.fill"
        case .claude: return "sparkle"
        case .spotify: return "music.note"
        }
    }
}

/// A user-added panel showing any website.
struct WebPanel: Codable, Equatable, Identifiable {
    var id: PanelID = "web-" + UUID().uuidString.prefix(8).lowercased()
    var title: String
    var url: String
    var symbol: String = "globe"
    var mobile = false        // present as an iPhone: better for narrow panels

    /// Adds https:// when the user typed a bare domain.
    static func normalize(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.contains("://") ? s : "https://" + s
    }

    static let presets: [WebPanel] = [
        WebPanel(title: "YouTube", url: "https://www.youtube.com", symbol: "play.rectangle.fill"),
        WebPanel(title: "YouTube Music", url: "https://music.youtube.com", symbol: "music.note.list"),
        WebPanel(title: "Lofi Radio", url: "https://www.youtube.com/watch?v=jfKfPfyJRdk", symbol: "headphones"),
        WebPanel(title: "Calendar", url: "https://calendar.google.com", symbol: "calendar"),
        WebPanel(title: "Gmail", url: "https://mail.google.com", symbol: "envelope.fill"),
        WebPanel(title: "Canvas", url: "https://wustl.instructure.com", symbol: "graduationcap.fill"),
        WebPanel(title: "Notion", url: "https://www.notion.so", symbol: "doc.text.fill"),
        WebPanel(title: "Google Docs", url: "https://docs.google.com", symbol: "doc.richtext"),
        WebPanel(title: "Keep", url: "https://keep.google.com", symbol: "note.text"),
        WebPanel(title: "Discord", url: "https://discord.com/app", symbol: "bubble.left.and.bubble.right.fill"),
        WebPanel(title: "WhatsApp", url: "https://web.whatsapp.com", symbol: "phone.bubble.fill"),
        WebPanel(title: "Desmos", url: "https://www.desmos.com/calculator", symbol: "function"),
    ]

    static let symbols = ["globe", "star.fill", "bolt.fill", "book.fill", "graduationcap.fill", "calendar",
                          "envelope.fill", "play.rectangle.fill", "music.note.list", "headphones",
                          "doc.text.fill", "checklist", "chart.bar.fill", "gamecontroller.fill",
                          "cart.fill", "newspaper.fill", "cloud.sun.fill", "heart.fill"]
}

enum LayoutPreset: String, Codable, CaseIterable, Identifiable {
    case sidebarLeft, sidebarRight, columns, rows, bottomStrip, topStrip, grid
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sidebarLeft: return "Sidebar left"
        case .sidebarRight: return "Sidebar right"
        case .columns: return "Columns"
        case .rows: return "Rows"
        case .bottomStrip: return "Bottom strip"
        case .topStrip: return "Top strip"
        case .grid: return "Grid"
        }
    }
}

enum PanelStyle: String, Codable, CaseIterable, Identifiable {
    case glass, frosted, solid
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum Ambient: String, Codable, CaseIterable, Identifiable {
    case none, orbs, stars, aurora
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

// MARK: - Colors & themes

struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double = 1

    init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        r = Double(ns.redComponent); g = Double(ns.greenComponent)
        b = Double(ns.blueComponent); a = Double(ns.alphaComponent)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

struct Theme: Identifiable {
    let id: String
    let name: String
    let colors: [RGBA]
    let accent: RGBA
    var isLight = false

    static let all: [Theme] = [
        Theme(id: "midnight", name: "Midnight", colors: [.init(hex: 0x0F1226), .init(hex: 0x1B1F4A), .init(hex: 0x3A1C5C)], accent: .init(hex: 0x8B7BFF)),
        Theme(id: "bear", name: "Bear Red", colors: [.init(hex: 0x14080A), .init(hex: 0x4D0F17), .init(hex: 0xA51417)], accent: .init(hex: 0xF0565A)),
        Theme(id: "olin", name: "Olin Green", colors: [.init(hex: 0x06120F), .init(hex: 0x0B3A30), .init(hex: 0x007360)], accent: .init(hex: 0x4FD1A8)),
        Theme(id: "sunset", name: "Sunset", colors: [.init(hex: 0x2B1132), .init(hex: 0x7A2A4F), .init(hex: 0xE0693A)], accent: .init(hex: 0xFF9A6B)),
        Theme(id: "ocean", name: "Ocean", colors: [.init(hex: 0x04121F), .init(hex: 0x0B3954), .init(hex: 0x087E8B)], accent: .init(hex: 0x48CAE4)),
        Theme(id: "mono", name: "Mono", colors: [.init(hex: 0x0A0A0A), .init(hex: 0x161616), .init(hex: 0x262626)], accent: .init(hex: 0x9CA3AF)),
        Theme(id: "paper", name: "Paper", colors: [.init(hex: 0xF4EFE6), .init(hex: 0xE9E1D2), .init(hex: 0xD8CBB4)], accent: .init(hex: 0xB5651D), isLight: true),
        Theme(id: "sakura", name: "Sakura", colors: [.init(hex: 0xFCEEF3), .init(hex: 0xF6D5E2), .init(hex: 0xE9B8CF)], accent: .init(hex: 0xD6457A), isLight: true),
    ]

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }
}

// MARK: - Settings model

struct DashSettings: Codable, Equatable {
    // Look
    var themeID = "midnight"
    var accent: RGBA? = nil              // nil = use the theme's accent
    var wallpaperPath: String? = nil
    var wallpaperDim = 0.3
    var wallpaperBlur = 0.0
    var ambient: Ambient = .orbs
    var panelStyle: PanelStyle = .glass
    var panelOpacity = 0.5
    var cornerRadius = 18.0
    var gap = 12.0
    var glow = true
    var showPanelTitles = true

    // Header
    var showHeader = true
    var greeting = "locked in 📚"
    var stickers = "🎧 ✨ 🐻"
    var use24Hour = false
    var showNextEvent = true
    var showTicker = true
    var tickerSymbols = "AAPL, NVDA, TSLA, MSFT, GOOGL, AMZN, META, SPY, BTC-USD"
    var tickerWidth = 300.0

    // Layout
    var preset: LayoutPreset = .sidebarLeft          // landscape monitor
    var portraitPreset: LayoutPreset = .rows         // sideways (vertical) monitor
    var order: [PanelID] = PanelKind.allCases.map(\.rawValue)
    var hidden: [PanelID] = []
    var webPanels: [WebPanel] = []
    var splits: [String: Double] = [:]
    var lockLayout = false

    // Behaviour
    var privacyMode = false
    var autoMoveToExternal = true
    var claudeHome = "https://claude.ai/new"
    var spotifyBrowse = false        // Spotify panel shows the web player for picking songs

    private static let key = "dashSettings.v1"

    /// Loads saved settings, filling in defaults for any keys added since they were saved.
    static func load() -> DashSettings {
        let defaults = DashSettings()
        guard let saved = UserDefaults.standard.data(forKey: key),
              let savedObj = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
              let defData = try? JSONEncoder().encode(defaults),
              var merged = try? JSONSerialization.jsonObject(with: defData) as? [String: Any]
        else { return defaults }
        merged.merge(savedObj) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              var s = try? JSONDecoder().decode(DashSettings.self, from: data)
        else { return defaults }
        s.normalize()
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Make sure every panel that exists appears exactly once in `order`.
    mutating func normalize() {
        let all = PanelKind.allCases.map(\.rawValue) + webPanels.map(\.id)
        var seen = Set<PanelID>()
        order = order.filter { all.contains($0) && seen.insert($0).inserted }
        order += all.filter { !seen.contains($0) }
        hidden = hidden.filter { all.contains($0) }
    }
}

// MARK: - Store

@MainActor
final class SettingsStore: ObservableObject {
    @Published var s: DashSettings {
        didSet {
            guard s != oldValue else { return }
            s.save()
            if s.wallpaperPath != oldValue.wallpaperPath { loadWallpaper() }
        }
    }
    @Published var showCustomize = false
    /// Divider positions while being dragged (committed to `s.splits` on release).
    @Published var liveSplits: [String: Double] = [:]
    @Published private(set) var wallpaper: NSImage?

    init() {
        s = DashSettings.load()
        loadWallpaper()
    }

    var theme: Theme { Theme.named(s.themeID) }
    var accentRGBA: RGBA { s.accent ?? theme.accent }
    var accent: Color { accentRGBA.color }
    /// Text color that reads well on top of the accent color.
    var onAccent: Color { accentRGBA.luminance > 0.62 ? .black : .white }

    /// Size of the dashboard window, kept up to date by the app delegate.
    @Published var windowSize: CGSize = .zero
    var isPortrait: Bool { windowSize.height > windowSize.width }
    /// Header wraps to two rows when the window is too narrow for one.
    var compactHeader: Bool { windowSize.width > 0 && windowSize.width < 1250 }

    /// Portrait and landscape each remember their own layout and divider sizes.
    var activePreset: LayoutPreset {
        get { isPortrait ? s.portraitPreset : s.preset }
        set { if isPortrait { s.portraitPreset = newValue } else { s.preset = newValue } }
    }
    var splitPrefix: String { isPortrait ? "p-" : "" }

    func resetSizes() {
        let portrait = isPortrait
        s.splits = s.splits.filter { $0.key.hasPrefix("p-") != portrait }
    }

    var visiblePanels: [PanelID] { s.order.filter { !s.hidden.contains($0) } }

    func fraction(_ key: String, _ defaultValue: Double) -> Double {
        liveSplits[key] ?? s.splits[key] ?? defaultValue
    }

    // MARK: Panels

    func webPanel(_ id: PanelID) -> WebPanel? { s.webPanels.first { $0.id == id } }

    func title(_ id: PanelID) -> String { PanelKind(rawValue: id)?.title ?? webPanel(id)?.title ?? "Panel" }

    func symbol(_ id: PanelID) -> String { PanelKind(rawValue: id)?.symbol ?? webPanel(id)?.symbol ?? "globe" }

    func addWebPanel(_ p: WebPanel) {
        var p = p
        p.id = "web-" + UUID().uuidString.prefix(8).lowercased()
        p.url = WebPanel.normalize(p.url)
        s.webPanels.append(p)
        s.order.append(p.id)
    }

    func updateWebPanel(_ p: WebPanel) {
        guard let i = s.webPanels.firstIndex(where: { $0.id == p.id }) else { return }
        var p = p
        p.url = WebPanel.normalize(p.url)
        s.webPanels[i] = p
    }

    func removeWebPanel(_ id: PanelID) {
        s.webPanels.removeAll { $0.id == id }
        s.normalize()
    }

    func hide(_ id: PanelID) {
        if !s.hidden.contains(id) { s.hidden.append(id) }
    }

    func show(_ id: PanelID) { s.hidden.removeAll { $0 == id } }

    /// Swap a panel with its neighbour in the slot order.
    func move(_ kind: PanelID, by delta: Int) {
        guard let i = s.order.firstIndex(of: kind) else { return }
        let j = i + delta
        guard s.order.indices.contains(j) else { return }
        s.order.swapAt(i, j)
    }

    // MARK: Wallpaper

    private var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PortableDash", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a wallpaper for your dashboard"
        guard panel.runModal() == .OK, let src = panel.url else { return }
        // Copy it in so the wallpaper survives the original being moved or deleted.
        let dest = supportDir.appendingPathComponent("wallpaper-\(Int(Date().timeIntervalSince1970)).\(src.pathExtension)")
        removeWallpaperFile()
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            s.wallpaperPath = dest.path
        } catch {
            s.wallpaperPath = src.path
        }
    }

    func clearWallpaper() {
        removeWallpaperFile()
        s.wallpaperPath = nil
    }

    private func removeWallpaperFile() {
        if let p = s.wallpaperPath, p.hasPrefix(supportDir.path) { try? FileManager.default.removeItem(atPath: p) }
    }

    private func loadWallpaper() {
        wallpaper = s.wallpaperPath.flatMap { NSImage(contentsOfFile: $0) }
    }
}
