import Foundation

/// User settings, read from ~/Library/Application Support/NotchPet/config.json at launch.
/// Every key is optional; missing keys fall back to the defaults here.
struct Config: Codable {
    /// ntfy.sh topic for phone pushes when an agent has waited too long. Off when nil.
    var ntfyTopic: String? = nil
    var ntfyServer: String = "https://ntfy.sh"
    /// Minutes a session can wait on you before the creature gets louder, then before a phone push.
    var escalateAfterMinutes: Double = 5
    var pushAfterMinutes: Double = 15
    /// Generate "where you left off" summaries with `claude -p` when a session stops.
    var summaries: Bool = true
    var summaryModel: String = "haiku"
    /// Answer Claude's permission prompts from the notch. How long the hook waits for you before
    /// falling back to the normal terminal prompt.
    var approvalsFromNotch: Bool = true
    var approvalWaitSeconds: Double = 120
    /// Keep the old menu bar icon as well as the notch.
    var menuBarIcon: Bool = false
    /// Watch Claude Desktop and ChatGPT chat windows (via Accessibility) for replies being written.
    var desktopChats: Bool = true
    /// Move the pet to whichever display the cursor is on. Off: it stays on the notch display.
    var followCursorAcrossDisplays: Bool = false
    /// Global shortcuts, like "ctrl+option+space". Empty string turns one off.
    var hotkeyOpen: String = "ctrl+option+space"
    var hotkeyJump: String = "ctrl+option+j"

    static func load() -> Config {
        let url = Paths.supportDir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url) else {
            // Write the defaults once so there's a file to edit.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(Config()).write(to: url)
            return Config()
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            NSLog("NotchPet: config.json is invalid, using defaults: \(error)")
            return Config()
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        ntfyTopic = try c.decodeIfPresent(String.self, forKey: .ntfyTopic) ?? d.ntfyTopic
        ntfyServer = try c.decodeIfPresent(String.self, forKey: .ntfyServer) ?? d.ntfyServer
        escalateAfterMinutes = try c.decodeIfPresent(Double.self, forKey: .escalateAfterMinutes) ?? d.escalateAfterMinutes
        pushAfterMinutes = try c.decodeIfPresent(Double.self, forKey: .pushAfterMinutes) ?? d.pushAfterMinutes
        summaries = try c.decodeIfPresent(Bool.self, forKey: .summaries) ?? d.summaries
        summaryModel = try c.decodeIfPresent(String.self, forKey: .summaryModel) ?? d.summaryModel
        approvalsFromNotch = try c.decodeIfPresent(Bool.self, forKey: .approvalsFromNotch) ?? d.approvalsFromNotch
        approvalWaitSeconds = try c.decodeIfPresent(Double.self, forKey: .approvalWaitSeconds) ?? d.approvalWaitSeconds
        menuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .menuBarIcon) ?? d.menuBarIcon
        desktopChats = try c.decodeIfPresent(Bool.self, forKey: .desktopChats) ?? d.desktopChats
        followCursorAcrossDisplays = try c.decodeIfPresent(Bool.self, forKey: .followCursorAcrossDisplays) ?? d.followCursorAcrossDisplays
        hotkeyOpen = try c.decodeIfPresent(String.self, forKey: .hotkeyOpen) ?? d.hotkeyOpen
        hotkeyJump = try c.decodeIfPresent(String.self, forKey: .hotkeyJump) ?? d.hotkeyJump
    }
}
