// Messages.swift
// Reads your iMessage/SMS history from ~/Library/Messages/chat.db (read-only, needs
// Full Disk Access) and sends replies by asking the Messages app over AppleScript.

import SwiftUI
import AppKit
import SQLite3
@preconcurrency import Contacts

// MARK: - Models

struct ChatSummary: Identifiable, Equatable {
    let id: Int64
    let guid: String
    let identifier: String     // phone/email for 1:1 chats
    let title: String
    let preview: String
    let date: Date
    let isGroup: Bool
    let lastFromMe: Bool
    var unread: Int
}

struct ChatMessage: Identifiable, Equatable {
    let id: Int64
    let text: String
    let isFromMe: Bool
    let date: Date
    let sender: String
}

// MARK: - SQLite helper

final class SQLiteDB {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        sqlite3_busy_timeout(db, 1500)
    }

    deinit { sqlite3_close(db) }

    struct Row {
        let stmt: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func string(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func data(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }

    func query(_ sql: String, _ args: [Any] = [], _ each: (Row) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "sqlite", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { each(Row(stmt: stmt)) }
            else if rc == SQLITE_DONE { break }
            else { throw NSError(domain: "sqlite", code: Int(rc),
                                 userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]) }
        }
    }
}

// MARK: - Store

@MainActor
final class MessagesStore: ObservableObject {
    enum Access: Equatable { case unknown, ok, needsFullDiskAccess(String) }

    @Published var access: Access = .unknown
    @Published var chats: [ChatSummary] = []
    @Published var selectedChatID: Int64? { didSet { if selectedChatID != oldValue { messages = []; refresh(force: true) } } }
    @Published var messages: [ChatMessage] = []
    @Published var sendError: String?
    @Published var sending = false

    var selectedChat: ChatSummary? { chats.first { $0.id == selectedChatID } }

    // Everything below is only touched on `queue`.
    private let queue = DispatchQueue(label: "portabledash.messages")
    nonisolated(unsafe) private var db: SQLiteDB?
    nonisolated(unsafe) private var lastMaxRowID: Int64 = -1
    nonisolated(unsafe) private var contacts: [String: String] = [:]
    nonisolated(unsafe) private var seen: [Int64: Int64] = [:]   // chat -> newest message ROWID viewed here

    private var timer: Timer?
    nonisolated private static let dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"

