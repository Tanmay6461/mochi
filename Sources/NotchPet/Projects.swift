import AppKit

/// One card in the panel: "ChatGPT" (ChatGPT chats and Codex, which share an app) or "Claude"
/// (Claude Desktop chats and Claude Code sessions), with the links you've pinned to it.
struct Project: Identifiable {
    let path: String          // "/ChatGPT" or "/Claude"
    let sessions: [Session]   // most urgent first
    let links: [SavedLink]

    var id: String { path }
    var lead: Session { sessions[0] }
    var isChat: Bool { lead.kind == .chat }
    var name: String { (path as NSString).lastPathComponent }

    static func groupKey(for session: Session) -> String {
        switch session.kind {
        case .codex: return "/ChatGPT"
        case .chat: return session.cwd == "/ChatGPT" ? "/ChatGPT" : "/Claude"
        case .claude, .job: return "/Claude"
        }
    }

    static func build(from sessions: [Session], links: [SavedLink]) -> [Project] {
        let grouped = Dictionary(grouping: sessions, by: groupKey(for:))
        let projects = grouped.map { path, group in
            Project(
                path: path,
                sessions: group.sorted { (urgency($0), $1.lastActivity) < (urgency($1), $0.lastActivity) },
                links: links.filter { $0.projectPath == path }
            )
        }
        // Always the same order, so the panel looks the same every time: ChatGPT, then Claude.
        return projects.sorted { $0.path == "/ChatGPT" && $1.path != "/ChatGPT" }
    }

    /// Lower is more urgent: blocked on you, then finished-unseen, then working, then the rest.
    static func urgency(_ s: Session) -> Int {
        if s.needsYou { return s.state == .done ? 1 : 0 }
        if s.state == .working { return 2 }
        return s.state == .ended ? 4 : 3
    }
}

/// Keeps regular apps in most-recently-used order for the app strip.
@MainActor
final class AppTracker {
    private(set) var recentPIDs: [pid_t] = []
    var onChange: (() -> Void)?

    init() {
        recentPIDs = NSWorkspace.shared.runningApplications
            .filter { Self.isSwitchable($0) }
            .sorted { $0.isActive && !$1.isActive }
            .map(\.processIdentifier)

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                guard let self, Self.isSwitchable(app) else { return }
                self.recentPIDs.removeAll { $0 == pid }
                self.recentPIDs.insert(pid, at: 0)
                self.onChange?()
            }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                self?.recentPIDs.removeAll { $0 == pid }
                self?.onChange?()
            }
        }
    }

    var apps: [NSRunningApplication] {
        recentPIDs.compactMap { NSRunningApplication(processIdentifier: $0) }.filter { !$0.isTerminated }
    }

    nonisolated static func isSwitchable(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }
}
