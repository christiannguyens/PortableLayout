// Layout.swift
// Turns a preset + visible panels into rectangles, plus draggable dividers between them.
// Panels never overlap: every split divides its space into two non-overlapping halves.

import SwiftUI
import AppKit

struct PlacedPanel: Identifiable {
    let id: PanelID
    let rect: CGRect
}

struct PlacedHandle: Identifiable {
    let key: String
    let vertical: Bool       // true = panels stacked top/bottom, handle is horizontal
    let rect: CGRect         // the gap between the two halves
    let span: CGFloat        // length the fraction is measured against
    let defaultFraction: Double
    var id: String { key }
}

indirect enum LayoutNode {
    case leaf(PanelID)
    case split(vertical: Bool, key: String, defaultFraction: Double, first: LayoutNode, second: LayoutNode)

    /// Panels in `order` fill the preset's slots; the first panel is the "main" one.
    /// Split keys include the panel count, so each count remembers its own sizes.
    static func build(_ preset: LayoutPreset, _ panels: [PanelID]) -> LayoutNode? {
        guard let first = panels.first else { return nil }
        let n = panels.count
        if n == 1 { return .leaf(first) }
        let leaves = panels.map { LayoutNode.leaf($0) }
        let rest = Array(leaves.dropFirst()), allButLast = Array(leaves.dropLast())

        switch preset {
        case .sidebarLeft:
            return .split(vertical: false, key: "sl\(n)", defaultFraction: 0.32, first: leaves[0],
                          second: chain(rest, vertical: true, key: "sl\(n)-stack", defaults: n == 3 ? [0.70] : []))
        case .sidebarRight:
            return .split(vertical: false, key: "sr\(n)", defaultFraction: 0.68,
                          first: chain(rest, vertical: true, key: "sr\(n)-stack", defaults: n == 3 ? [0.70] : []),
                          second: leaves[0])
        case .columns:
            return chain(leaves, vertical: false, key: "col\(n)", defaults: n == 3 ? [0.30] : [])
        case .rows:
            return chain(leaves, vertical: true, key: "rows\(n)", defaults: n == 3 ? [0.36, 0.76] : [])
        case .bottomStrip:
            return .split(vertical: true, key: "bs\(n)", defaultFraction: 0.74,
                          first: chain(allButLast, vertical: false, key: "bs\(n)-row", defaults: n == 3 ? [0.40] : []),
                          second: leaves[n - 1])
        case .topStrip:
            return .split(vertical: true, key: "ts\(n)", defaultFraction: 0.24, first: leaves[n - 1],
                          second: chain(allButLast, vertical: false, key: "ts\(n)-row", defaults: n == 3 ? [0.40] : []))
        case .grid:
            let cols = Int(Double(n).squareRoot().rounded(.up))
            let rows = stride(from: 0, to: n, by: cols).enumerated().map { r, start in
                chain(Array(leaves[start..<min(start + cols, n)]), vertical: false, key: "grid\(n)-r\(r)", defaults: [])
            }
            return chain(rows, vertical: true, key: "grid\(n)", defaults: [])
        }
    }

    /// Lays nodes out in a row (or column) of equal sizes, as nested two-way splits.
    /// `defaults` optionally gives the default fraction for each successive split.
    private static func chain(_ nodes: [LayoutNode], vertical: Bool, key: String, defaults: [Double]) -> LayoutNode {
        guard nodes.count > 1 else { return nodes[0] }
        let k = nodes.count
        return .split(vertical: vertical, key: "\(key)-\(k)", defaultFraction: defaults.first ?? 1.0 / Double(k),
                      first: nodes[0],
                      second: chain(Array(nodes.dropFirst()), vertical: vertical, key: key,
                                    defaults: Array(defaults.dropFirst())))
    }

    /// `keyPrefix` keeps portrait and landscape divider sizes separate.
    func layout(in r: CGRect, gap: CGFloat, keyPrefix: String = "",
                fraction: (String, Double) -> Double) -> ([PlacedPanel], [PlacedHandle]) {
        switch self {
        case .leaf(let id):
            return ([PlacedPanel(id: id, rect: r)], [])
        case let .split(vertical, rawKey, def, first, second):
            let key = keyPrefix + rawKey
            let f = CGFloat(fraction(key, def))
            let r1: CGRect, r2: CGRect, gapRect: CGRect, span: CGFloat
            if vertical {
                span = max(r.height - gap, 1)
                let h1 = (span * f).rounded()
                r1 = CGRect(x: r.minX, y: r.minY, width: r.width, height: h1)
                gapRect = CGRect(x: r.minX, y: r.minY + h1, width: r.width, height: gap)
                r2 = CGRect(x: r.minX, y: r.minY + h1 + gap, width: r.width, height: span - h1)
            } else {
                span = max(r.width - gap, 1)
                let w1 = (span * f).rounded()
                r1 = CGRect(x: r.minX, y: r.minY, width: w1, height: r.height)
                gapRect = CGRect(x: r.minX + w1, y: r.minY, width: gap, height: r.height)
                r2 = CGRect(x: r.minX + w1 + gap, y: r.minY, width: span - w1, height: r.height)
            }
            let (p1, h1) = first.layout(in: r1, gap: gap, keyPrefix: keyPrefix, fraction: fraction)
            let (p2, h2) = second.layout(in: r2, gap: gap, keyPrefix: keyPrefix, fraction: fraction)
            let handle = PlacedHandle(key: key, vertical: vertical, rect: gapRect, span: span, defaultFraction: def)
            return (p1 + p2, [handle] + h1 + h2)
        }
    }
}