    init() {
        loadContacts()
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: false) }
        }
    }

    func retry() {
        queue.async { [weak self] in self?.db = nil; self?.lastMaxRowID = -1 }
        refresh(force: true)
    }

    func refresh(force: Bool) {
        let selected = selectedChatID
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if self.db == nil { self.db = try SQLiteDB(path: Self.dbPath) }
                guard let db = self.db else { return }
                var maxID: Int64 = 0
                try db.query("SELECT MAX(ROWID) FROM message") { maxID = $0.int(0) }
                guard force || maxID != self.lastMaxRowID else { return }
                self.lastMaxRowID = maxID

                var msgs: [ChatMessage]? = nil
                if let selected {
                    msgs = try self.loadMessages(db, chat: selected)
                    if let last = msgs?.last { self.seen[selected] = max(self.seen[selected] ?? 0, last.id) }
                }
                let chats = try self.loadChats(db)
                DispatchQueue.main.async {
                    self.access = .ok
                    self.chats = chats
                    if let msgs, self.selectedChatID == selected { self.messages = msgs }
                }
            } catch {
                self.db = nil
                let msg = error.localizedDescription
                DispatchQueue.main.async { self.access = .needsFullDiskAccess(msg) }
            }
        }
    }

    // MARK: Queries (run on `queue`)

    nonisolated private func loadChats(_ db: SQLiteDB) throws -> [ChatSummary] {
        var participants: [Int64: [String]] = [:]
        try db.query("SELECT chj.chat_id, h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id") {
            participants[$0.int(0), default: []].append($0.string(1) ?? "")
        }

        // Unread = not read, not mine, in the last two weeks, and newer than what we've shown here.
        var unread: [Int64: Int] = [:]
        let twoWeeksAgo = Int64((Date().timeIntervalSinceReferenceDate - 14 * 86400) * 1_000_000_000)
        try db.query("""
            SELECT cmj.chat_id, m.ROWID FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE m.is_read = 0 AND m.is_from_me = 0 AND m.item_type = 0
              AND m.associated_message_type = 0 AND m.date > ?
            """, [twoWeeksAgo]) { row in
            let chat = row.int(0)
            if row.int(1) > (self.seen[chat] ?? 0) { unread[chat, default: 0] += 1 }
        }

        var out: [ChatSummary] = []
        try db.query("""
            SELECT c.ROWID, c.guid, c.chat_identifier, IFNULL(c.display_name, ''), c.style,
                   m.text, m.attributedBody, m.is_from_me, m.date, m.cache_has_attachments
            FROM chat c
            JOIN (SELECT chat_id, MAX(message_id) AS mid FROM chat_message_join GROUP BY chat_id) l
              ON l.chat_id = c.ROWID
            JOIN message m ON m.ROWID = l.mid
            ORDER BY m.date DESC
            LIMIT 60
            """) { row in
            let id = row.int(0)
            let identifier = row.string(2) ?? ""
            let displayName = row.string(3) ?? ""
            let isGroup = row.int(4) == 43
            let people = participants[id] ?? [identifier]
            let title: String
            if !displayName.isEmpty { title = displayName }
            else if isGroup { title = people.map { self.shortName($0) }.joined(separator: ", ") }
            else { title = self.name(for: identifier) }
            let text = Self.messageText(row.string(5), row.data(6), hasAttachment: row.int(9) != 0) ?? ""
            out.append(ChatSummary(id: id, guid: row.string(1) ?? "", identifier: identifier, title: title,
                                   preview: text, date: Self.appleDate(row.int(8)), isGroup: isGroup,
                                   lastFromMe: row.int(7) != 0, unread: unread[id] ?? 0))
        }
        return out
    }

    nonisolated private func loadMessages(_ db: SQLiteDB, chat: Int64) throws -> [ChatMessage] {
        var out: [ChatMessage] = []
        try db.query("""
            SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date, IFNULL(h.id, ''), m.cache_has_attachments
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id = ? AND m.associated_message_type = 0 AND m.item_type = 0
            ORDER BY m.date DESC
            LIMIT 120
            """, [chat]) { row in
            guard let text = Self.messageText(row.string(1), row.data(2), hasAttachment: row.int(6) != 0) else { return }
            let fromMe = row.int(3) != 0
            out.append(ChatMessage(id: row.int(0), text: text, isFromMe: fromMe, date: Self.appleDate(row.int(4)),
                                   sender: fromMe ? "Me" : self.shortName(row.string(5) ?? "")))
        }
        return out.reversed()
    }

    // MARK: Text decoding

    nonisolated static func appleDate(_ v: Int64) -> Date {
        // Newer macOS stores nanoseconds since 2001; older stored seconds.
        Date(timeIntervalSinceReferenceDate: v > 1_000_000_000_000 ? Double(v) / 1e9 : Double(v))
    }

    nonisolated static func messageText(_ text: String?, _ body: Data?, hasAttachment: Bool) -> String? {
        var s = text ?? ""
        if s.isEmpty, let body { s = decodeAttributedBody(body) ?? "" }
        s = s.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return hasAttachment ? "📎 Attachment" : nil }
        return s
    }

    /// Recent macOS versions leave `text` empty and store an archived NSAttributedString in
    /// `attributedBody` (typedstream format). Pull the plain string out of it by hand.
    nonisolated static func decodeAttributedBody(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard bytes.count > marker.count,
              let start = (0...(bytes.count - marker.count)).first(where: { Array(bytes[$0..<$0 + marker.count]) == marker })
        else { return nil }
        var i = start + marker.count + 5   // skip class info up to the '+' string tag
        guard i < bytes.count else { return nil }
        var length = Int(bytes[i]); i += 1
        if length == 0x81, i + 2 <= bytes.count {
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8; i += 2
        } else if length == 0x82, i + 4 <= bytes.count {
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24; i += 4
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(decoding: bytes[i..<i + length], as: UTF8.self)
    }

    // MARK: Contacts

    nonisolated private static func key(for handle: String) -> String {
        if handle.contains("@") { return handle.lowercased() }
        let digits = handle.filter(\.isNumber)
        return String(digits.suffix(10))
    }

    nonisolated private func name(for handle: String) -> String {
        contacts[Self.key(for: handle)] ?? handle
    }

    nonisolated private func shortName(_ handle: String) -> String {
        guard let n = contacts[Self.key(for: handle)] else { return handle }
        return n.components(separatedBy: " ").first ?? n
    }

    private func loadContacts() {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { [weak self] granted, _ in
            guard granted, let self else { return }
            self.queue.async {
                let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                            CNContactOrganizationNameKey, CNContactPhoneNumbersKey,
                            CNContactEmailAddressesKey] as [CNKeyDescriptor]
                var map: [String: String] = [:]
                try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
                    var name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                    if name.isEmpty { name = c.nickname.isEmpty ? c.organizationName : c.nickname }
                    guard !name.isEmpty else { return }
                    for p in c.phoneNumbers { map[Self.key(for: p.value.stringValue)] = name }
                    for e in c.emailAddresses { map[(e.value as String).lowercased()] = name }
                }
                self.contacts = map
                DispatchQueue.main.async { self.refresh(force: true) }
            }
        }
    }

    // MARK: Sending

    func send(_ text: String, to chat: ChatSummary, completion: @escaping (Bool) -> Void) {
        let body = AppleScript.escape(text)
        sending = true
        sendError = nil
        let primary = "tell application \"Messages\" to send \"\(body)\" to chat id \"\(AppleScript.escape(chat.guid))\""
        AppleScript.run(primary) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.finishSend(ok: true, completion)
            case .failure(let e) where !chat.isGroup && !e.notAuthorized:
                // Fall back to addressing the person directly.
                let fallback = """
                tell application "Messages"
                    set svc to 1st account whose service type = iMessage
                    send "\(body)" to participant "\(AppleScript.escape(chat.identifier))" of svc
                end tell
                """
                AppleScript.run(fallback) { [weak self] r in
                    if case .failure(let e2) = r { self?.sendError = e2.message }
                    self?.finishSend(ok: (try? r.get()) != nil, completion)
                }
            case .failure(let e):
                self.sendError = e.notAuthorized
                    ? "Allow PortableDash to control Messages in System Settings → Privacy & Security → Automation."
                    : e.message
                self.finishSend(ok: false, completion)
            }
        }
    }

    private func finishSend(ok: Bool, _ completion: (Bool) -> Void) {
        sending = false
        completion(ok)
        for delay in [0.5, 1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh(force: true) }
        }
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    static func openMessagesApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Messages.app"))
    }
}

