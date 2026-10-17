// Dashboard.swift
// The root view: background + decor, header bar, panel grid, customize sidebar.

import SwiftUI
import AppKit

struct DashboardView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        let s = settings.s
        ZStack(alignment: .trailing) {
            BackgroundView()

            VStack(spacing: CGFloat(s.gap)) {
                if s.showHeader {
                    HeaderBar()
                } else {
                    WindowDragArea().frame(height: 22)   // room for the traffic lights
                }
                PanelGrid()
            }
            .padding(.horizontal, CGFloat(s.gap))
            .padding(.bottom, CGFloat(s.gap))
            .padding(.top, s.showHeader ? 6 : 6)

            if settings.showCustomize {
                CustomizeSidebar()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, settings.theme.isLight ? .light : .dark)
        .animation(.spring(duration: 0.35), value: settings.showCustomize)
        .animation(.spring(duration: 0.35), value: settings.activePreset)
        .animation(.spring(duration: 0.35), value: s.order)
        .animation(.spring(duration: 0.35), value: s.hidden)
    }
}

// MARK: - Panel card

struct PanelCard: View {
    let id: PanelID
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var web: WebSessions
    @EnvironmentObject var messages: MessagesStore
    @EnvironmentObject var spotify: SpotifyController
    @State private var hovering = false
    @State private var editing = false

    private var kind: PanelKind? { PanelKind(rawValue: id) }

