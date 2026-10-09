import AppKit
import ApplicationServices

/// Watches chat apps that have no hooks (Claude Desktop's Chat, the ChatGPT app) through
/// Accessibility. While a reply is being written these apps show a Stop button, so:
/// Stop button visible = working, gone again = finished. Needs Accessibility permission.
final class DesktopChatWatcher: @unchecked Sendable {
    struct ChatApp: Sendable {
        let bundleID: String
        let name: String
        let processName: String   // what the app is called in the Dock, for matching when the bundle ID differs
    }

    struct Observation: Sendable {
        let app: ChatApp
        let appPath: String
        let windowIndex: Int
        let title: String
        let url: String?          // the chat's own address when the app exposes it (Claude: claude.ai/chat/<id>)
        let generating: Bool
    }

    static let apps = [
        ChatApp(bundleID: "com.anthropic.claudefordesktop", name: "Claude Desktop", processName: "Claude"),
        // The ChatGPT app has shipped under its own ID and, more recently, Codex's.
        ChatApp(bundleID: "com.openai.chat", name: "ChatGPT", processName: "ChatGPT"),
    ]

    private let queue = DispatchQueue(label: "notchpet.desktopchats", qos: .utility)
    private var primed = Set<pid_t>()
    private let onUpdate: @Sendable ([Observation]) -> Void

    init(onUpdate: @escaping @Sendable ([Observation]) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        schedule(after: 2)
    }

