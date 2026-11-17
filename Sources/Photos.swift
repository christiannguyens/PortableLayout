// Photos.swift
// Photo gallery panels: a slideshow of a folder (local or Google Drive for desktop) and/or photos
// you picked, cycling at your chosen interval with a transition.

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Model

enum PhotoTransition: String, Codable, CaseIterable, Identifiable {
    case crossfade, slide, zoom, kenBurns
    var id: String { rawValue }

    var title: String {
        switch self {
        case .crossfade: return "Fade"
        case .slide: return "Slide"
        case .zoom: return "Zoom"
        case .kenBurns: return "Ken Burns"
        }
    }

    var transition: AnyTransition {
        switch self {
        case .crossfade, .kenBurns: return .opacity
        case .slide: return .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
        case .zoom: return .asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.12)),
                                       removal: .opacity.combined(with: .scale(scale: 0.94)))
        }
    }

    var duration: Double { self == .slide ? 0.8 : 1.4 }
}

/// A user-added photo gallery panel.
struct PhotoPanel: Codable, Equatable, Identifiable {
    var id: PanelID = "photo-" + UUID().uuidString.prefix(8).lowercased()
    var title = "Photos"
    var folderPath: String? = nil          // watched folder; photos you pick are copied to `storageDir`
    var interval = 30.0                    // seconds per photo
    var transition: PhotoTransition = .crossfade
    var fill = true                        // fill the panel (crop) vs. fit the whole photo
    var shuffle = true
    var photosVersion = 0                  // bumped when picked photos change, so the slideshow rescans

    static let symbol = "photo.on.rectangle.angled"

    static let intervals: [(String, Double)] = [
        ("3 sec", 3), ("5 sec", 5), ("10 sec", 10), ("15 sec", 15), ("30 sec", 30),
        ("1 min", 60), ("2 min", 120), ("5 min", 300), ("10 min", 600), ("30 min", 1800), ("1 hour", 3600),
    ]

    /// Where photos picked for this panel are copied, so they survive the originals moving.
    static func storageDir(for id: PanelID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PortableDash/Photos/\(id)", isDirectory: true)
    }

    static func importPhotos(_ urls: [URL], into id: PanelID) {
        guard !urls.isEmpty else { return }
        let dir = storageDir(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for src in urls {
            var dest = dir.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(src.lastPathComponent)")
            }
            try? FileManager.default.copyItem(at: src, to: dest)
        }
    }

    static func deleteStorage(for id: PanelID) {
        try? FileManager.default.removeItem(at: storageDir(for: id))
    }

    static func importedCount(for id: PanelID) -> Int {
        PhotoLibrary.images(in: storageDir(for: id)).count
    }
}

// MARK: - Pickers

