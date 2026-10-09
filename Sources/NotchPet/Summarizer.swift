import AppKit

/// Runs one-shot `claude -p` calls with your existing Claude login: per-session
/// "where you left off" summaries, and free-form questions about your agents.
/// NOTCHPET_INTERNAL=1 makes our own hook scripts ignore these runs.
final class Summarizer: @unchecked Sendable {
    struct Summary: Decodable {
        let title: String?
        let left_off: String?
        let next_step: String?
    }

    private let model: String
    private let queue = DispatchQueue(label: "notchpet.summarizer", qos: .utility)
    private lazy var claudePath: String? = Self.findClaude()

    init(model: String) {
        self.model = model
    }

    func summarize(transcriptPath: String, completion: @escaping @Sendable (Summary?) -> Void) {
        queue.async { [self] in
            guard let excerpt = TranscriptReader.excerpt(path: transcriptPath, maxChars: 14_000), !excerpt.isEmpty else {
                return completion(nil)
            }
            let prompt = """
            Below is the tail of a coding-agent session transcript. Reply with ONLY a JSON object, no prose:
            {"title": "<what this session is about, max 6 words>",
             "left_off": "<one sentence: where the work stands right now>",
             "next_step": "<one short imperative: the obvious next thing the user should do>"}

            TRANSCRIPT:
            \(excerpt)
            """
            guard let text = run(prompt: prompt, timeout: 90),
                  let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
                  let data = String(text[start...end]).data(using: .utf8) else {
                return completion(nil)
            }
            completion(try? JSONDecoder().decode(Summary.self, from: data))
        }
    }

    func ask(_ question: String, context: String, completion: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            let prompt = """
            You are NotchPet, a small assistant that watches the user's AI coding agents. Answer the question
            in at most 3 short sentences using only the session list below. Mention project names.

            SESSIONS (most recent first):
            \(context)

            QUESTION: \(question)
            """
            completion(run(prompt: prompt, timeout: 60) ?? "Couldn't reach Claude. Is `claude` installed and logged in?")
        }
    }

    // MARK: Process

    private func run(prompt: String, timeout: TimeInterval) -> String? {
        guard let claude = claudePath else {
            NSLog("NotchPet: claude CLI not found; summaries disabled")
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = [
            "-p", prompt,
            "--model", model,
            "--no-session-persistence",
            "--tools", "",
            "--max-turns", "1",
            "--output-format", "json",
        ]
        var env = ProcessInfo.processInfo.environment
        env["NOTCHPET_INTERNAL"] = "1"
        env["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] = "1"
        process.environment = env
        // Run outside any project so no project CLAUDE.md or hooks get pulled in.
        process.currentDirectoryURL = Paths.supportDir

        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch {
            NSLog("NotchPet: could not launch claude: \(error)")
            return nil
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? String else { return nil }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Apps launched from Finder don't get your shell PATH, so look in the usual places, then ask a login shell.
    private static func findClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        try? shell.run()
        shell.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

/// Reads Claude Code transcript JSONL files. The format is internal to Claude Code and changes
/// between versions, so everything here is best-effort and skips lines it doesn't understand.
enum TranscriptReader {
    struct Info {
        var sessionID: String
        var cwd: String?
        var title: String?
        var lastPrompt: String?
        var lastAssistant: String?
        var entrypoint: String?   // "cli" for the terminal; something else for the desktop app
    }

    /// Last user/assistant text turns, oldest first, trimmed to fit `maxChars`.
    static func excerpt(path: String, maxChars: Int) -> String? {
        guard let lines = tailLines(path: path, bytes: 1_500_000) else { return nil }
        var turns: [String] = []
        var total = 0
        for line in lines.reversed() {
            guard let obj = parse(line), let type = obj["type"] as? String,
                  type == "user" || type == "assistant",
                  let text = text(of: obj), !text.isEmpty else { continue }
            let clipped = text.count > 700 ? String(text.prefix(700)) + "…" : text
            let entry = "\(type == "user" ? "USER" : "AGENT"): \(clipped)"
            if total + entry.count > maxChars { break }
            turns.append(entry)
            total += entry.count
        }
        return turns.reversed().joined(separator: "\n\n")
    }

    static func info(path: String) -> Info? {
        let sessionID = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var info = Info(sessionID: sessionID)
        if let head = headLines(path: path, bytes: 64_000) {
            for line in head {
                if let obj = parse(line), let cwd = obj["cwd"] as? String { info.cwd = cwd; break }
            }
        }
        guard let tail = tailLines(path: path, bytes: 400_000) else { return info }
        for line in tail.reversed() {
            guard let obj = parse(line), let type = obj["type"] as? String else { continue }
            switch type {
            case "custom-title" where info.title == nil:
                info.title = (obj["customTitle"] as? String) ?? (obj["title"] as? String)
            case "ai-title" where info.title == nil:
                info.title = obj["aiTitle"] as? String
            case "summary" where info.title == nil:
                info.title = obj["summary"] as? String
            case "last-prompt" where info.lastPrompt == nil:
                info.lastPrompt = obj["lastPrompt"] as? String
            case "assistant" where info.lastAssistant == nil:
                info.lastAssistant = text(of: obj)
            default:
                break
            }
            if info.cwd == nil, let cwd = obj["cwd"] as? String { info.cwd = cwd }
            if info.entrypoint == nil, let entry = obj["entrypoint"] as? String { info.entrypoint = entry }
        }
        return info
    }

    /// Sessions not started from the terminal (or the SDK) came from the Claude desktop app.
    static func desktopApp(for entrypoint: String?) -> String? {
        guard let entry = entrypoint, entry != "cli", !entry.hasPrefix("sdk") else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")?.path
    }

    private static func text(of obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String {
            return s.hasPrefix("<") ? nil : s // skip injected system/command wrappers
        }
        guard let parts = message["content"] as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        let joined = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func parse(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func tailLines(path: String, bytes: Int) -> [Substring]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() } // probably cut mid-line
        return lines
    }

    private static func headLines(path: String, bytes: Int) -> [Substring]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: bytes)) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
    }
}

/// Finds Claude Code sessions on disk so older work shows up (and is searchable) too.
enum TranscriptIndexer {
    static func scan(maxAgeDays: Double = 14) -> [Session] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-maxAgeDays * 86400)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }

        var found: [Session] = []
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified > cutoff,
                      let info = TranscriptReader.info(path: file.path),
                      let cwd = info.cwd else { continue }
                found.append(Session(
                    id: info.sessionID, kind: .claude, cwd: cwd, transcriptPath: file.path,
                    state: .ended, stateSince: modified, lastViewedAt: modified, lastActivity: modified,
                    lastMessage: info.lastAssistant, lastPrompt: info.lastPrompt,
                    terminal: TerminalRef(hostApp: TranscriptReader.desktopApp(for: info.entrypoint)), title: info.title
                ))
            }
        }
        return found
    }
}
