import AppKit

/// A browser tab, found via AppleScript (each browser asks for Automation permission once).
struct BrowserTab: Identifiable {
    let id = UUID()
    let bundleID: String
    let appName: String
    let window: Int
    let tab: Int
    let title: String
    let url: String
}

enum BrowserTabs {
    private static let chromeLike = ["com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac"]
    private static let safari = "com.apple.Safari"

    /// Lists tabs of supported browsers that are already running (never launches one). Call off the main thread.
    static func snapshot(running bundleIDs: Set<String>) -> [BrowserTab] {
        var tabs: [BrowserTab] = []
        for id in chromeLike + [safari] where bundleIDs.contains(id) {
            let titleKey = id == safari ? "name" : "title"
            let script = """
            tell application id "\(id)"
                set out to ""
                set wi to 0
                repeat with w in windows
                    set wi to wi + 1
                    set ti to 0
                    repeat with t in tabs of w
                        set ti to ti + 1
                        set out to out & wi & tab & ti & tab & (\(titleKey) of t) & tab & (URL of t) & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
            guard let output = osascript(script, timeout: 2) else { continue }
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "Browser"
            for line in output.split(separator: "\n") {
                let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard f.count == 4, let w = Int(f[0]), let t = Int(f[1]) else { continue }
                tabs.append(BrowserTab(bundleID: id, appName: name, window: w, tab: t, title: String(f[2]), url: String(f[3])))
            }
        }
        return tabs
    }

    static func focus(_ tab: BrowserTab) {
        let body = tab.bundleID == safari
            ? "tell window \(tab.window) to set current tab to tab \(tab.tab)"
            : "set active tab index of window \(tab.window) to \(tab.tab)"
        let script = """
        tell application id "\(tab.bundleID)"
            \(body)
            set index of window \(tab.window) to 1
            activate
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async { _ = osascript(script, timeout: 3) }
    }

    /// Does this tab belong to the project? Title or URL mentions the folder name.
    static func tab(_ tab: BrowserTab, belongsTo project: String) -> Bool {
        WindowIndex.title(tab.title, mentions: project) || WindowIndex.title(tab.url, mentions: project)
    }

    /// osascript runs as a child process, so it's safe off the main thread (NSAppleScript isn't).
    private static func osascript(_ script: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