enum PhotoPicker {
    /// Google Drive for desktop mounts Drive here, e.g. ~/Library/CloudStorage/GoogleDrive-you@gmail.com/My Drive.
    static var googleDriveRoot: URL? {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        guard let drive = (try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasPrefix("GoogleDrive") }) else { return nil }
        let myDrive = drive.appendingPathComponent("My Drive")
        return FileManager.default.fileExists(atPath: myDrive.path) ? myDrive : drive
    }

    static let googleDriveDownload = URL(string: "https://www.google.com/drive/download/")!

    static func chooseFolder(startingAt start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        panel.message = "Pick a folder of photos — new photos added to it will show up automatically"
        panel.prompt = "Use Folder"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func choosePhotos() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Pick photos for the gallery"
        panel.prompt = "Add Photos"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

// MARK: - Slideshow

enum PhotoLibrary {
    /// Image files in a folder and its subfolders (capped, so pointing at a huge drive stays responsive).
    nonisolated static func images(in dir: URL, limit: Int = 5000) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var found: [URL] = []
        for case let url as URL in e {
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { continue }
            found.append(url)
            if found.count >= limit { break }
        }
        return found
    }

    /// Decodes a downsampled, correctly rotated copy so big camera photos don't eat memory.
    nonisolated static func load(_ url: URL, maxPixels: Int = 2560) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

@MainActor
final class PhotoSlideshow: ObservableObject {
    struct Slide: Equatable {
        let id = UUID()
        let image: NSImage
        static func == (a: Slide, b: Slide) -> Bool { a.id == b.id }
    }

    @Published private(set) var current: Slide?
    @Published private(set) var count = 0
    @Published private(set) var scanned = false
    @Published var paused = false { didSet { if paused != oldValue { restartTimer() } } }

    private var panel: PhotoPanel?
    private var order: [URL] = []
    private var index = -1
    private var timer: Task<Void, Never>?
    private var rescanner: Task<Void, Never>?
    private var loadToken = UUID()

    func configure(_ p: PhotoPanel) {
        let old = panel
        panel = p
        if old?.folderPath != p.folderPath || old?.photosVersion != p.photosVersion || old?.shuffle != p.shuffle {
            rescan(reset: old?.shuffle != p.shuffle || old == nil)
        }
        if old?.interval != p.interval { restartTimer() }
        if rescanner == nil {
            // Pick up photos added to the folder (or synced down from Drive) without a relaunch.
            rescanner = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    self?.rescan(reset: false)
                }
            }
        }
    }

    func stop() {
        timer?.cancel(); timer = nil
        rescanner?.cancel(); rescanner = nil
        panel = nil
    }

    func next() { step(1) }
    func previous() { step(-1) }

    private func step(_ delta: Int) {
        guard !order.isEmpty else { return }
        var i = index + delta
        if i >= order.count {
            i = 0
            if panel?.shuffle == true, order.count > 2 {
                // New random pass, without showing the same photo twice in a row.
                let last = order.last
                order.shuffle()
                if order.first == last { order.swapAt(0, order.count - 1) }
            }
        } else if i < 0 {
            i = order.count - 1
        }
        index = i
        show(order[i])
        restartTimer()
    }

    private func show(_ url: URL) {
        let token = UUID()
        loadToken = token
        Task.detached(priority: .userInitiated) {
            let img = PhotoLibrary.load(url)
            await MainActor.run { [weak self] in
                guard let self, self.loadToken == token else { return }
                if let img { self.current = Slide(image: img) } else { self.next() }   // unreadable file: skip it
            }
        }
    }

    private func rescan(reset: Bool) {
        guard let p = panel else { return }
        let folder = p.folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let imported = PhotoPanel.storageDir(for: p.id)
        Task.detached(priority: .utility) {
            var urls = PhotoLibrary.images(in: imported)
            if let folder { urls += PhotoLibrary.images(in: folder) }
            urls.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let found = urls
            await MainActor.run { [weak self] in self?.apply(found, reset: reset) }
        }
    }

    private func apply(_ urls: [URL], reset: Bool) {
        scanned = true
        count = urls.count
        if !reset, Set(urls) == Set(order) { return }
        let showing = order.indices.contains(index) ? order[index] : nil
        order = panel?.shuffle == true ? urls.shuffled() : urls
        if urls.isEmpty { index = -1; current = nil; return }
        if !reset, let showing, let i = order.firstIndex(of: showing) {
            index = i      // same photo stays up; the new ones join the rotation
        } else {
            index = -1
            next()
        }
    }

    private func restartTimer() {
        timer?.cancel()
        guard let interval = panel?.interval, !paused else { timer = nil; return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.next()
        }
    }
}

// MARK: - Panel view

struct PhotoPanelView: View {
    let panel: PhotoPanel
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var show = PhotoSlideshow()
    @State private var hovering = false

    var body: some View {
        ZStack {
            if let slide = show.current {
                SlideImage(image: slide.image, fill: panel.fill,
                           drift: panel.transition == .kenBurns ? panel.interval + panel.transition.duration : nil)
                    .id(slide.id)
                    .transition(panel.transition.transition)
            } else if show.scanned {
                emptyState
            }

            if hovering && show.count > 0 { controls }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: panel.transition.duration), value: show.current)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .onAppear { show.configure(panel) }
        .onChange(of: panel) { _, p in show.configure(p) }
        .onDisappear { show.stop() }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            control("chevron.left", help: "Previous") { show.previous() }
            control(show.paused ? "play.fill" : "pause.fill", help: show.paused ? "Resume" : "Pause") { show.paused.toggle() }
            control("chevron.right", help: "Next") { show.next() }
        }
        .padding(6)
        .background(Capsule().fill(.black.opacity(0.45)))
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 12)
        .transition(.opacity)
    }

    private func control(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: PhotoPanel.symbol)
                .font(.system(size: 28))
                .foregroundStyle(settings.accent)
            Text("No photos yet").font(.headline)
            Text("Use ⋯ → Edit to pick a folder or add photos.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// One photo, optionally drifting slowly (Ken Burns) for as long as it's on screen.
private struct SlideImage: View {
    let image: NSImage
    let fill: Bool
    let drift: Double?
    @State private var zoomed = false

    var body: some View {
        GeometryReader { geo in
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: fill || drift != nil ? .fill : .fit)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(zoomed ? 1.15 : 1.0, anchor: .init(x: 0.4, y: 0.4))
                .clipped()
        }
        .onAppear {
            guard let drift else { return }
            withAnimation(.linear(duration: drift)) { zoomed = true }
        }
    }
}

