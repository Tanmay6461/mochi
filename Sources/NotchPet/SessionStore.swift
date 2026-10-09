import Foundation

/// What the pet knows about one session.
enum SessionState: String, Codable {
    case idle             // started, nothing asked yet (your move, but not urgent)
    case working          // busy
    case needsPermission  // blocked on a permission prompt
    case needsInput       // asked you something / waiting for a reply
    case done             // finished its turn
    case ended            // session closed

    var wantsAttention: Bool {
        self == .needsPermission || self == .needsInput || self == .done
    }

    var isBlocked: Bool { self == .needsPermission || self == .needsInput }

    var label: String {
        switch self {
        case .idle: "idle"
        case .working: "working"
        case .needsPermission: "needs permission"
        case .needsInput: "waiting for you"
        case .done: "finished"
        case .ended: "ended"
        }
    }
}

enum SessionKind: String, Codable {
    case claude, codex, job
    case chat   // a Claude Desktop / ChatGPT chat, seen through Accessibility
}

struct TerminalRef: Codable, Equatable {
    var program: String?
    var itermSessionID: String?
    var termSessionID: String?
    var tty: String?
    /// The .app the session runs in: a terminal, or a desktop app like Claude, Codex, VS Code, Cursor.
    var hostApp: String?
}

struct Session: Codable, Identifiable {
    let id: String
    var kind: SessionKind = .claude
    var cwd: String
    var transcriptPath: String?
    var state: SessionState
    var stateSince: Date
    var lastViewedAt: Date
    var lastActivity: Date
    var lastMessage: String?
    var lastPrompt: String?
    var terminal: TerminalRef
    /// From the transcript's ai-title, a job's name, or the summarizer.
    var title: String?
    /// Summarizer output: where things stand and the obvious next move.
    var leftOff: String?
    var nextStep: String?
    var summarizedAt: Date?
    /// Desktop chats: the chat's own address when the app exposes it (claude.ai/chat/<id>), a stable ID.
    var chatURL: String?

    var folderName: String { (cwd as NSString).lastPathComponent }

    /// Unread: it wants you and you haven't looked since it changed.
    var needsYou: Bool { state.wantsAttention && stateSince > lastViewedAt }
}

/// A chat link or file dropped on the notch, optionally pinned to a project folder.
struct SavedLink: Codable, Identifiable {
    var id = UUID()
    let url: URL
    var projectPath: String?
    let addedAt: Date

    var label: String {
        if url.isFileURL { return url.lastPathComponent }
        let host = url.host ?? url.absoluteString
        if host.contains("chatgpt.com") || host.contains("chat.openai.com") { return "ChatGPT chat" }
        if host.contains("claude.ai") { return "Claude chat" }
        if host.contains("gemini.google.com") { return "Gemini chat" }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    var symbol: String {
        if url.isFileURL { return "doc" }
        return label.hasSuffix("chat") ? "bubble.left.and.text.bubble.right" : "link"
    }
}

/// The virtual pet's care state: fed by finished work you check on, happier when petted,
/// sadder when agents sit blocked on you.
struct PetStats: Codable {
    var name = "Mochi"
    var skin: Skin = .peach
    var treats = 0
    var happiness: Double = 70

    var level: Int { 1 + treats / 8 }
    var hearts: Int { max(0, min(5, Int((happiness / 20).rounded(.up)))) }
    var isSad: Bool { happiness < 30 }
}

/// A permission prompt Claude is holding open, waiting for an answer from the notch (or the terminal).
struct PendingApproval: Identifiable {
    let id = UUID()
    let sessionID: String
    let cwd: String
    let toolName: String
    let detail: String
    let suggestions: Any?       // permission_suggestions, echoed back for "Always allow"
    let createdAt = Date()
    let respond: (Data?) -> Void

    var projectName: String { (cwd as NSString).lastPathComponent }
}

enum ApprovalDecision {
    case allow, allowAlways, deny
}

/// Raw hook payload as delivered on the hook's stdin, plus `notch_terminal` added by notch-hook.sh.
struct HookEvent: Decodable {
    let hook_event_name: String
    let session_id: String
    let transcript_path: String?
    let cwd: String?
    let notification_type: String?
    let message: String?
    let prompt: String?
    let last_assistant_message: String?
    let source: String?
    let exit_code: Int?
    let duration_seconds: Int?
    let notch_agent: String?      // "codex" when forwarded from Codex's hooks
    let notch_terminal: Terminal?

