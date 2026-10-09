import AppKit

/// Takes you back to a session: focus its live tab if we can find it, otherwise
/// open a new terminal in the right folder and resume it (`claude --resume`, `codex resume`, or just `cd` for jobs).
@MainActor
enum TerminalJumper {
    private static let terminalApps: Set<String> = [
        "Terminal.app", "iTerm.app", "iTerm2.app", "Ghostty.app", "Warp.app", "kitty.app", "WezTerm.app", "Alacritty.app",
    ]

    static func jump(to session: Session) {
        // Started in a desktop app (Claude, Codex, VS Code, Cursor...)? Go back to that app, not a terminal.
        if let host = session.terminal.hostApp, !terminalApps.contains((host as NSString).lastPathComponent) {
            openHostApp(host, session: session)
            return
        }
        if session.state != .ended {
            if let iterm = session.terminal.itermSessionID,
               let uuid = iterm.split(separator: ":").last,
               run(focusITerm(uuid: String(uuid))) == "ok" {
                return
            }
            if let tty = session.terminal.tty,
               session.terminal.program == "Apple_Terminal",
               run(focusTerminal(tty: tty)) == "ok" {
                return
            }
        }
        resumeInNewTab(session)
    }

    /// Brings the host app forward, preferring its window that shows this project or session.
    /// If it isn't running any more, launches it.
    private static func openHostApp(_ path: String, session: Session) {
        let url = URL(fileURLWithPath: path).standardizedFileURL

        // A desktop chat: open the app the way the Dock does (launches it, or reopens its window if
        // it was closed), then wait for its chat list and open that exact conversation.
        if session.kind == .chat {
            let title = session.title ?? "Current chat"
            let chatURL = session.chatURL
            // Fastest: Claude's own link goes straight to the chat, launching Claude if needed.
            if let link = DesktopChatWatcher.deepLink(for: chatURL, app: url) {
                NSWorkspace.shared.open(link)
                DesktopChatWatcher.logOpen(["lookingFor": title, "chatID": chatURL ?? "", "result": "fast path: opened \(link.absoluteString)"])
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
                guard let app else { return }
                let pid = app.processIdentifier
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
                    DesktopChatWatcher.openChat(pid: pid, bundleURL: url, title: title, chatURL: chatURL, waitUpTo: 12)
                }
            }
            return
        }

        guard let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL == url }) else {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let windows = WindowIndex.snapshot(of: [(pid: running.processIdentifier, name: running.localizedName ?? "")])
        let match = windows.first { w in
            WindowIndex.title(w.title, mentions: session.folderName)
                || (session.title.map { w.title.localizedCaseInsensitiveContains($0) } ?? false)
        }
        if let window = match ?? windows.first {
            WindowIndex.raise(window)
        } else {
            WindowIndex.activate(pid: running.processIdentifier)
        }
    }

    private static func resumeInNewTab(_ session: Session) {
        let cd = "cd \(shellQuote(session.cwd))"
        let command: String
        switch session.kind {
        case .claude: command = "\(cd) && claude --resume \(shellQuote(session.id))"
        case .codex: command = "\(cd) && codex resume \(shellQuote(session.id))"
        case .job, .chat: command = cd
        }

        if session.terminal.program == "ghostty" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-na", "Ghostty", "--args", "-e", "/bin/zsh", "-lic", command + "; exec zsh -l"]
            try? p.run()
        } else if session.terminal.program == "iTerm.app" {
            run("""
            tell application "iTerm2"
                activate
                create window with default profile command "/bin/zsh -lic \(appleQuote(command + "; exec zsh -l"))"
            end tell
            """)
        } else {
            run("""
            tell application "Terminal"
                activate
                do script \(appleQuote(command))
            end tell
            """)
        }
    }

    private static func focusITerm(uuid: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique id of s is \(appleQuote(uuid)) then
                            select w
                            select t
                            select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    private static func focusTerminal(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is \(appleQuote(tty)) then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    @discardableResult
    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("NotchPet: AppleScript failed: \(error)") }
        return result?.stringValue
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