    /// Check every second while a chat app is in front (short replies finish fast), every 3 otherwise.
    private func schedule(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.poll()
            let chatInFront = NSWorkspace.shared.frontmostApplication.map { Self.chatApp(for: $0) != nil } ?? false
            self.schedule(after: chatInFront ? 1 : 3)
        }
    }

    static func chatApp(for running: NSRunningApplication) -> ChatApp? {
        apps.first { $0.bundleID == running.bundleIdentifier }
            ?? apps.first { running.activationPolicy == .regular && running.localizedName == $0.processName }
    }

    private func poll() {
        var diagnostics: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date())]
        guard AXIsProcessTrusted() else {
            diagnostics["trusted"] = false
            Self.writeDiagnostics(diagnostics)
            return
        }
        diagnostics["trusted"] = true
        var observations: [Observation] = []
        var seenApps: [[String: Any]] = []

        for running in NSWorkspace.shared.runningApplications {
            guard let app = Self.chatApp(for: running) else { continue }
            let pid = running.processIdentifier
            let axApp = Self.prepare(pid: pid, firstTime: primed.insert(pid).inserted)

            var appInfo: [String: Any] = ["app": app.name, "pid": pid, "bundleID": running.bundleIdentifier ?? "",
                                          "onScreenWindows": Self.onScreenWindowCount(pid: pid)]
            var windowInfos: [[String: Any]] = []
            for (index, window) in Self.windows(of: axApp).enumerated() {
                let windowTitle: String = Self.copy(window, kAXTitleAttribute) ?? ""
                let scan = Self.scan(window)
                let title = Self.clean(scan.documentTitle ?? windowTitle)
                let chatURL = scan.documentURL.flatMap(Self.chatAddress)
                observations.append(Observation(app: app, appPath: running.bundleURL?.path ?? "", windowIndex: index,
                                                title: title, url: chatURL, generating: scan.stopButton))
                windowInfos.append(["windowTitle": windowTitle, "chatTitle": title, "generating": scan.stopButton,
                                    "nodesScanned": scan.visited, "buttons": scan.buttons, "roles": scan.roles,
                                    "pageURL": scan.documentURL ?? "(none exposed)", "chatID": chatURL ?? "(none)"])
            }
            appInfo["windows"] = windowInfos
            seenApps.append(appInfo)
        }
        diagnostics["apps"] = seenApps
        Self.writeDiagnostics(diagnostics)
        onUpdate(observations)
    }

    /// Electron/Chromium apps (Claude Desktop) only build their web content's accessibility tree when
    /// asked. Ask every time: a request made while the app starts up or comes forward can be ignored.
    private static func prepare(pid: pid_t, firstTime: Bool) -> AXUIElement {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if firstTime {
            // Earlier builds turned AXEnhancedUserInterface on, which can disturb window animations and
            // positioning in the app. It isn't needed (AXManualAccessibility is enough), so turn it back off.
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        return axApp
    }

    /// The app's windows; falls back to the focused/main window when the list comes back empty
    /// (some apps do that for windows on another Space or in full screen).
    private static func windows(of axApp: AXUIElement) -> [AXUIElement] {
        let list: [AXUIElement] = copy(axApp, kAXWindowsAttribute) ?? []
        if !list.isEmpty { return list }
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = element(axApp, attribute) { return [window] }
        }
        return []
    }

    /// Keeps only addresses that identify one chat: claude.ai/chat/<id>, chatgpt.com/c/<id>.
    private static func chatAddress(_ url: String) -> String? {
        guard let components = URLComponents(string: url), let host = components.host else { return nil }
        let path = components.path
        let isChat = (host.hasSuffix("claude.ai") && path.hasPrefix("/chat/"))
            || ((host.hasSuffix("chatgpt.com") || host.hasSuffix("openai.com")) && path.hasPrefix("/c/"))
        return isChat ? "https://\(host)\(path)" : nil
    }

    // MARK: Opening a specific chat

    /// Claude Desktop opens `claude://claude.ai/chat/<id>` straight to that chat (launching if needed).
    /// Returns the link only when Claude itself is registered to handle it, so macOS never shows a
    /// "no app can open this" error.
    /// Records how a chat was opened in open-chat.json (for diagnosing without a debugger).
    static func logOpen(_ info: [String: Any]) {
        var log = info
        log["time"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.supportDir.appendingPathComponent("open-chat.json"), options: .atomic)
        }
    }

    static func deepLink(for chatURL: String?, app bundleURL: URL) -> URL? {
        guard let chatURL, let url = URL(string: chatURL), url.host?.hasSuffix("claude.ai") == true,
              let link = URL(string: "claude://claude.ai\(url.path)"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: link),
              handler.standardizedFileURL == bundleURL.standardizedFileURL else { return nil }
        return link
    }

    /// Opens one chat in its app: by its address if we know it (exact), otherwise by clicking the
    /// sidebar entry with that title or a clearly similar one. Call off the main thread, after
    /// bringing the app forward. Writes what it did to open-chat.json.
    static func openChat(pid: pid_t, bundleURL: URL?, title: String, chatURL: String?, waitUpTo: TimeInterval = 2) {
        var log: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "lookingFor": title,
                                  "chatID": chatURL ?? "(none)"]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: Paths.supportDir.appendingPathComponent("open-chat.json"), options: .atomic)
            }
        }
        guard AXIsProcessTrusted() else { log["result"] = "skipped (no Accessibility permission)"; return }
        if chatURL == nil && title == "Current chat" { log["result"] = "skipped (untitled chat, no ID)"; return }

        // The app may be launching, reopening its window, or still waking up its page content:
        // keep looking until the chat list is readable, up to `waitUpTo` seconds.
        let started = Date()
        let deadline = started.addingTimeInterval(waitUpTo)
        var search = SearchResult()
        var attempts = 0
        repeat {
            attempts += 1
            let axApp = prepare(pid: pid, firstTime: attempts == 1)
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            search = SearchResult()
            for window in windows(of: axApp) {
                searchSidebar(window, title: title, chatURL: chatURL, into: &search)
                if search.alreadyShowing { break }
            }
            if search.alreadyShowing || search.best != nil { break }
            // Page loaded and still no match after a few seconds (the chat list fills in after the page,
            // especially right after launch): no point waiting the full time.
            if search.visited > 200 && Date().timeIntervalSince(started) > min(waitUpTo, 5) { break }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        log["scanned"] = search.visited
        log["attempts"] = attempts
        log["similarLabels"] = search.similar

        if search.alreadyShowing { log["result"] = "already showing"; return }
        if let target = search.best {
            log["matched"] = search.matchedLabel
            log["result"] = press(target)
            return
        }
        // Claude: no link on screen (sidebar collapsed or chat scrolled away). Use Claude's own link.
        if let bundleURL, let link = deepLink(for: chatURL, app: bundleURL) {
            NSWorkspace.shared.open(link)
            log["result"] = "opened via \(link.absoluteString)"
            return
        }
        log["result"] = "no matching chat found on screen"
    }

    private struct SearchResult {
        var visited = 0
        var alreadyShowing = false
        var best: AXUIElement?
        var bestScore = 0
        var matchedLabel: String?
        var similar: [String] = []
    }

    private static func searchSidebar(_ window: AXUIElement, title: String, chatURL: String?, into result: inout SearchResult) {
        let target = title.lowercased()
        let words = Set(target.split(separator: " ").map(String.init).filter { $0.count > 2 })
        let chatID = chatURL.flatMap { URL(string: $0)?.lastPathComponent }
        let attributes = [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXChildrenAttribute] as CFArray
        var stack: [AXUIElement] = [window]
        while let el = stack.popLast(), result.visited < 8000 {
            result.visited += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let v = values as? [Any], v.count == 4 else { continue }
            let role = v[0] as? String
            let labels = [v[1], v[2]].compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }

            // The page itself: is this chat already on screen?
            if role == "AXWebArea" {
                let page: URL? = copy(el, kAXURLAttribute)
                if let chatURL, let page, chatAddress(page.absoluteString) == chatURL {
                    result.alreadyShowing = true
                    return
                }
                if chatURL == nil, let pageTitle = v[2] as? String, clean(pageTitle).lowercased() == target {
                    result.alreadyShowing = true
                    return
                }
            }

            // Exact: a link to this chat's address (Claude's sidebar entries are real links).
            if role == "AXLink", let chatID, let href: URL = copy(el, kAXURLAttribute), href.absoluteString.contains(chatID) {
                result.best = el
                result.bestScore = 100
                result.matchedLabel = "link to \(chatID)"
                return
            }

            // By title: exact wins; otherwise a clearly similar one (ChatGPT renames chats after the first reply).
            let clickable = [kAXButtonRole as String, kAXRowRole as String, "AXLink", "AXCell"].contains(role ?? "")
            if let label = labels.first, label != target, result.similar.count < 15,
               !words.isDisjoint(with: label.split(separator: " ").map(String.init)) {
                result.similar.append("\(role ?? "?"): \(label)")
            }
            var score = 0
            if labels.contains(target) {
                score = 10
            } else if clickable, let label = labels.first {
                let likeness = similarity(target, label)
                if likeness >= 0.6 { score = Int(likeness * 5) }
            }
            if score > 0 {
                if clickable { score += 1 }
                if labels.count == 2 && labels[0] == labels[1] { score += 2 } // sidebar entries label themselves twice
                if score > result.bestScore {
                    result.best = el
                    result.bestScore = score
                    result.matchedLabel = labels.first
                }
            }
            if let children = v[3] as? [AXUIElement] { stack.append(contentsOf: children.reversed()) } // top to bottom
        }
    }

    /// Presses the element, or the nearest ancestor that accepts a press.
    private static func press(_ start: AXUIElement) -> String {
        var candidate = start
        for level in 0..<4 {
            let pressed = AXUIElementPerformAction(candidate, kAXPressAction as CFString)
            if pressed == .success { return "clicked (\(level) levels up)" }
            guard let parent = element(candidate, kAXParentAttribute) else { return "found but not clickable (\(pressed.rawValue))" }
            candidate = parent
        }
        return "found but not clickable"
    }

    /// 0...1: how alike two chat titles are, ignoring small words, punctuation, and word endings.
    /// "Write poem" vs "write a poem" = 1; "Explain TCP Works" vs "TCP explained" = 0.67.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = keywords(a), y = keywords(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    private static let smallWords: Set<String> = ["a", "an", "the", "of", "to", "for", "in", "on", "and", "with", "my", "me", "is", "how", "what"]

    private static func keywords(_ s: String) -> Set<String> {
        let words = s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return Set(words.filter { !smallWords.contains($0) }.map { word in
            for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
                return String(word.dropLast(suffix.count))
            }
            return word
        })
    }

    // MARK: Scanning for the Stop button

    /// Walks a window's accessibility tree looking for a Stop button, picking up the page title and
    /// address on the way. Goes last-child-first: the message box (where Stop lives) sits at the bottom
    /// of the window, after thousands of conversation and sidebar elements. Capped so a huge chat can't stall us.
    private static func scan(_ root: AXUIElement) -> (stopButton: Bool, documentTitle: String?, visited: Int, buttons: [String], roles: [String: Int], documentURL: String?) {
        let attributes = [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXChildrenAttribute] as CFArray
        var stack: [AXUIElement] = [root]
        var next = 0
        var documentTitle: String?
        var documentURL: String?
        var buttons: [String] = []
        var roles: [String: Int] = [:]
        while let element = stack.popLast(), next < 6000 {
            next += 1
            var values: CFArray?
            let v: [Any]
            if AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
               let all = values as? [Any], all.count == 5 {
                v = all
            } else {
                // The batch read can fail for some elements; read what we need one by one so we don't lose the subtree.
                v = [copy(element, kAXRoleAttribute) as String? as Any, copy(element, kAXDescriptionAttribute) as String? as Any,
                     copy(element, kAXTitleAttribute) as String? as Any, copy(element, kAXHelpAttribute) as String? as Any,
                     copy(element, kAXChildrenAttribute) as [AXUIElement]? as Any]
            }
            let role = v[0] as? String
            roles[role ?? "?", default: 0] += 1
            if role == "AXWebArea" {
                if documentTitle == nil, let title = v[2] as? String, !title.isEmpty { documentTitle = title }
                if documentURL == nil, let url: URL = copy(element, kAXURLAttribute) { documentURL = url.absoluteString }
            }
            if role == kAXButtonRole as String {
                let label = [v[1], v[2], v[3]].compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: " / ")
                if !label.isEmpty && buttons.count < 25 { buttons.append(label) } // the first ones found are the message box's
                let lower = label.lowercased()
                if lower.contains("stop") && !lower.contains("sharing") && !lower.contains("recording") {
                    return (true, documentTitle, next, buttons, roles, documentURL)
                }
            }
            var children = v[4] as? [AXUIElement]
            if children == nil || children!.isEmpty {
                children = copy(element, kAXChildrenAttribute) // the batch value can come back empty for web content
            }
            // Pushed in order, so the last child is popped (visited) first.
            if let children { stack.append(contentsOf: children) }
        }
        return (false, documentTitle, next, buttons, roles, documentURL)
    }

    // MARK: Helpers

    /// "Fix my resume - Claude" → "Fix my resume"; a bare app name means no chat title yet.
    private static func clean(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespaces)
        for suffix in [" - Claude", " | Claude", " – Claude", " - ChatGPT", " | ChatGPT", " – ChatGPT"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        if t.isEmpty || t == "Claude" || t == "ChatGPT" || t == "New chat" { return "Current chat" }
        return t
    }

    /// What the watcher saw on its last check, so detection problems can be diagnosed:
    /// ~/Library/Application Support/NotchPet/chat-watcher.json (labels and titles only, no chat contents).
    private static func writeDiagnostics(_ info: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: Paths.supportDir.appendingPathComponent("chat-watcher.json"), options: .atomic)
    }

    /// How many normal windows this app has on screen (window list metadata only, no pixels).
    private static func onScreenWindowCount(pid: pid_t) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return -1 }
        return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }.count
    }

    private static func element(_ from: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(from, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