// MARK: - Edit form

struct PhotoPanelForm: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var panel: PhotoPanel
    @State private var importedCount: Int
    let onSave: (PhotoPanel) -> Void
    let onCancel: () -> Void

    init(initial: PhotoPanel, onSave: @escaping (PhotoPanel) -> Void, onCancel: @escaping () -> Void) {
        _panel = State(initialValue: initial)
        _importedCount = State(initialValue: PhotoPanel.importedCount(for: initial.id))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Photo gallery").font(.headline)
            TextField("Name", text: $panel.title).textFieldStyle(.roundedBorder)

            label("Folder")
            HStack {
                Image(systemName: "folder").foregroundStyle(settings.accent)
                Text(panel.folderPath.map(Self.displayPath) ?? "None")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(panel.folderPath == nil ? .secondary : .primary)
                Spacer()
                if panel.folderPath != nil {
                    Button("Remove") { panel.folderPath = nil }
                }
            }
            HStack {
                Button("Choose folder…") {
                    if let url = PhotoPicker.chooseFolder() { panel.folderPath = url.path }
                }
                if let drive = PhotoPicker.googleDriveRoot {
                    Button("Google Drive folder…") {
                        if let url = PhotoPicker.chooseFolder(startingAt: drive) { panel.folderPath = url.path }
                    }
                } else {
                    Link("Get Google Drive for desktop", destination: PhotoPicker.googleDriveDownload)
                        .font(.caption)
                }
            }

            label("Added photos")
            HStack {
                Text(importedCount == 1 ? "1 photo" : "\(importedCount) photos")
                    .foregroundStyle(importedCount == 0 ? .secondary : .primary)
                Spacer()
                if importedCount > 0 {
                    Button("Clear") {
                        PhotoPanel.deleteStorage(for: panel.id)
                        changedPhotos()
                    }
                }
                Button("Add photos…") {
                    let urls = PhotoPicker.choosePhotos()
                    guard !urls.isEmpty else { return }
                    PhotoPanel.importPhotos(urls, into: panel.id)
                    changedPhotos()
                }
            }

            label("Slideshow")
            Picker("Change every", selection: $panel.interval) {
                ForEach(PhotoPanel.intervals, id: \.1) { Text($0.0).tag($0.1) }
                if !PhotoPanel.intervals.contains(where: { $0.1 == panel.interval }) {
                    Text("\(Int(panel.interval)) sec").tag(panel.interval)
                }
            }
            Picker("Transition", selection: $panel.transition) {
                ForEach(PhotoTransition.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Photos", selection: $panel.fill) {
                Text("Fill panel").tag(true)
                Text("Show whole photo").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(panel.transition == .kenBurns)
            Toggle("Shuffle", isOn: $panel.shuffle)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    if panel.title.trimmingCharacters(in: .whitespaces).isEmpty { panel.title = "Photos" }
                    onSave(panel)
                }
                .buttonStyle(.borderedProminent)
                .tint(settings.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// Added photos are copied in immediately; bump the version so the slideshow picks them up.
    private func changedPhotos() {
        importedCount = PhotoPanel.importedCount(for: panel.id)
        panel.photosVersion += 1
        if var saved = settings.photoPanel(panel.id) {
            saved.photosVersion = panel.photosVersion
            settings.updatePhotoPanel(saved)
        }
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
    }

    /// "~/Library/CloudStorage/GoogleDrive-x/My Drive/Pics" → "Google Drive › Pics".
    static func displayPath(_ path: String) -> String {
        if let r = path.range(of: #"/Library/CloudStorage/GoogleDrive-[^/]+(/My Drive)?"#, options: .regularExpression) {
            let rest = path[r.upperBound...].split(separator: "/").joined(separator: " › ")
            return rest.isEmpty ? "Google Drive" : "Google Drive › " + rest
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
