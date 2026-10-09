import AppKit

if let i = CommandLine.arguments.firstIndex(of: "--render-pet"), i + 1 < CommandLine.arguments.count {
    PetSnapshot.render(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    app.run()
}
