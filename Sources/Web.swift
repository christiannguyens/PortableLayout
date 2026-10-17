// Web.swift
// Web panels: Claude and any site you add with the + button. Each runs in its own WebKit view;
// logins are kept between launches.

import SwiftUI
import WebKit

@MainActor
final class WebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    @Published var canGoBack = false
    @Published var isLoading = false
    let home: String

    private let domains: [String]          // links within these stay in the panel
    private var observations: [NSKeyValueObservation] = []
    private var popups: [NSWindow] = []

    // Present as Safari so sites and sign-in providers (e.g. Google) don't reject the embedded browser.
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    init(home: String, mobile: Bool = false, extraDomains: [String] = []) {
        self.home = home
        let host = URL(string: home)?.host ?? ""
        domains = [Self.baseDomain(host)] + extraDomains

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()    // shared, persistent cookies = stay logged in
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.customUserAgent = mobile ? Self.mobileUA : Self.desktopUA
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        observations = [
            webView.observe(\.canGoBack) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.isLoading) { [weak self] wv, _ in
                DispatchQueue.main.async { self?.isLoading = wv.isLoading }
            },
        ]
        load(home)
    }

    func load(_ urlString: String) {
        let url = URL(string: urlString) ?? URL(string: home) ?? URL(string: "about:blank")!
        webView.load(URLRequest(url: url))
    }

    func goHome() { load(home) }
    func reload() { webView.reload() }
    func back() { webView.goBack() }
    func openInBrowser() { if let url = webView.url { NSWorkspace.shared.open(url) } }

    /// Stop audio/video before the panel is thrown away.
    func tearDown() {
        webView.pauseAllMediaPlayback()
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
        popups.forEach { $0.close() }
    }

    /// "www.youtube.com" -> "youtube.com"
    private static func baseDomain(_ host: String) -> String {
        let parts = host.split(separator: ".")
        return parts.count > 2 ? parts.suffix(2).joined(separator: ".") : host
    }

    private func isInternal(_ host: String) -> Bool {
        domains.contains { !$0.isEmpty && (host == $0 || host.hasSuffix("." + $0)) }
    }

    private static func isSignIn(_ host: String) -> Bool {
        ["accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com"].contains(host)
            || host.hasSuffix(".google.com") || host.hasSuffix(".wustl.edu") || host.hasSuffix("facebook.com")
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        // Clicked links to other sites go to your normal browser instead of replacing the panel.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame ?? true,
           let url = navigationAction.request.url, let host = url.host,
           !isInternal(host), !Self.isSignIn(host) {
            NSWorkspace.shared.open(url)
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = dir.appendingPathComponent(suggestedFilename)
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            n += 1
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        return dest
    }

    // MARK: Pop-ups (sign-in windows), file pickers, dialogs

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, let host = url.host, !host.isEmpty,
           !isInternal(host), !Self.isSignIn(host) {
            NSWorkspace.shared.open(url)
            return nil
        }
        // Same site opening a new tab (e.g. a target=_blank link): just navigate this panel.
        if let url = navigationAction.request.url, let host = url.host, isInternal(host),
           navigationAction.navigationType == .linkActivated {
            webView.load(navigationAction.request)
            return nil
        }
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 700), configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.uiDelegate = self
        let win = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Sign in"
        win.contentView = popup
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        popups.append(win)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.filter { $0.contentView === webView }.forEach { $0.close() }
        popups.removeAll { $0.contentView === webView || !$0.isVisible }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Lets sites in the panel (e.g. Claude's voice mode) use the mic; macOS still asks you once.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        isInternal(origin.host) ? .grant : .deny
    }
}

// MARK: - Keeps one WebSession alive per panel, so layout changes never reload a page

@MainActor
final class WebSessions: ObservableObject {
    private var sessions: [PanelID: WebSession] = [:]
    private var configs: [PanelID: WebPanel] = [:]

    func session(for id: PanelID, settings: SettingsStore) -> WebSession? {
        if id == PanelKind.claude.rawValue {
            if let s = sessions[id] { return s }
            let s = WebSession(home: settings.s.claudeHome, extraDomains: ["anthropic.com"])
            sessions[id] = s
            return s
        }
        guard let panel = settings.webPanel(id) else { return nil }
        // Rebuild if the URL or mobile setting was edited.
        if let s = sessions[id], configs[id]?.url == panel.url, configs[id]?.mobile == panel.mobile { return s }
        sessions[id]?.tearDown()
        let s = WebSession(home: panel.url, mobile: panel.mobile)
        sessions[id] = s
        configs[id] = panel
        return s
    }

    var claude: WebSession? { sessions[PanelKind.claude.rawValue] }

    /// open.spotify.com, shown in the Spotify panel's Browse mode.
    lazy var spotifyBrowser = WebSession(home: "https://open.spotify.com", extraDomains: ["scdn.co", "spotifycdn.com"])

    func remove(_ id: PanelID) {
        sessions[id]?.tearDown()
        sessions[id] = nil
        configs[id] = nil
    }
}

// MARK: - Hosting a web view in SwiftUI

/// Container that reports hover itself: SwiftUI's onHover can miss events over a WKWebView.
final class HoverContainer: NSView {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    let cornerRadius: CGFloat
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverContainer {
        let container = HoverContainer()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        attach(to: container)
        return container
    }

    func updateNSView(_ container: HoverContainer, context: Context) {
        container.layer?.cornerRadius = cornerRadius
        container.layer?.cornerCurve = .continuous
        container.onHover = onHover
        if webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: HoverContainer) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        container.layer?.cornerRadius = cornerRadius
        container.onHover = onHover
    }
}

struct WebPanelView: View {
    @EnvironmentObject var settings: SettingsStore
    let session: WebSession
    let cardHovering: Bool
    @State private var webHovering = false

    var body: some View {
        let radius = max(CGFloat(settings.s.cornerRadius) - 6, 4)
        let concealed = settings.s.privacyMode && !(cardHovering || webHovering)
        WebViewHost(webView: session.webView, cornerRadius: radius) { webHovering = $0 }
            .overlay {
                if concealed {
                    ZStack {
                        Rectangle().fill(.ultraThickMaterial)
                        Label("Hover to reveal", systemImage: "eye.slash")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .allowsHitTesting(false)
                }
            }
            .padding([.horizontal, .bottom], 6)
            .padding(.top, settings.s.showPanelTitles ? 0 : 6)
    }
}

/// Back / reload / home / open-in-browser buttons for a web panel's title bar.
struct WebTitleButtons: View {
    @ObservedObject var session: WebSession
    var homeHelp = "Home"
    var homeSymbol = "house"

    var body: some View {
        if session.isLoading { ProgressView().controlSize(.mini) }
        TitleButton("chevron.left", help: "Back") { session.back() }.disabled(!session.canGoBack)
        TitleButton("arrow.clockwise", help: "Reload") { session.reload() }
        TitleButton(homeSymbol, help: homeHelp) { session.goHome() }
        TitleButton("safari", help: "Open in browser") { session.openInBrowser() }
    }
}
