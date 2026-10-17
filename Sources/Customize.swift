// Customize.swift
// The slide-in sidebar for themes, decor, layout and behaviour.

import SwiftUI

struct CustomizeSidebar: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var web: WebSessions

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Customize").font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Button { settings.showCustomize = false } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    layoutSection
                    themeSection
                    decorSection
                    panelSection
                    headerSection
                    behaviourSection
                }
                .padding([.horizontal, .bottom], 16)
            }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1) }
        .shadow(color: .black.opacity(0.3), radius: 20)
    }

    // MARK: Layout

    private var layoutSection: some View {
        Section("Layout") {
            Label(settings.isPortrait ? "Sideways monitor (portrait) layout" : "Normal monitor (landscape) layout",
                  systemImage: settings.isPortrait ? "rectangle.portrait" : "rectangle")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(LayoutPreset.allCases) { p in
                    Button { settings.activePreset = p } label: {
                        VStack(spacing: 4) {
                            LayoutThumb(preset: p, panels: settings.visiblePanels, selected: settings.activePreset == p)
                                .frame(width: settings.isPortrait ? 40 : nil, height: settings.isPortrait ? 64 : 52)
                                .frame(maxWidth: .infinity)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(settings.activePreset == p ? settings.accent : .clear, lineWidth: 2))
                            Text(p.title).font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Panel order — drag a divider to resize, double-click it to reset.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(spacing: 4) {
                ForEach(Array(settings.s.order.enumerated()), id: \.element) { i, id in
                    let hidden = settings.s.hidden.contains(id)
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
                        Image(systemName: settings.symbol(id)).foregroundStyle(settings.accent).frame(width: 18)
                        Text(settings.title(id)).lineLimit(1).opacity(hidden ? 0.45 : 1)
                        Spacer()
                        smallButton("chevron.up") { settings.move(id, by: -1) }.disabled(i == 0)
                        smallButton("chevron.down") { settings.move(id, by: 1) }.disabled(i == settings.s.order.count - 1)
                        smallButton(hidden ? "eye.slash" : "eye") {
                            hidden ? settings.show(id) : settings.hide(id)
                        }
                        if PanelKind(rawValue: id) == nil {
                            smallButton("trash") {
                                web.remove(id)
                                settings.removeWebPanel(id)
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
            }

            HStack {
                Toggle("Lock layout", isOn: $settings.s.lockLayout)
                Spacer()
                Button("Reset sizes") { settings.resetSizes() }
            }
        }
    }

    // MARK: Theme

    private var themeSection: some View {
        Section("Theme") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                ForEach(Theme.all) { t in
                    Button {
                        settings.s.themeID = t.id
                        settings.s.accent = nil
                    } label: {
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(LinearGradient(colors: t.colors.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay(alignment: .bottomTrailing) {
                                    Circle().fill(t.accent.color).frame(width: 10, height: 10).padding(5)
                                }
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(settings.s.themeID == t.id ? settings.accent : Color.primary.opacity(0.15),
                                                  lineWidth: settings.s.themeID == t.id ? 2 : 1))
                                .frame(height: 40)
                            Text(t.name).font(.caption2).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                ColorPicker("Accent color", selection: Binding(
                    get: { settings.accent },
                    set: { settings.s.accent = RGBA($0) }), supportsOpacity: false)
                if settings.s.accent != nil {
                    Button("Use theme's") { settings.s.accent = nil }.controlSize(.small)
                }
            }

            HStack {
                Text("Wallpaper")
                Spacer()
                if settings.s.wallpaperPath != nil {
                    Button("Remove") { settings.clearWallpaper() }
                }
                Button("Choose image…") { settings.chooseWallpaper() }
            }
            if settings.s.wallpaperPath != nil {
                slider("Dim", $settings.s.wallpaperDim, 0...0.85)
                slider("Blur", $settings.s.wallpaperBlur, 0...40)
            }
        }
    }

    // MARK: Decor

    private var decorSection: some View {
        Section("Decor") {
            Picker("Ambient effect", selection: $settings.s.ambient) {
                ForEach(Ambient.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Accent glow around panels", isOn: $settings.s.glow)
            VStack(alignment: .leading, spacing: 4) {
                Text("Stickers").font(.callout)
                TextField("Emoji, e.g. 🎧 ✨ 🐻", text: $settings.s.stickers)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 4) {
                    ForEach(["🎧", "✨", "🐻", "📚", "☕️", "🌙", "🔥", "💻", "🍀", "🌸", "🎶", "🧠"], id: \.self) { e in
                        Button(e) { settings.s.stickers += (settings.s.stickers.isEmpty ? "" : " ") + e }
                            .buttonStyle(.plain).font(.system(size: 17))
                    }
                }
            }
        }
    }

    // MARK: Panels

    private var panelSection: some View {
        Section("Panels") {
            Picker("Style", selection: $settings.s.panelStyle) {
                ForEach(PanelStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            slider("Darkness", $settings.s.panelOpacity, 0...1)
            slider("Corner radius", $settings.s.cornerRadius, 0...32)
            slider("Spacing", $settings.s.gap, 4...32)
            Toggle("Show panel title bars", isOn: $settings.s.showPanelTitles)
        }
    }

    // MARK: Header

    private var headerSection: some View {
        Section("Header") {
            Toggle("Show header", isOn: $settings.s.showHeader)
            TextField("Greeting", text: $settings.s.greeting).textFieldStyle(.roundedBorder)
            Toggle("24-hour clock", isOn: $settings.s.use24Hour)
            Toggle("Next calendar event", isOn: $settings.s.showNextEvent)
            if settings.s.showNextEvent {
                HStack {
                    Text("Uses the Mac's Calendar app — add Google there to see Google events.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Add account…") { CalendarStore.openInternetAccounts() }.controlSize(.small)
                }
            }
            Toggle("Stock ticker", isOn: $settings.s.showTicker)
            if settings.s.showTicker {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Symbols (comma-separated, crypto like BTC-USD works)").font(.caption).foregroundStyle(.secondary)
                    TextField("AAPL, NVDA, SPY", text: $settings.s.tickerSymbols).textFieldStyle(.roundedBorder)
                }
                slider("Ticker width", $settings.s.tickerWidth, 160...520)
            }
        }
    }

    // MARK: Behaviour

    private var behaviourSection: some View {
        Section("Behaviour") {
            Toggle("Privacy mode — blur Messages & web panels until hovered", isOn: $settings.s.privacyMode)
            Toggle("Jump to the external display when it's plugged in", isOn: $settings.s.autoMoveToExternal)
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude home page").font(.callout)
                TextField("https://claude.ai/new", text: $settings.s.claudeHome).textFieldStyle(.roundedBorder)
            }
            Text("Shortcuts: ⌃⌥⌘D show/hide dashboard · ⇧⌘P privacy · ⇧⌘L lock · ⌘R reload Claude")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 96, alignment: .leading)
            Slider(value: value, in: range).tint(settings.accent)
        }
    }

    private func smallButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