    var body: some View {
        let s = settings.s
        let shape = RoundedRectangle(cornerRadius: CGFloat(s.cornerRadius), style: .continuous)

        VStack(spacing: 0) {
            if s.showPanelTitles { titleBar }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .panelBackground(settings: settings, shape: shape)
        .clipShape(shape)
        .overlay {
            if s.glow {
                shape.strokeBorder(
                    LinearGradient(colors: [settings.accent.opacity(0.65), .white.opacity(0.06), settings.accent.opacity(0.3)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
                    .allowsHitTesting(false)
            } else {
                shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false)
            }
        }
        .background {
            if s.glow {
                shape.fill(settings.accent.opacity(0.18)).blur(radius: 18).allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        .sheet(isPresented: $editing) {
            if let panel = settings.webPanel(id) {
                WebPanelForm(initial: panel, isNew: false) { updated in
                    settings.updateWebPanel(updated)
                    editing = false
                } onCancel: { editing = false }
                .environmentObject(settings)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .messages:
            MessagesPanel(concealed: settings.s.privacyMode && !hovering)
        case .spotify:
            SpotifyPanel()
        case .claude, nil:
            if let session = web.session(for: id, settings: settings) {
                WebPanelView(session: session, cardHovering: hovering)
            }
        }
    }

    private var titleBar: some View {
        let title = settings.title(id)
        return HStack(spacing: 8) {
            Image(systemName: settings.symbol(id))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(settings.accent)
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Spacer()
            accessories
            Menu {
                Button("Move earlier", systemImage: "arrow.left") { settings.move(id, by: -1) }
                    .disabled(settings.s.order.first == id)
                Button("Move later", systemImage: "arrow.right") { settings.move(id, by: 1) }
                    .disabled(settings.s.order.last == id)
                Divider()
                if kind == nil {
                    Button("Edit…", systemImage: "pencil") { editing = true }
                }
                Button("Hide \(title)", systemImage: "eye.slash") { settings.hide(id) }
                if kind == nil {
                    Button("Remove \(title)", systemImage: "trash", role: .destructive) {
                        web.remove(id)
                        settings.removeWebPanel(id)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    @ViewBuilder private var accessories: some View {
        switch kind {
        case .claude:
            if let s = web.session(for: id, settings: settings) {
                WebTitleButtons(session: s, homeHelp: "New chat", homeSymbol: "square.and.pencil")
            }
        case nil:
            if let s = web.session(for: id, settings: settings) { WebTitleButtons(session: s) }
        case .messages:
            TitleButton("arrow.clockwise", help: "Refresh") { messages.refresh(force: true) }
            TitleButton("arrow.up.forward.app", help: "Open Messages") { MessagesStore.openMessagesApp() }
        case .spotify:
            if settings.s.spotifyBrowse {
                WebTitleButtons(session: web.spotifyBrowser)
            }
            TitleButton(settings.s.spotifyBrowse ? "play.square.fill" : "magnifyingglass",
                        help: settings.s.spotifyBrowse ? "Back to player" : "Browse & pick songs") {
                settings.s.spotifyBrowse.toggle()
            }
            TitleButton("arrow.up.forward.app", help: "Open Spotify") {
                spotify.running ? spotify.bringToFront() : spotify.launch()
            }
        }
    }
}

struct TitleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol; self.help = help; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

extension View {
    @ViewBuilder
    func panelBackground(settings: SettingsStore, shape: RoundedRectangle) -> some View {
        let s = settings.s
        let scrim: Color = settings.theme.isLight ? .white : .black
        switch s.panelStyle {
        case .glass:
            if #available(macOS 26.0, *) {
                self.background(scrim.opacity(s.panelOpacity * 0.45), in: shape)
                    .glassEffect(.regular.tint(settings.accent.opacity(0.08)), in: shape)
            } else {
                self.background(scrim.opacity(s.panelOpacity * 0.4), in: shape)
                    .background(.ultraThinMaterial, in: shape)
            }
        case .frosted:
            self.background(scrim.opacity(s.panelOpacity * 0.5), in: shape)
                .background(.thinMaterial, in: shape)
        case .solid:
            self.background(scrim.opacity(0.35 + s.panelOpacity * 0.65), in: shape)
        }
    }
}

// MARK: - Header

struct HeaderBar: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var spotify: SpotifyController

    var body: some View {
        let s = settings.s
        Group {
            if settings.compactHeader {
                // Narrow (e.g. sideways) monitor: event + ticker get their own row.
                VStack(spacing: 8) {
                    HStack(spacing: 14) {
                        clock
                        greeting
                        Spacer(minLength: 8)
                        nowPlaying
                        stickers
                        buttons
                    }
                    .padding(.leading, 76)
                    .frame(height: 44)
                    if s.showNextEvent || s.showTicker {
                        HStack(spacing: 10) {
                            if s.showNextEvent { NextEventChip() }
                            if s.showTicker { StockTicker(fill: true) } else { Spacer() }
                        }
                    }
                }
            } else {
                HStack(spacing: 14) {
                    clock
                    greeting
                    if s.showNextEvent { NextEventChip() }
                    Spacer(minLength: 12)
                    if s.showTicker { StockTicker() }
                    nowPlaying
                    stickers
                    buttons
                }
                .padding(.leading, 76)   // clear the window's traffic-light buttons
                .frame(height: 44)
            }
        }
        .padding(.trailing, 2)
        .background(WindowDragArea())
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Self.time(ctx.date, h24: settings.s.use24Hour))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if settings.windowSize.width >= 820 {
                    Text(ctx.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text(ctx.date.formatted(.dateTime.weekday(.abbreviated).day()))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder private var greeting: some View {
        if !settings.s.greeting.isEmpty {
            Capsule().fill(settings.accent).frame(width: 3, height: 18)
            Text(settings.s.greeting)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .lineLimit(1)
                .layoutPriority(-1)   // first thing to shorten when space is tight
        }
    }

    @ViewBuilder private var nowPlaying: some View {
        if let t = spotify.track, spotify.playing, !settings.visiblePanels.contains(PanelKind.spotify.rawValue) {
            Label("\(t.name) · \(t.artist)", systemImage: "waveform")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var stickers: some View {
        if !settings.s.stickers.isEmpty {
            Text(settings.s.stickers).font(.system(size: 20)).lineLimit(1).fixedSize()
        }
    }

    private var buttons: some View {
        let s = settings.s
        return HStack(spacing: 6) {
            AddPanelButton()
            HeaderButton(symbol: s.privacyMode ? "eye.slash.fill" : "eye",
                         on: s.privacyMode, help: "Privacy mode (⇧⌘P): blur until hovered") {
                settings.s.privacyMode.toggle()
            }
            HeaderButton(symbol: s.lockLayout ? "lock.fill" : "lock.open",
                         on: s.lockLayout, help: "Lock layout (⇧⌘L)") {
                settings.s.lockLayout.toggle()
            }
            HeaderButton(symbol: "slider.horizontal.3", on: settings.showCustomize, help: "Customize (⌘,)") {
                settings.showCustomize.toggle()
            }
        }
        .fixedSize()
    }

    static func time(_ d: Date, h24: Bool) -> String {
        let f = DateFormatter()
        f.dateFormat = h24 ? "HH:mm" : "h:mm"
        return f.string(from: d)
    }
}

struct HeaderButton: View {
    @EnvironmentObject var settings: SettingsStore
    let symbol: String
    let on: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? settings.onAccent : .primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(on ? settings.accent : Color.primary.opacity(hovering ? 0.16 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Lets you drag the window by the header (the title bar is hidden).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

// MARK: - Background & ambient decor

struct BackgroundView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        let theme = settings.theme
        let s = settings.s
        ZStack {
            LinearGradient(colors: theme.colors.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing)

            if let img = settings.wallpaper {
                GeometryReader { geo in
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: CGFloat(s.wallpaperBlur))
                        .clipped()
                }
                Color.black.opacity(s.wallpaperDim)
            }

            AmbientLayer(kind: s.ambient, colors: theme.colors.map(\.color), accent: settings.accent)
        }
        .allowsHitTesting(false)
    }
}

struct AmbientLayer: View {
    let kind: Ambient
    let colors: [Color]
    let accent: Color

    var body: some View {
        switch kind {
        case .none:
            Color.clear
        case .orbs:
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
                Canvas { gc, size in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    for i in 0..<5 {
                        let fi = Double(i)
                        let x = size.width * (0.5 + 0.42 * sin(t * (0.045 + fi * 0.012) + fi * 1.7))
                        let y = size.height * (0.5 + 0.40 * cos(t * (0.035 + fi * 0.010) + fi * 2.3))
                        let r = max(size.width, size.height) * (0.20 + 0.05 * Double(i % 3))
                        let c = i.isMultiple(of: 2) ? accent : colors[(i + 1) % colors.count]
                        gc.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                                with: .radialGradient(Gradient(colors: [c.opacity(0.32), c.opacity(0)]),
                                                      center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
                    }
                }
            }
        case .stars:
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { ctx in
                Canvas { gc, size in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    var rng = SeededRandom(seed: 42)
                    for _ in 0..<180 {
                        let x = rng.next() * size.width, y = rng.next() * size.height
                        let r = 0.5 + rng.next() * 1.4
                        let phase = rng.next() * 6.28, speed = 0.4 + rng.next() * 1.6
                        let alpha = 0.25 + 0.6 * (0.5 + 0.5 * sin(t * speed + phase))
                        gc.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                                with: .color(.white.opacity(alpha)))
                    }
                }
            }
        case .aurora:
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { ctx in
                Canvas { gc, size in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    for band in 0..<3 {
                        let fb = Double(band)
                        var p = Path()
                        let baseY = size.height * (0.25 + 0.18 * fb)
                        p.move(to: CGPoint(x: 0, y: size.height))
                        for xi in stride(from: 0.0, through: Double(size.width), by: 12) {
                            let y = baseY + 60 * sin(xi / 260 + t * (0.18 + fb * 0.05) + fb * 2)
                                + 30 * sin(xi / 90 + t * 0.3 + fb)
                            p.addLine(to: CGPoint(x: xi, y: y))
                        }
                        p.addLine(to: CGPoint(x: size.width, y: size.height))
                        p.closeSubpath()
                        let c = band == 1 ? accent : colors[(band + 1) % colors.count]
                        gc.fill(p, with: .linearGradient(Gradient(colors: [c.opacity(0.35), .clear]),
                                                         startPoint: CGPoint(x: 0, y: baseY - 60),
                                                         endPoint: CGPoint(x: 0, y: baseY + 260)))
                    }
                }
                .blur(radius: 30)
            }
        }
    }
}

/// Deterministic random numbers so the starfield doesn't reshuffle every frame.
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}