// MARK: - Views

struct MessagesPanel: View {
    @EnvironmentObject var store: MessagesStore
    @EnvironmentObject var settings: SettingsStore
    let concealed: Bool

    var body: some View {
        switch store.access {
        case .unknown:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsFullDiskAccess(let detail):
            FullDiskAccessView(detail: detail)
        case .ok:
            GeometryReader { geo in
                if geo.size.width >= 560 {
                    HStack(spacing: 0) {
                        ChatList(concealed: concealed)
                            .frame(width: min(300, geo.size.width * 0.38))
                        Divider().opacity(0.5)
                        ConversationView(concealed: concealed, showBack: false)
                    }
                } else if store.selectedChatID != nil {
                    ConversationView(concealed: concealed, showBack: true)
                } else {
                    ChatList(concealed: concealed)
                }
            }
        }
    }
}

private struct FullDiskAccessView: View {
    @EnvironmentObject var store: MessagesStore
    @EnvironmentObject var settings: SettingsStore
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.doc").font(.system(size: 34)).foregroundStyle(settings.accent)
            Text("Messages needs Full Disk Access").font(.headline)
            Text("macOS keeps your message history in a protected folder. Turn on **PortableDash** under Privacy & Security → Full Disk Access, then relaunch.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack {
                Button("Open Settings") { MessagesStore.openFullDiskAccessSettings() }
                    .buttonStyle(.borderedProminent).tint(settings.accent)
                Button("Relaunch") { AppDelegate.relaunch() }
                Button("Retry") { store.retry() }
            }
            Text(detail).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChatList: View {
    @EnvironmentObject var store: MessagesStore
    @EnvironmentObject var settings: SettingsStore
    let concealed: Bool
    @State private var search = ""

    var filtered: [ChatSummary] {
        search.isEmpty ? store.chats : store.chats.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.preview.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
            .padding(10)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { chat in
                        ChatRow(chat: chat, selected: chat.id == store.selectedChatID)
                            .contentShape(Rectangle())
                            .onTapGesture { store.selectedChatID = chat.id }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .blur(radius: concealed ? 9 : 0)
        }
    }
}

private struct ChatRow: View {
    @EnvironmentObject var settings: SettingsStore
    let chat: ChatSummary
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: chat.title, isGroup: chat.isGroup, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(chat.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.shortDate(chat.date)).font(.caption2).foregroundStyle(.secondary)
                }
                Text((chat.lastFromMe ? "You: " : "") + chat.preview)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            if chat.unread > 0 {
                Circle().fill(settings.accent).frame(width: 9, height: 9)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? settings.accent.opacity(0.28) : .clear))
    }

    static func shortDate(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(d) { f.timeStyle = .short }
        else if cal.isDateInYesterday(d) { return "Yesterday" }
        else if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { f.dateFormat = "EEEE" }
        else { f.dateStyle = .short }
        return f.string(from: d)
    }
}