    struct Terminal: Decodable {
        let program: String?
        let iterm_session_id: String?
        let term_session_id: String?
        let tty: String?
        let host_app: String?
    }
}

@MainActor
final class SessionStore {
    private(set) var sessions: [String: Session] = [:]
    private(set) var links: [SavedLink] = []
    private(set) var approvals: [PendingApproval] = []
    /// Seconds agents spent blocked on you, per day ("2026-10-08": 840).
    private(set) var blockedSecondsByDay: [String: Double] = [:]
    private(set) var pet = PetStats()
    private(set) var lastFedAt = Date.distantPast
    /// Which chat each desktop-app window was last showing, so a rename isn't mistaken for a new chat.
    private var windowChats: [String: (id: String, until: Date)] = [:]

    private var observers: [() -> Void] = []
    /// Called when a session stops or ends, so it can be summarized.
    var onSessionSettled: ((Session) -> Void)?

    private let dir: URL
    private let retention: TimeInterval = 14 * 24 * 3600

    init(directory: URL) {
        dir = directory
        load()
    }

    // MARK: Queries

    var attention: [Session] {
        sessions.values.filter(\.needsYou).sorted { $0.stateSince < $1.stateSince } // longest-waiting first
    }

    var working: [Session] {
        sessions.values.filter { $0.state == .working }.sorted { $0.lastActivity > $1.lastActivity }
    }

