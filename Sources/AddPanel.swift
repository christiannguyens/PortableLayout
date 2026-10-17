// AddPanel.swift
// The header's + button: quick-add popular sites, add any URL, or bring back hidden panels.

import SwiftUI

struct AddPanelButton: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var open = false

    var body: some View {
        HeaderButton(symbol: "plus", on: open, help: "Add a panel") { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                AddPanelPopover { open = false }
                    .environmentObject(settings)
                    .environment(\.colorScheme, settings.theme.isLight ? .light : .dark)
            }
    }
}

private struct AddPanelPopover: View {
    @EnvironmentObject var settings: SettingsStore
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a panel").font(.system(size: 16, weight: .bold, design: .rounded))

            if !settings.s.hidden.isEmpty {
                label("Hidden panels")
                HStack(spacing: 6) {
                    ForEach(settings.s.hidden, id: \.self) { id in
                        Button {
                            settings.show(id)
                            close()
                        } label: {
                            Label(settings.title(id), systemImage: settings.symbol(id))
                                .font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(settings.accent.opacity(0.2)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            label("Quick add")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 10) {
                ForEach(WebPanel.presets, id: \.title) { p in
                    Button {
                        settings.addWebPanel(p)
                        close()
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: p.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(settings.accent)
                                .frame(width: 38, height: 38)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(settings.accent.opacity(0.15)))
                            Text(p.title).font(.caption2).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
            label("Any website")
            WebPanelForm(initial: WebPanel(title: "", url: ""), isNew: true) { p in
                settings.addWebPanel(p)
                close()
            }
        }
        .padding(16)
        .frame(width: 390)
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
    }
}

/// Name / URL / icon / mobile form, used for adding and for editing a web panel.
struct WebPanelForm: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var panel: WebPanel
    let isNew: Bool
    let onSave: (WebPanel) -> Void
    let onCancel: (() -> Void)?

    init(initial: WebPanel, isNew: Bool, onSave: @escaping (WebPanel) -> Void, onCancel: (() -> Void)? = nil) {
        _panel = State(initialValue: initial)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var host: String? { URL(string: WebPanel.normalize(panel.url))?.host }
    private var valid: Bool { (host?.contains(".") ?? false) || host == "localhost" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isNew { Text("Edit panel").font(.headline) }
            TextField("Website, e.g. wustl.instructure.com", text: $panel.url)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            TextField("Name (optional)", text: $panel.title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 9), spacing: 4) {
                ForEach(WebPanel.symbols, id: \.self) { sym in
                    Button { panel.symbol = sym } label: {
                        Image(systemName: sym)
                            .font(.system(size: 12))
                            .frame(width: 30, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(panel.symbol == sym ? settings.accent.opacity(0.35) : Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }

            Toggle("Mobile layout (fits narrow panels better)", isOn: $panel.mobile)
                .font(.callout)

            HStack {
                Spacer()
                if let onCancel { Button("Cancel", action: onCancel) }
                Button(isNew ? "Add panel" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(settings.accent)
                    .disabled(!valid)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(isNew ? 0 : 20)
        .frame(width: isNew ? nil : 380)
    }

    private func save() {
        guard valid else { return }
        var p = panel
        if p.title.trimmingCharacters(in: .whitespaces).isEmpty {
            let h = host ?? "Website"
            p.title = (h.hasPrefix("www.") ? String(h.dropFirst(4)) : h)
        }
        onSave(p)
    }
}