struct Avatar: View {
    @EnvironmentObject var settings: SettingsStore
    let name: String
    let isGroup: Bool
    let size: CGFloat

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined()
        return s.isEmpty || s.first?.isNumber == true || s.first == "+" ? "" : s.uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [settings.accent.opacity(0.9), settings.accent.opacity(0.45)],
                                         startPoint: .top, endPoint: .bottom))
            if isGroup { Image(systemName: "person.2.fill").font(.system(size: size * 0.36)) }
            else if initials.isEmpty { Image(systemName: "person.fill").font(.system(size: size * 0.42)) }
            else { Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)) }
        }
        .foregroundStyle(settings.onAccent)
        .frame(width: size, height: size)
    }
}

private struct ConversationView: View {
    @EnvironmentObject var store: MessagesStore
    @EnvironmentObject var settings: SettingsStore
    let concealed: Bool
    let showBack: Bool
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        if let chat = store.selectedChat {
            VStack(spacing: 0) {
                header(chat)
                Divider().opacity(0.4)
                transcript(chat).blur(radius: concealed ? 9 : 0)
                composer(chat)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 30))
                Text("Pick a conversation").font(.callout)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ chat: ChatSummary) -> some View {
        HStack(spacing: 8) {
            if showBack {
                Button { store.selectedChatID = nil } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
            }
            Avatar(name: chat.title, isGroup: chat.isGroup, size: 24)
            Text(chat.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func transcript(_ chat: ChatSummary) -> some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(store.messages.enumerated()), id: \.element.id) { i, msg in
                            let prev = i > 0 ? store.messages[i - 1] : nil
                            if prev == nil || msg.date.timeIntervalSince(prev!.date) > 45 * 60 {
                                Text(msg.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 10)
                            }
                            if chat.isGroup && !msg.isFromMe && prev?.sender != msg.sender {
                                Text(msg.sender).font(.caption2).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6).padding(.top, 4)
                            }
                            Bubble(msg: msg, maxWidth: geo.size.width * 0.74)
                                .id(msg.id)
                        }
                    }
                    .padding(10)
                }
                .onAppear { proxy.scrollTo(store.messages.last?.id, anchor: .bottom) }
                .onChange(of: store.messages.last?.id) { _, id in
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private func composer(_ chat: ChatSummary) -> some View {
        VStack(spacing: 4) {
            if let err = store.sendError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            HStack(spacing: 8) {
                TextField(chat.isGroup ? "Message group" : "Message \(chat.title)", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($composerFocused)
                    .onSubmit { send(chat) }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Button { send(chat) } label: {
                    Image(systemName: store.sending ? "ellipsis.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(draft.isEmpty ? Color.secondary : settings.accent)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || store.sending)
            }
        }
        .padding(10)
    }

    private func send(_ chat: ChatSummary) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.sending else { return }
        store.send(text, to: chat) { ok in
            if ok { draft = "" }
            composerFocused = true
        }
    }
}

private struct Bubble: View {
    @EnvironmentObject var settings: SettingsStore
    let msg: ChatMessage
    let maxWidth: CGFloat

    var body: some View {
        Text(msg.text)
            .font(.system(size: 13))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(msg.isFromMe ? settings.onAccent : Color.primary)
            .background(RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(msg.isFromMe ? settings.accent : Color.primary.opacity(0.12)))
            .frame(maxWidth: maxWidth, alignment: msg.isFromMe ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: msg.isFromMe ? .trailing : .leading)
            .help(msg.date.formatted(date: .abbreviated, time: .shortened))
    }
}
