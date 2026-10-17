// HeaderWidgets.swift
// Header extras: your next calendar event, and a scrolling stock ticker.

import SwiftUI
import EventKit

// MARK: - Next event (via macOS Calendar, which syncs your Google account)

@MainActor
final class CalendarStore: ObservableObject {
    enum Access { case unknown, granted, denied }

    struct Event: Equatable {
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let color: Color
    }

    @Published var access: Access = .unknown
    @Published var next: Event?

    private let store = EKEventStore()
    private var timer: Timer?

    init() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.access = granted ? .granted : .denied
                self.refresh()
            }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard access == .granted else { next = nil; return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                 end: now.addingTimeInterval(14 * 86400), calendars: nil)
        // Prefer timed events that haven't ended; fall back to an upcoming all-day event.
        let events = store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        let pick = events.first { !$0.isAllDay } ?? events.first { $0.isAllDay && $0.startDate > now }
        next = pick.map {
            Event(title: $0.title ?? "Untitled", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay,
                  color: Color(nsColor: $0.calendar?.color ?? .systemBlue))
        }
    }

    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    static func openInternetAccounts() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
    }
}

struct NextEventChip: View {
    @EnvironmentObject var cal: CalendarStore
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(spacing: 7) {
                if let e = cal.next {
                    Capsule().fill(e.color).frame(width: 3, height: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(e.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(Self.when(e, now: ctx.date)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Image(systemName: "calendar").foregroundStyle(settings.accent)
                    Text(cal.access == .denied ? "Allow Calendar access" : "Nothing coming up")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: 240, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
            .onTapGesture {
                if cal.access == .denied { CalendarStore.openPrivacySettings() }
                else { NSWorkspace.shared.open(URL(string: "https://calendar.google.com")!) }
            }
            .help(cal.access == .denied ? "Click to open Calendar privacy settings" : "Open Google Calendar")
        }
    }

    /// "Now · until 3:00 PM", "in 25 min", "Today 3:00 PM", "Tomorrow 9:00 AM", "Thu, Oct 23 · 9:00 AM"
    static func when(_ e: CalendarStore.Event, now: Date) -> String {
        let cal = Calendar.current
        let time = e.start.formatted(date: .omitted, time: .shortened)
        if e.isAllDay {
            if cal.isDateInToday(e.start) { return "Today · all day" }
            if cal.isDateInTomorrow(e.start) { return "Tomorrow · all day" }
            return e.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " · all day"
        }
        if e.start <= now { return "Now · until " + e.end.formatted(date: .omitted, time: .shortened) }
        let mins = Int(e.start.timeIntervalSince(now) / 60)
        if mins < 60 { return "in \(max(mins, 1)) min · \(time)" }
        if cal.isDateInToday(e.start) { return "Today · \(time)" }
        if cal.isDateInTomorrow(e.start) { return "Tomorrow · \(time)" }
        return e.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " · \(time)"
    }
}

// MARK: - Stock ticker

@MainActor
final class StockStore: ObservableObject {
    struct Quote: Identifiable, Equatable {
        let symbol: String
        let price: Double
        let change: Double     // percent
        var id: String { symbol }
    }

    @Published var quotes: [Quote] = []
    private var symbols: [String] = []
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func setSymbols(_ raw: String) {
        let list = raw.uppercased()
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard list != symbols else { return }
        symbols = list
        quotes = quotes.filter { list.contains($0.symbol) }
        refresh()
    }

    func refresh() {
        let list = symbols
        guard !list.isEmpty else { quotes = []; return }
        Task {
            // Yahoo Finance's public chart endpoint: no API key, ~1 min delayed, unofficial.
            let results = await withTaskGroup(of: Quote?.self) { group in
                for sym in list { group.addTask { await Self.fetch(sym) } }
                var out: [Quote] = []
                for await q in group { if let q { out.append(q) } }
                return out
            }
            guard !results.isEmpty else { return }
            let bySymbol = Dictionary(results.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
            quotes = list.compactMap { bySymbol[$0] }
        }
    }

    nonisolated private static func fetch(_ symbol: String) async -> Quote? {
        guard let enc = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(enc)?range=1d&interval=1d")
        else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = json["chart"] as? [String: Any],
              let meta = ((chart["result"] as? [[String: Any]])?.first)?["meta"] as? [String: Any],
              let price = meta["regularMarketPrice"] as? Double
        else { return nil }
        let prev = (meta["chartPreviousClose"] as? Double) ?? (meta["previousClose"] as? Double) ?? price
        return Quote(symbol: symbol, price: price, change: prev == 0 ? 0 : (price - prev) / prev * 100)
    }
}

/// A fixed-width box whose contents scroll sideways forever. Hover to pause.
struct StockTicker: View {
    @EnvironmentObject var stocks: StockStore
    @EnvironmentObject var settings: SettingsStore
    @State private var contentWidth: CGFloat = 0
    @State private var hovering = false
    @State private var pausedOffset: CGFloat = 0
    @State private var startDate = Date()
    /// Stretch to fill the available width instead of using the fixed ticker width.
    var fill = false

    private let speed: CGFloat = 32       // points per second
    private let spacing: CGFloat = 28

    var body: some View {
        Group {
            if stocks.quotes.isEmpty {
                Text("Loading stocks…").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: hovering)) { ctx in
                    let loop = contentWidth + spacing
                    let offset = hovering || loop <= spacing
                        ? pausedOffset
                        : (CGFloat(ctx.date.timeIntervalSince(startDate)) * speed).truncatingRemainder(dividingBy: loop)
                    HStack(spacing: spacing) {
                        row.background(GeometryReader { g in
                            Color.clear.onAppear { contentWidth = g.size.width }
                                .onChange(of: g.size.width) { _, w in contentWidth = w }
                        })
                        row   // second copy makes the loop seamless
                    }
                    .fixedSize()
                    .offset(x: -offset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: fill ? nil : CGFloat(settings.s.tickerWidth), height: 34)
        .frame(minWidth: fill ? 0 : nil, maxWidth: fill ? .infinity : nil)
        .padding(.horizontal, 2)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                     .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
        .onHover { inside in
            if inside {
                let loop = contentWidth + spacing
                pausedOffset = loop > spacing
                    ? (CGFloat(Date().timeIntervalSince(startDate)) * speed).truncatingRemainder(dividingBy: loop) : 0
            } else {
                // Resume from where it paused.
                startDate = Date().addingTimeInterval(-Double(pausedOffset / speed))
            }
            hovering = inside
        }
        .onAppear { stocks.setSymbols(settings.s.tickerSymbols) }
        .onChange(of: settings.s.tickerSymbols) { _, v in stocks.setSymbols(v) }
        .help("Prices from Yahoo Finance, refreshed every minute · hover to pause")
    }

    private var row: some View {
        HStack(spacing: spacing) {
            ForEach(stocks.quotes) { q in
                let up = q.change >= 0
                HStack(spacing: 5) {
                    Text(q.symbol).font(.system(size: 11.5, weight: .bold, design: .rounded))
                    Text(Self.price(q.price)).font(.system(size: 11.5).monospacedDigit())
                    Text(String(format: "%@%.2f%%", up ? "▲" : "▼", abs(q.change)))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(up ? Color.green : Color.red)
                }
                .fixedSize()
            }
        }
    }

    static func price(_ p: Double) -> String {
        p >= 1000 ? String(format: "%.0f", p) : String(format: "%.2f", p)
    }
}
