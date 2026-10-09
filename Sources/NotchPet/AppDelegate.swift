import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = Config.load()
    private let store = SessionStore(directory: Paths.supportDir)
    private lazy var summarizer = Summarizer(model: config.summaryModel)
    private var statusController: StatusController?
    private var notchController: NotchController?
    private var server: SocketServer?
    private var hotKeys: [HotKey] = []
    private var chatWatcher: DesktopChatWatcher?
    private var pendingSummaries: [String: DispatchWorkItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        if config.menuBarIcon { statusController = StatusController(store: store) }
        let notch = NotchController(store: store, config: config, summarizer: summarizer)
        notchController = notch

        let store = self.store
        let server = SocketServer(path: Paths.socket.path) { path, body, respond in
            Task { @MainActor in
                if path == "/permission" {
                    notch.handlePermission(body, respond: respond) // held open until you decide
                } else {
                    respond(nil)
                    store.ingest(body)
                }
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("NotchPet: could not start socket server: \(error)")
        }

        // Shortcuts from config.json (defaults ⌃⌥Space / ⌃⌥J, which don't collide with common apps
        // the way ⌥⌘J did with Chrome's JavaScript Console). An empty string turns one off.
        if let open = HotKey.parse(config.hotkeyOpen) {
            hotKeys.append(HotKey(keyCode: open.keyCode, modifiers: open.modifiers) { [weak notch] in notch?.toggleSearch() })
        }
        if let jump = HotKey.parse(config.hotkeyJump) {
            hotKeys.append(HotKey(keyCode: jump.keyCode, modifiers: jump.modifiers) { [weak notch] in notch?.jumpToOldestWaiting() })
        }

        store.onSessionSettled = { [weak self] session in self?.scheduleSummary(session.id) }

        // Chats in Claude Desktop / ChatGPT have no hooks; watch their windows instead.
        if config.desktopChats {
            let watcher = DesktopChatWatcher { observations in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { store.updateDesktopChats(observations) }
                }
            }
            watcher.start()
            chatWatcher = watcher
        }

        // Pull in sessions from before NotchPet was running, so they're findable too.
        DispatchQueue.global(qos: .utility).async {
            let found = TranscriptIndexer.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { store.importIndexed(found) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    /// Summarize a session once it has been quiet for a bit (Stop fires after every turn).
    private func scheduleSummary(_ id: String) {
        guard config.summaries else { return }
        pendingSummaries[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let s = self.store.sessions[id], s.kind == .claude,
                  s.state == .done || s.state == .ended,
                  let path = s.transcriptPath else { return }
            // At most one summary per 10 minutes per live session; always one at the end.
            if s.state != .ended, let last = s.summarizedAt, Date().timeIntervalSince(last) < 600 { return }
            let store = self.store
            self.summarizer.summarize(transcriptPath: path) { summary in
                guard let summary else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        store.updateSummary(id, title: summary.title, leftOff: summary.left_off, nextStep: summary.next_step)
                    }
                }
            }
        }
        pendingSummaries[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }
}

enum Paths {
    static let supportDir: URL = {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["NOTCHPET_HOME"] {
            dir = URL(fileURLWithPath: override, isDirectory: true) // for tests
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent("NotchPet", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var socket: URL {
        if let override = ProcessInfo.processInfo.environment["NOTCHPET_SOCKET"] {
            return URL(fileURLWithPath: override)
        }
        return supportDir.appendingPathComponent("notch.sock")
    }
}