    var recent: [Session] {
        sessions.values
            .filter { !$0.needsYou && $0.state != .working }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    var blockedToday: TimeInterval {
        blockedSecondsByDay[Self.dayKey(Date()), default: 0]
            + attention.filter(\.state.isBlocked).reduce(0) { $0 + Date().timeIntervalSince($1.stateSince) }
    }

    func search(_ query: String) -> [Session] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        return sessions.values
            .filter { s in
                let haystack = [s.cwd, s.title, s.lastPrompt, s.lastMessage, s.leftOff, s.nextStep]
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                return terms.allSatisfy { haystack.contains($0) }
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: Hook events

    func ingest(_ data: Data) {
        do {
            apply(try JSONDecoder().decode(HookEvent.self, from: data))
        } catch {
            NSLog("NotchPet: bad hook payload: \(error)")
        }
    }

    func apply(_ event: HookEvent) {
        let now = Date()
        var session = sessions[event.session_id] ?? Session(
            id: event.session_id,
            kind: Self.kind(of: event),
            cwd: event.cwd ?? "?",
            transcriptPath: event.transcript_path,
            state: .idle,
            stateSince: now,
            lastViewedAt: .distantPast,
            lastActivity: now,
            terminal: TerminalRef()
        )

        if let cwd = event.cwd { session.cwd = cwd }
        if let path = event.transcript_path { session.transcriptPath = path }
        if let t = event.notch_terminal, t.tty.nonEmpty != nil || t.program.nonEmpty != nil || t.host_app.nonEmpty != nil {
            session.terminal = TerminalRef(
                program: t.program.nonEmpty,
                itermSessionID: t.iterm_session_id.nonEmpty,
                termSessionID: t.term_session_id.nonEmpty,
                tty: t.tty.nonEmpty,
                hostApp: t.host_app.nonEmpty ?? session.terminal.hostApp
            )
        }
        session.lastActivity = now

        var newState: SessionState?
        var settled = false
        switch event.hook_event_name {
        case "SessionStart":
            newState = .idle
        case "UserPromptSubmit":
            newState = .working
            session.lastViewedAt = now // you're clearly looking at it
            if let prompt = event.prompt { session.lastPrompt = prompt }
        case "PostToolUse":
            // After a permission prompt is answered, the next tool result means it's moving again.
            newState = session.state == .working ? nil : .working
        case "Notification":
            switch event.notification_type {
            case "permission_prompt":
                newState = .needsPermission
            case "idle_prompt":
                // Fires ~60s after a turn ends; "done" already covers that, don't re-mark it unread.
                newState = session.state == .done ? nil : .needsInput
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                newState = .needsInput
            default:
                newState = nil
            }
            if let message = event.message, newState != nil { session.lastMessage = message }
        case "Stop":
            newState = .done
            if let last = event.last_assistant_message { session.lastMessage = last }
            settled = true
        case "SessionEnd":
            newState = .ended
            settled = true

        // Long shell jobs started with bin/notch-run
        case "JobStart":
            session.kind = .job
            session.title = event.message
            session.lastMessage = event.message
            newState = .working
        case "JobEnd":
            let took = Formatting.duration(TimeInterval(event.duration_seconds ?? 0))
            let ok = (event.exit_code ?? 0) == 0
            session.lastMessage = ok ? "✓ finished in \(took)" : "✗ exit \(event.exit_code ?? -1) after \(took)"
            newState = .done
        default:
            newState = nil
        }

        if let newState, newState != session.state {
            if session.state.isBlocked { recordBlocked(from: session.stateSince, to: now) }
            session.state = newState
            session.stateSince = now
        }

        // Answered in the terminal (or moved on): drop any notch prompt still showing for it.
        if session.state != .needsPermission {
            resolveApprovals(for: session.id)
        }

        sessions[session.id] = session
        changed()
        if settled { onSessionSettled?(session) }
    }

    // MARK: Approvals

    func addApproval(_ approval: PendingApproval) {
        approvals.append(approval)
        var session = sessions[approval.sessionID] ?? Session(
            id: approval.sessionID, cwd: approval.cwd, state: .idle, stateSince: Date(),
            lastViewedAt: .distantPast, lastActivity: Date(), terminal: TerminalRef()
        )
        if session.state != .needsPermission {
            session.state = .needsPermission
            session.stateSince = Date()
        }
        session.lastMessage = "\(approval.toolName): \(approval.detail)"
        sessions[session.id] = session
        changed()
    }

    func decide(_ id: UUID, _ decision: ApprovalDecision) {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        let approval = approvals.remove(at: index)

        var body: [String: Any]
        switch decision {
        case .allow:
            body = ["behavior": "allow"]
        case .allowAlways:
            body = ["behavior": "allow"]
            if let suggestions = approval.suggestions { body["updatedPermissions"] = suggestions }
        case .deny:
            body = ["behavior": "deny", "message": "Denied from NotchPet"]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
        approval.respond(try? JSONSerialization.data(withJSONObject: output))

        if var session = sessions[approval.sessionID] {
            recordBlocked(from: session.stateSince, to: Date())
            session.state = decision == .deny ? .done : .working
            session.stateSince = Date()
            session.lastViewedAt = Date()
            sessions[session.id] = session
        }
        changed()
    }

    /// Lets go of a held prompt without deciding, so the terminal prompt takes over.
    func expireApproval(_ id: UUID) {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        approvals.remove(at: index).respond(nil)
        changed()
    }

    private func resolveApprovals(for sessionID: String) {
        let stale = approvals.filter { $0.sessionID == sessionID }
        guard !stale.isEmpty else { return }
        approvals.removeAll { $0.sessionID == sessionID }
        stale.forEach { $0.respond(nil) }
    }

    // MARK: Summaries, indexing, links

    func updateSummary(_ id: String, title: String?, leftOff: String?, nextStep: String?) {
        guard var s = sessions[id] else { return }
        if let title, !title.isEmpty { s.title = title }
        s.leftOff = leftOff
        s.nextStep = nextStep
        s.summarizedAt = Date()
        sessions[id] = s
        changed()
    }

    /// Adds sessions found on disk that the hooks never saw (e.g. from before NotchPet was installed).
    func importIndexed(_ found: [Session]) {
        var added = false
        for var s in found {
            if var existing = sessions[s.id] {
                var updated = false
                if existing.title == nil, let title = s.title { existing.title = title; updated = true }
                // Learned from the transcript that it ran in the desktop app, and the hooks never said otherwise
                if existing.terminal.hostApp == nil, existing.terminal.tty == nil, let host = s.terminal.hostApp {
                    existing.terminal.hostApp = host
                    updated = true
                }
                if updated { sessions[s.id] = existing; added = true }
                continue
            }
            s.lastViewedAt = s.stateSince // old news: don't mark as unread
            sessions[s.id] = s
            added = true
        }
        if added { changed() }
    }

    /// Desktop chats: a chat shows up once it starts writing a reply, and is "finished" when the reply ends.
    func updateDesktopChats(_ observations: [DesktopChatWatcher.Observation]) {
        let now = Date()
        var anyChange = false
        var seen = Set<String>()
        for o in observations {
            let windowKey = "\(o.app.bundleID)#\(o.windowIndex)"
            let appFolder = "/" + o.app.name
            let untitled = o.title == "Current chat"

            // 1. The chat's own address, when the app exposes it (Claude Desktop does): a stable ID.
            var id = o.url.map { "chat:" + $0 }
            // 2. Otherwise the chat with this title.
            if id == nil, !untitled {
                id = sessions.values.first { $0.kind == .chat && $0.cwd == appFolder && $0.chatURL == nil && $0.title == o.title }?.id
            }
            // 3. Otherwise this window's chat may just have been renamed: ChatGPT shows one name while
            //    writing and settles on another after the reply. Keep the same entry, take the new name.
            if id == nil, let recent = windowChats[windowKey], recent.until > now,
               let s = sessions[recent.id], s.chatURL == nil, let old = s.title,
               old == "Current chat" || (!untitled && DesktopChatWatcher.similarity(old, o.title) >= 0.25) {
                id = recent.id
            }
            // 4. Otherwise it's a new chat, but only worth showing once it starts writing.
            if id == nil, o.generating {
                id = o.url.map { "chat:" + $0 } ?? "chat:\(o.app.bundleID):\(UUID().uuidString)"
            }
            guard let chatID = id else { continue }
            seen.insert(chatID)

            var s = sessions[chatID] ?? Session(
                id: chatID, kind: .chat, cwd: appFolder, state: .idle, stateSince: now,
                lastViewedAt: .distantPast, lastActivity: now,
                terminal: TerminalRef(hostApp: o.appPath.isEmpty ? nil : o.appPath), title: o.title
            )
            let before = (title: s.title, state: s.state, isNew: sessions[chatID] == nil)
            if !untitled { s.title = o.title } // follow renames
            if s.chatURL == nil { s.chatURL = o.url }
            if o.generating && s.state != .working {
                s.state = .working
                s.stateSince = now
                s.lastActivity = now
                s.lastMessage = "Writing a reply…"
            } else if !o.generating && s.state == .working {
                s.state = .done
                s.stateSince = now
                s.lastActivity = now
                s.lastMessage = "Reply finished"
            }
            // Keep tying this window to its chat while it writes and for 2 minutes after, to catch the final name.
            if s.state == .working {
                windowChats[windowKey] = (chatID, now.addingTimeInterval(120))
            } else if now.timeIntervalSince(s.stateSince) < 120 {
                windowChats[windowKey] = (chatID, s.stateSince.addingTimeInterval(120))
            }
            if before.isNew || before.title != s.title || before.state != s.state {
                sessions[chatID] = s
                anyChange = true
            }
        }
        // A chat that was writing but whose window closed (or was renamed) has stopped.
        for (id, var s) in sessions where s.kind == .chat && s.state == .working && !seen.contains(id) {
            s.state = .done
            s.stateSince = now
            s.lastActivity = now
            s.lastMessage = "Reply finished"
            sessions[id] = s
            anyChange = true
        }
        if anyChange { changed() }
    }

    func addLink(_ url: URL, projectPath: String?) {
        guard !links.contains(where: { $0.url == url && $0.projectPath == projectPath }) else { return }
        links.insert(SavedLink(url: url, projectPath: projectPath, addedAt: Date()), at: 0)
        changed()
    }

    func removeLink(_ id: UUID) {
        links.removeAll { $0.id == id }
        changed()
    }

    // MARK: Viewing

    func markViewed(_ id: String) {
        guard var s = sessions[id] else { return }
        if s.needsYou && s.state == .done { feed() } // checking on finished work is a treat
        s.lastViewedAt = Date()
        sessions[id] = s
        changed()
    }

    func markAllViewed() {
        if attention.contains(where: { $0.state == .done }) { feed() }
        let now = Date()
        for id in sessions.keys { sessions[id]?.lastViewedAt = now }
        changed()
    }

    // MARK: Pet

    private func feed() {
        pet.treats += 1
        pet.happiness = min(100, pet.happiness + 8)
        lastFedAt = Date()
    }

    func petThePet() {
        pet.happiness = min(100, pet.happiness + 3)
        changed()
    }

    func setSkin(_ skin: Skin) {
        pet.skin = skin
        changed()
    }

    /// Called every few seconds: agents blocked on you for over 5 minutes make the pet sad; otherwise it recovers.
    func tickPetMood(blockedLong: Bool) {
        let before = pet.happiness
        if blockedLong {
            pet.happiness = max(0, pet.happiness - 0.5)
        } else if pet.happiness < 60 {
            pet.happiness = min(60, pet.happiness + 0.15)
        }
        if pet.happiness != before { changed() }
    }

    func observe(_ observer: @escaping () -> Void) {
        observers.append(observer)
    }

    // MARK: Persistence

    private func recordBlocked(from start: Date, to end: Date) {
        let seconds = min(end.timeIntervalSince(start), 4 * 3600) // a forgotten prompt overnight isn't 12h of real waiting
        guard seconds > 0 else { return }
        blockedSecondsByDay[Self.dayKey(end), default: 0] += seconds
    }

    private func changed() {
        prune()
        save()
        observers.forEach { $0() }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-retention)
        sessions = sessions.filter { $0.value.lastActivity > cutoff || $0.value.state == .working }
    }

    private struct Snapshot: Codable {
        var sessions: [Session]
        var links: [SavedLink]
        var blockedSecondsByDay: [String: Double]
        var pet: PetStats?
    }

    private var fileURL: URL { dir.appendingPathComponent("state-v2.json") }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let snap = try JSONDecoder().decode(Snapshot.self, from: data)
            sessions = Dictionary(snap.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            links = snap.links
            blockedSecondsByDay = snap.blockedSecondsByDay
            if let saved = snap.pet { pet = saved }
        } catch {
            NSLog("NotchPet: could not read saved state: \(error)")
        }
    }

    private func save() {
        let snap = Snapshot(sessions: Array(sessions.values), links: links, blockedSecondsByDay: blockedSecondsByDay, pet: pet)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func kind(of event: HookEvent) -> SessionKind {
        if event.hook_event_name.hasPrefix("Job") { return .job }
        if event.notch_agent == "codex" { return .codex }
        return .claude
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
