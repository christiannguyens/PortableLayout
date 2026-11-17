// Spotify.swift
// A native now-playing panel that remote-controls the Spotify app over AppleScript.

import SwiftUI
import AppKit

// MARK: - AppleScript runner

struct ScriptError: Error {
    let code: Int
    let message: String
    /// -1743: the user hasn't allowed this app to control the target app (Automation permission).
    var notAuthorized: Bool { code == -1743 }
}

enum AppleScript {
    /// All AppleScript runs on one serial queue: NSAppleScript isn't safe to use concurrently.
    static let queue = DispatchQueue(label: "portabledash.applescript", qos: .userInitiated)

    static func run(_ source: String, completion: @escaping (Result<String, ScriptError>) -> Void) {
        queue.async {
            var err: NSDictionary?
            let output = NSAppleScript(source: source)?.executeAndReturnError(&err)
            let result: Result<String, ScriptError>
            if let err {
                result = .failure(ScriptError(code: (err[NSAppleScript.errorNumber] as? Int) ?? 0,
                                              message: (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"))
            } else {
                result = .success(output?.stringValue ?? "")
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}

// MARK: - Controller

@MainActor
final class SpotifyController: ObservableObject {
    struct Track: Equatable {
        var id: String
        var name: String
        var artist: String
        var album: String
        var artworkURL: URL?
        var duration: Double   // seconds
    }

    static let bundleID = "com.spotify.client"

    @Published var running = false
    @Published var playing = false
    @Published var track: Track?
    @Published var position: Double = 0
    @Published var volume: Double = 50
    @Published var shuffling = false
    @Published var repeating = false
    @Published var artwork: NSImage?
    @Published var permissionError: String?

    private var timer: Timer?
    private var inFlight = false
    private var lastPoll = Date.distantPast

    private static let sep = "|~|"
    private static let stateScript = """
    tell application "Spotify"
        set s to player state as string
        if s is "stopped" then return "stopped"
        set t to current track
        return s & "\(sep)" & (id of t) & "\(sep)" & (name of t) & "\(sep)" & (artist of t) & "\(sep)" & (album of t) & "\(sep)" & (artwork url of t) & "\(sep)" & (duration of t) & "\(sep)" & (player position) & "\(sep)" & (sound volume) & "\(sep)" & (shuffling) & "\(sep)" & (repeating)
    end tell
    """

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Spotify broadcasts this whenever the track or play state changes: refresh immediately.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    private func tick() {
        // Advance locally between polls so the progress bar moves smoothly,
        // and only hit Spotify every second while playing, every 4s when idle.
        if playing, let t = track { position = min(position + 1, t.duration) }
        if playing || Date().timeIntervalSince(lastPoll) > 4 { poll() }
    }

    func poll() {
        running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        // Never `tell` Spotify while it's closed — that would launch it.
        guard running else { playing = false; track = nil; artwork = nil; return }
        guard !inFlight else { return }
        inFlight = true
        lastPoll = Date()
        AppleScript.run(Self.stateScript) { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            switch result {
            case .success(let out): self.apply(out)
            case .failure(let e):
                self.permissionError = e.notAuthorized
                    ? "Allow PortableDash to control Spotify in System Settings → Privacy & Security → Automation."
                    : nil
            }
        }
    }

    private func apply(_ out: String) {
        permissionError = nil
        let f = out.components(separatedBy: Self.sep)
        guard f.count >= 11 else { playing = false; track = nil; artwork = nil; return }
        func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        let t = Track(id: f[1], name: f[2], artist: f[3], album: f[4], artworkURL: URL(string: f[5]),
                      duration: num(f[6]) / 1000)
        playing = f[0] == "playing"
        if t.artworkURL != track?.artworkURL { loadArtwork(t.artworkURL) }
        track = t
        position = num(f[7])
        volume = num(f[8])
        shuffling = f[9] == "true"
        repeating = f[10] == "true"
    }

    private func loadArtwork(_ url: URL?) {
        guard let url else { artwork = nil; return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let img = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async { [weak self] in
                if self?.track?.artworkURL == url || self?.track == nil { self?.artwork = img }
            }
        }.resume()
    }

    // MARK: Commands

    private func command(_ cmd: String) {
        guard running else { return }
        AppleScript.run("tell application \"Spotify\" to \(cmd)") { [weak self] _ in self?.poll() }
    }

    func playPause() { playing.toggle(); command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }
    func seek(_ seconds: Double) { position = seconds; command("set player position to \(Int(seconds))") }
    func setVolume(_ v: Double) { volume = v; command("set sound volume to \(Int(v))") }
    func toggleShuffle() { shuffling.toggle(); command("set shuffling to \(shuffling)") }
    func toggleRepeat() { repeating.toggle(); command("set repeating to \(repeating)") }

    func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            NSWorkspace.shared.open(URL(string: "https://www.spotify.com/download/mac/")!)
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.poll() }
        }
    }

    func bringToFront() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first?.activate()
    }
}

// MARK: - View

struct SpotifyPanel: View {
    @EnvironmentObject var sp: SpotifyController
    @EnvironmentObject var settings: SettingsStore
    @State private var scrub: Double?
    @State private var liveVolume: Double?

    var body: some View {
        playerView
            .overlay(alignment: .topTrailing) {
                // With panel title bars hidden, keep a way to open the browser.
                if !settings.s.showPanelTitles {
                    TitleButton("magnifyingglass", help: "Search & pick songs") { settings.openSpotifyBrowser(sp) }
                        .padding(8)
                }
            }
    }

    private var playerView: some View {
        GeometryReader { geo in
            ZStack {
                if let art = sp.artwork {
                    Image(nsImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 50)
                        .opacity(0.45)
                        .clipped()
                        .allowsHitTesting(false)
                }
                content(geo.size)
                    .padding(14)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func content(_ size: CGSize) -> some View {
        if !sp.running {
            placeholder(icon: "music.note", title: "Spotify isn't open",
                        button: "Open Spotify") { sp.launch() }
        } else if let err = sp.permissionError {
            placeholder(icon: "lock.shield", title: err, button: "Open Automation Settings") {
                AppleScript.openAutomationSettings()
            }
        } else if let t = sp.track {
            if size.width > size.height * 1.25 {
                HStack(spacing: 18) {
                    artwork(side: min(size.height - 28, size.width * 0.38))
                    VStack(alignment: .leading, spacing: 8) {
                        info(t, align: .leading)
                        progress(t)
                        controls
                        if size.height > 170 { volume }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 10) {
                    artwork(side: max(min(size.width - 28, size.height - 230), 60))
                    info(t, align: .center)
                    progress(t)
                    controls
                    if size.height > 380 { volume }
                }
                .frame(maxHeight: .infinity)
            }
        } else {
            placeholder(icon: "play.circle", title: "Nothing playing", button: "Pick something") {
                settings.openSpotifyBrowser(sp)
            }
        }
    }

    private func artwork(side: CGFloat) -> some View {
        Group {
            if let art = sp.artwork {
                Image(nsImage: art).resizable().scaledToFill()
            } else {
                ZStack {
                    settings.accent.opacity(0.25)
                    Image(systemName: "music.note").font(.system(size: side * 0.35))
                }
            }
        }
        .frame(width: max(side, 0), height: max(side, 0))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .onTapGesture { sp.bringToFront() }
        .help("Show Spotify")
    }

    private func info(_ t: SpotifyController.Track, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 2) {
            Text(t.name).font(.system(.title3, design: .rounded).weight(.semibold))
            Text(t.artist).font(.callout).foregroundStyle(.secondary)
            Text(t.album).font(.caption).foregroundStyle(.tertiary)
        }
        .lineLimit(1)
        .multilineTextAlignment(align == .center ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: align == .center ? .center : .leading)
    }

    private func progress(_ t: SpotifyController.Track) -> some View {
        let dur = max(t.duration, 1)
        let pos = min(scrub ?? sp.position, dur)
        return VStack(spacing: 2) {
            Slider(value: Binding(get: { pos }, set: { scrub = $0 }), in: 0...dur) { editing in
                if !editing, let v = scrub { sp.seek(v); scrub = nil }
            }
            .controlSize(.small)
            .tint(settings.accent)
            HStack {
                Text(Self.time(pos))
                Spacer()
                Text("-" + Self.time(dur - pos))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 22) {
            iconButton("shuffle", on: sp.shuffling, size: 13) { sp.toggleShuffle() }
            iconButton("backward.fill", size: 17) { sp.previous() }
            Button(action: sp.playPause) {
                Image(systemName: sp.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(settings.onAccent)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(settings.accent))
                    .shadow(color: settings.accent.opacity(0.5), radius: 8)
            }
            .buttonStyle(.plain)
            iconButton("forward.fill", size: 17) { sp.next() }
            iconButton("repeat", on: sp.repeating, size: 13) { sp.toggleRepeat() }
        }
        .frame(maxWidth: .infinity)
    }

    private var volume: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").font(.caption)
            Slider(value: Binding(get: { liveVolume ?? sp.volume }, set: { liveVolume = $0 }), in: 0...100) { editing in
                if !editing, let v = liveVolume { sp.setVolume(v); liveVolume = nil }
            }
            .controlSize(.mini)
            .tint(settings.accent)
            Image(systemName: "speaker.wave.3.fill").font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
    }

    private func iconButton(_ name: String, on: Bool = false, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(on ? settings.accent : .primary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func placeholder(icon: String, title: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(settings.accent)
            Text(title).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(button, action: action).buttonStyle(.borderedProminent).tint(settings.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func time(_ s: Double) -> String {
        let s = max(Int(s), 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Browser overlay

/// open.spotify.com in a big card floating over the dashboard, for searching and picking songs
/// without resizing the layout. Picks play through the Spotify Mac app (via Spotify Connect).
struct SpotifyBrowserOverlay: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var web: WebSessions
    @EnvironmentObject var sp: SpotifyController

    var body: some View {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: CGFloat(settings.s.cornerRadius), style: .continuous)
            ZStack {
                Color.black.opacity(0.4)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(settings.accent)
                        Text("Spotify").font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text(sp.running ? "Plays through your Spotify app" : "Starting the Spotify app…")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        WebTitleButtons(session: web.spotifyBrowser)
                        Button(action: close) {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.primary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .help("Close (Esc)")
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)

                    WebViewHost(webView: web.spotifyBrowser.webView,
                                cornerRadius: max(CGFloat(settings.s.cornerRadius) - 6, 4)) { _ in }
                        .padding([.horizontal, .bottom], 6)
                }
                .frame(width: max(min(geo.size.width - 40, 1100), 300),
                       height: max(min(geo.size.height - 40, 860), 300))
                .background(.regularMaterial, in: shape)
                .clipShape(shape)
                .overlay(shape.strokeBorder(settings.accent.opacity(0.45), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 10)
            }
        }
    }

    private func close() { settings.showSpotifyBrowser = false }
}
