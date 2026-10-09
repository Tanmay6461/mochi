import AppKit

/// Weekend-1 stand-in for the notch creature: a menu bar icon that turns red when an agent needs you.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let store: SessionStore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    init(store: SessionStore) {
        self.store = store
        super.init()
        menu.delegate = self
        item.menu = menu
        store.observe { [weak self] in self?.refreshIcon() }
        refreshIcon()
    }

    private func refreshIcon() {
        guard let button = item.button else { return }
        let attention = store.attention.count
        let symbol: String
        if attention > 0 {
            symbol = "exclamationmark.bubble.fill"
        } else if !store.working.isEmpty {
            symbol = "ellipsis.bubble"
        } else {
            symbol = "bubble"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NotchPet")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = attention > 0 ? .systemRed : nil
        button.title = attention > 0 ? " \(attention)" : ""
        button.imagePosition = .imageLeading
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        addSection("Needs you", store.attention, to: menu)
        addSection("Working", store.working, to: menu)
        addSection("Recent", Array(store.recent.prefix(10)), to: menu)

        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "No Claude sessions yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        let seen = NSMenuItem(title: "Mark all as seen", action: #selector(markAllSeen), keyEquivalent: "")
        seen.target = self
        menu.addItem(seen)
        menu.addItem(NSMenuItem(title: "Quit NotchPet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addSection(_ title: String, _ sessions: [Session], to menu: NSMenu) {
        guard !sessions.isEmpty else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(NSMenuItem.sectionHeader(title: title))

        for s in sessions {
            let item = NSMenuItem(
                title: "\(s.folderName) · \(s.state.label) · \(Formatting.ago(s.stateSince))",
                action: #selector(open(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = s.id
            item.toolTip = s.cwd
            if let message = s.lastMessage {
                item.subtitle = Formatting.oneLine(message, max: 80)
            }
            menu.addItem(item)
        }
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let session = store.sessions[id] else { return }
        store.markViewed(id)
        TerminalJumper.jump(to: session)
    }

    @objc private func markAllSeen() {
        store.markAllViewed()
    }
}