// MARK: - The panel grid

struct PanelGrid: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        GeometryReader { geo in
            let gap = CGFloat(settings.s.gap)
            if let node = LayoutNode.build(settings.activePreset, settings.visiblePanels) {
                let (panels, handles) = node.layout(in: CGRect(origin: .zero, size: geo.size), gap: gap,
                                                    keyPrefix: settings.splitPrefix, fraction: settings.fraction)
                ZStack(alignment: .topLeading) {
                    ForEach(panels) { p in
                        PanelCard(id: p.id)
                            .frame(width: max(p.rect.width, 0), height: max(p.rect.height, 0))
                            .offset(x: p.rect.minX, y: p.rect.minY)
                    }
                    if !settings.s.lockLayout {
                        ForEach(handles) { h in SplitHandle(handle: h) }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.dashed").font(.system(size: 40))
                    Text("All panels are hidden").font(.headline)
                    Text("Use the + button in the header to add or show panels.").font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Draggable divider

struct SplitHandle: View {
    let handle: PlacedHandle
    @EnvironmentObject var settings: SettingsStore
    @State private var startFraction: Double?
    @State private var hovering = false

    private let minPanel: CGFloat = 140

    var body: some View {
        let thickness = max(handle.vertical ? handle.rect.height : handle.rect.width, 10)
        let hit = handle.vertical
            ? CGSize(width: handle.rect.width, height: thickness)
            : CGSize(width: thickness, height: handle.rect.height)
        let active = hovering || startFraction != nil

        ZStack {
            Color.clear.contentShape(Rectangle())
            Capsule()
                .fill(settings.accent.opacity(active ? 0.95 : 0.0))
                .frame(width: handle.vertical ? 56 : 4, height: handle.vertical ? 4 : 56)
                .shadow(color: settings.accent.opacity(active ? 0.8 : 0), radius: 6)
        }
        .frame(width: hit.width, height: hit.height)
        .offset(x: handle.rect.midX - hit.width / 2, y: handle.rect.midY - hit.height / 2)
        .onHover { inside in
            hovering = inside
            if inside { (handle.vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startFraction ?? settings.fraction(handle.key, handle.defaultFraction)
                    if startFraction == nil { startFraction = start }
                    let delta = handle.vertical ? value.translation.height : value.translation.width
                    let lo = min(0.45, Double(minPanel / handle.span))
                    let f = min(max(start + Double(delta / handle.span), lo), 1 - lo)
                    settings.liveSplits[handle.key] = f
                }
                .onEnded { _ in
                    if let f = settings.liveSplits[handle.key] { settings.s.splits[handle.key] = f }
                    settings.liveSplits[handle.key] = nil
                    startFraction = nil
                }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            settings.s.splits[handle.key] = nil   // double-click resets
        })
        .help("Drag to resize · double-click to reset")
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

// MARK: - Mini layout preview (used in Customize)

struct LayoutThumb: View {
    @EnvironmentObject var settings: SettingsStore
    let preset: LayoutPreset
    let panels: [PanelID]
    var selected = false

    var body: some View {
        GeometryReader { geo in
            let placed = LayoutNode.build(preset, panels)?
                .layout(in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 4, dy: 4), gap: 3,
                        fraction: { _, def in def }).0 ?? []
            ZStack(alignment: .topLeading) {
                ForEach(placed) { p in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(selected ? settings.accent.opacity(0.45) : Color.primary.opacity(0.18))
                        .overlay(Image(systemName: settings.symbol(p.id)).font(.system(size: 8)).opacity(0.8))
                        .frame(width: p.rect.width, height: p.rect.height)
                        .offset(x: p.rect.minX, y: p.rect.minY)
                }
            }
        }
    }
}
