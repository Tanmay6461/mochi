import AppKit

/// Something a project row can bring to the front: an app window or a browser tab.
enum ProjectTarget: Identifiable {
    case window(WindowRef)
    case tab(BrowserTab)

    var id: String {
        switch self {
        case .window(let w): "w-\(w.id)"
        case .tab(let t): "t-\(t.id)"
        }
    }

    var appName: String {
        switch self {
        case .window(let w): w.appName
        case .tab(let t): t.appName
        }
    }

    var title: String {
        switch self {
        case .window(let w): w.title
        case .tab(let t): t.title
        }
    }

    var icon: NSImage? {
        switch self {
        case .window(let w):
            return NSRunningApplication(processIdentifier: w.pid)?.icon
        case .tab(let t):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: t.bundleID) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    func bringForward() {
        switch self {
        case .window(let w): WindowIndex.raise(w)
        case .tab(let t): BrowserTabs.focus(t)
        }
    }
}

/// Everything that belongs to one folder: its agent sessions, the app windows and browser
/// tabs showing it, and links you've pinned to it. The panel shows just two of these: "ChatGPT"
/// (ChatGPT chats and Codex, which share an app) and "Claude" (Claude Desktop chats and Claude Code).
struct Project: Identifiable {
    let path: String          // "/ChatGPT" or "/Claude"
    let sessions: [Session]   // most urgent first
    let windows: [WindowRef]
    let tabs: [BrowserTab]
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

    /// One icon per app window, then matching browser tabs.
    var targets: [ProjectTarget] {
        var seen = Set<pid_t>()
        let windowTargets = windows.compactMap { w in seen.insert(w.pid).inserted ? ProjectTarget.window(w) : nil }
        return Array((windowTargets + tabs.prefix(2).map(ProjectTarget.tab)).prefix(5))
    }

    static func build(from sessions: [Session], windows: [WindowRef], tabs: [BrowserTab],
                      links: [SavedLink], limit: Int) -> [Project] {
        let grouped = Dictionary(grouping: sessions, by: groupKey(for:))
        let projects = grouped.map { path, group in
            Project(
                path: path,
                sessions: group.sorted { (urgency($0), $1.lastActivity) < (urgency($1), $0.lastActivity) },
                // Each row opens its own session or chat, so no window grouping at the card level.
                windows: [],
                tabs: [],
                links: links.filter { $0.projectPath == path }
            )
        }
        // Always the same order, so the panel looks the same every time: ChatGPT, then Claude.
        return Array(projects.sorted { $0.path == "/ChatGPT" && $1.path != "/ChatGPT" }.prefix(limit))
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
