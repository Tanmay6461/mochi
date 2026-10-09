import AppKit
import SwiftUI

/// Places a borderless panel over the notch with the pet in it. Resting, it's the notch plus two
/// small ears (pet on the left, badge on the right). The pet drops out to say one thing when
/// something matters or when you hover; clicking it opens a small chat. Scrolling switches apps.
@MainActor
final class NotchController {
    let model = NotchModel()

    private let store: SessionStore
    private let config: Config
    private let summarizer: Summarizer
    private let pusher: PushNotifier?
    private let panel: NotchPanel
    private let appTracker = AppTracker()
    private var screen: NSScreen?
    private var screensAsleep = false  // display asleep or screen locked: the pet stops rendering

    private var timers: [Timer] = []
    private var clickMonitor: Any?
    private var escMonitor: Any?
    private var hoverStartedAt: Date?
    private var hovering = false
    private var lastInsideAt = Date.distantPast
    private var contentSize: CGSize = .zero
    private var shrinkWork: DispatchWorkItem?
    private var scrollAccumulator: CGFloat = 0
    private var switchCommit: DispatchWorkItem?
    private var pushedWaits = Set<String>()
    private var seenFinished: Set<String>?

    static let panelWidth: CGFloat = 440
    private static let maxHeight: CGFloat = 640

    init(store: SessionStore, config: Config, summarizer: Summarizer) {
        self.store = store
        self.config = config
        self.summarizer = summarizer
        pusher = config.ntfyTopic.nonEmpty.map { PushNotifier(server: config.ntfyServer, topic: $0) }

        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // above the menu bar
        panel.collectionBehavior = Self.normalSpaces // stays out of fullscreen apps (see updateFullscreenPresence)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true

        let host = FirstClickHostingView(rootView: NotchView(model: model))
        host.sizingOptions = [] // we size the panel ourselves; don't let SwiftUI move it
        host.onScroll = { [weak self] event in self?.handleScroll(event) }
        panel.contentView = host

        wireModel()
        store.observe { [weak self] in self?.sync() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }

        // Clicking anywhere else closes the panel.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.mode == .chat else { return }
                if !self.visibleRect.contains(NSEvent.mouseLocation) { self.closeChat() }
            }
        }
        // So does Esc, wherever your keyboard is (the panel never takes keyboard focus).
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return } // Esc
            MainActor.assumeIsolated {
                guard let self, self.model.mode == .chat else { return }
                self.closeChat(restoreFocus: false)
            }
        }

        // Stop rendering the pet while the display sleeps or the screen is locked.
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                               (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreensAsleep(asleep) }
            }
        }
        for (name, asleep) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreensAsleep(asleep) }
            }
        }

        screen = homeScreen
        sync()
        layout()
        panel.orderFrontRegardless()

        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 4.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.blinkNow() }
        })

        // Render the notch pictures for the current color up front, so mood changes are instant.
        PetImageCache.shared.prewarm(skin: store.pet.skin)
    }

    private func wireModel() {
        model.onContentSize = { [weak self] size in self?.contentSizeChanged(size) }
        model.onPetTap = { [weak self] in
            self?.model.pokedAt = Date() // boing
            self?.togglePanel()
        }
        model.onPet = { [weak self] in
            self?.model.pettedAt = Date()
            self?.store.petThePet()
        }
        model.onSkin = { [weak self] skin in
            PetImageCache.shared.prewarm(skin: skin)
            self?.store.setSkin(skin)
        }
        model.onOpen = { [weak self] session in self?.open(session) }
        model.onRequestAccess = { WindowIndex.requestAccess() }
        model.onMarkAllSeen = { [weak self] in self?.store.markAllViewed() }
        model.onMarkSeen = { [weak self] id in self?.store.markViewed(id) }
        model.onDecide = { [weak self] id, decision in self?.store.decide(id, decision) }
        model.onEscape = { [weak self] in self?.closeChat() }
        model.search = { [weak self] query in self?.store.search(query) ?? [] }
        model.onDrop = { [weak self] urls, projectPath in
            urls.forEach { self?.store.addLink($0, projectPath: projectPath) }
        }
        model.onOpenLink = { [weak self] link in
            self?.closeChat(restoreFocus: false)
            NSWorkspace.shared.open(link.url)
        }
        model.onRemoveLink = { [weak self] id in self?.store.removeLink(id) }
    }

    // MARK: Public actions (hotkeys)

    /// Jump hotkey (default ⌃⌥J): go to the session that has waited on you the longest.
    func jumpToOldestWaiting() {
        guard let session = store.attention.first ?? store.recent.first else { return }
        open(session)
    }

    /// Open hotkey (default ⌃⌥Space): open or close the panel.
    func toggleSearch() {
        togglePanel()
    }

    // MARK: Permission prompts

    func handlePermission(_ body: Data, respond: @escaping (Data?) -> Void) {
        guard config.approvalsFromNotch,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let sessionID = obj["session_id"] as? String else {
            respond(nil)
            return
        }
        let tool = obj["tool_name"] as? String ?? "a tool"
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let detail = ["command", "file_path", "url", "pattern", "path", "query"]
            .lazy.compactMap { input[$0] as? String }.first
            ?? (try? JSONSerialization.data(withJSONObject: input)).map { String(decoding: $0, as: UTF8.self) }
            ?? ""
        let isCodex = obj["notch_agent"] as? String == "codex"

        let approval = PendingApproval(
            sessionID: sessionID,
            cwd: obj["cwd"] as? String ?? "?",
            toolName: tool,
            detail: Formatting.oneLine(detail, max: 300),
            suggestions: isCodex ? nil : obj["permission_suggestions"], // Codex rejects updatedPermissions
            respond: respond
        )
        store.addApproval(approval)

        // Give up after a while so the terminal prompt is the only one left.
        DispatchQueue.main.asyncAfter(deadline: .now() + config.approvalWaitSeconds) { [weak self] in
            self?.store.expireApproval(approval.id)
        }
    }

    // MARK: Geometry

    private func measureNotch(on screen: NSScreen) -> (width: CGFloat, height: CGFloat) {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return (right.minX - left.maxX, screen.safeAreaInsets.top)
        }
        // External display: draw a small fake notch in the middle of the menu bar.
        return (150, max(screen.frame.maxY - screen.visibleFrame.maxY, 24))
    }

    private func topCenteredRect(width: CGFloat, height: CGFloat) -> NSRect {
        guard let screen else { return .zero }
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    /// Just the notch + ears strip.
    private var stripRect: NSRect {
        topCenteredRect(width: model.notchWidth + 2 * model.earWidth, height: model.notchHeight)
    }

    /// Room to lay out any mode before we measure it.
    private var bigRect: NSRect {
        topCenteredRect(width: Self.panelWidth, height: Self.maxHeight)
    }

    /// The part of the panel that's actually drawn right now.
    private var visibleRect: NSRect {
        topCenteredRect(width: contentSize.width, height: contentSize.height)
    }

    static let normalSpaces: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

    /// The display the pet lives on: the one with a notch, else the main display.
    private var homeScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func layout() {
        if !config.followCursorAcrossDisplays {
            screen = homeScreen
        } else if screen == nil || !NSScreen.screens.contains(where: { $0 == screen }) {
            screen = homeScreen
        }
        guard let screen else { return }
        let notch = measureNotch(on: screen)
        model.notchWidth = notch.width
        model.notchHeight = notch.height
        panel.setFrame(model.mode == .resting ? stripRect : bigRect, display: true)
        fitSoon()
    }

    /// Keep the window exactly the size of what's drawn, so the empty area never blocks clicks.
    /// Grow right away; shrink once the closing animation has finished.
    private func contentSizeChanged(_ size: CGSize) {
        contentSize = size
        let target = topCenteredRect(width: size.width, height: size.height)
        if target.height > panel.frame.height + 0.5 || target.width > panel.frame.width + 0.5 {
            panel.setFrame(target.union(panel.frame), display: true)
        }
        fitSoon()
    }

    private func fitSoon() {
        shrinkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let target = self.model.mode == .resting
                ? self.stripRect
                : self.topCenteredRect(width: self.contentSize.width, height: self.contentSize.height)
            if target.width > 0, target.height > 0, self.panel.frame != target {
                self.panel.setFrame(target, display: true)
            }
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func setMode(_ mode: NotchMode) {
        guard model.mode != mode else { return }
        if mode != .resting { panel.setFrame(bigRect, display: true) } // room for the opening animation
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { model.mode = mode }
        fitSoon()
        updatePetActivity()
    }

    // MARK: Fullscreen and battery

    /// Fullscreen apps (videos, slides, games) don't get the notch drawn over them. The one
    /// exception is a permission prompt: an agent is blocked until you answer, so it still shows.
    private func updateFullscreenPresence() {
        let behavior = model.approvals.isEmpty ? Self.normalSpaces : Self.normalSpaces.union(.fullScreenAuxiliary)
        if panel.collectionBehavior != behavior {
            panel.collectionBehavior = behavior
            panel.orderFrontRegardless()
        }
    }

    private func setScreensAsleep(_ asleep: Bool) {
        screensAsleep = asleep
        updatePetActivity()
    }

    /// The notch shows a still picture of the pet (free). The live 3D pet only exists while the panel
    /// or a permission prompt is open, and it stops rendering if the screen sleeps or locks meanwhile.
    private func updatePetActivity() {
        if model.petPaused != screensAsleep { model.petPaused = screensAsleep }
        if model.petFPS != 30 { model.petFPS = 30 }
    }

    /// Every few seconds the still pet in the notch blinks: two picture swaps, no rendering.
    private func blinkNow() {
        guard model.mode == .resting, !screensAsleep, model.earFrame == .normal,
              [Mood.idle, .working, .needsYou].contains(model.mood) else { return }
        model.earFrame = .blink
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            if self?.model.earFrame == .blink { self?.model.earFrame = .normal }
        }
    }

    /// Something finished: the still pet shows its hop picture for a moment.
    private func hopNow() {
        model.earFrame = .hop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            if self?.model.earFrame == .hop { self?.model.earFrame = .normal }
        }
    }

    // MARK: Mouse

    private func trackMouse() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        // Optionally follow the cursor to whichever display it's on (off by default: a pet that
        // jumps screens every time you move across is distracting).
        if config.followCursorAcrossDisplays, model.mode == .resting,
           let here = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }), here != screen {
            screen = here
            layout()
        }

        updateLook(mouse)
        if model.mode == .switcher { return }

        let overStrip = stripRect.insetBy(dx: -4, dy: -2).contains(mouse)
        let overContent = model.mode != .resting && visibleRect.insetBy(dx: -8, dy: -8).contains(mouse)

        if overStrip || overContent {
            lastInsideAt = now
            if !hovering {
                if hoverStartedAt == nil { hoverStartedAt = now }
                // Small dwell so flicking the cursor to the menu bar doesn't pop it open.
                if overContent || now.timeIntervalSince(hoverStartedAt!) > 0.15 { hovering = true }
            }
        } else {
            hoverStartedAt = nil
            if hovering && now.timeIntervalSince(lastInsideAt) > 0.35 { hovering = false }
        }

        // The panel opens and closes on click (notch, Esc, or anywhere else), never on hover.
        if model.mode != .chat { updatePeek() }
    }

    /// The pet's eyes follow the cursor when it's nearby.
    private func updateLook(_ mouse: NSPoint) {
        let petCenter: NSPoint
        if model.mode == .resting || model.mode == .switcher {
            petCenter = NSPoint(x: stripRect.minX + model.earWidth / 2, y: stripRect.maxY - model.notchHeight / 2)
        } else {
            petCenter = NSPoint(x: visibleRect.minX + 46, y: visibleRect.maxY - model.notchHeight - 36)
        }
        let dx = mouse.x - petCenter.x, dy = mouse.y - petCenter.y
        let near = hypot(dx, dy) < 700
        let look = near ? CGSize(width: max(-1, min(1, dx / 250)), height: max(-1, min(1, -dy / 250))) : .zero
        if abs(look.width - model.look.width) > 0.04 || abs(look.height - model.look.height) > 0.04 {
            model.look = look
        }
    }

    /// The only thing that drops down on its own: a permission prompt, because an agent is blocked
    /// until you answer. Everything else waits for a click; finished work just makes the pet hop.
    private func updatePeek() {
        guard model.mode == .resting || model.mode == .peek else { return }
        setMode(model.approvals.isEmpty ? .resting : .peek)
    }

    /// One click on the notch opens the panel; another click closes it.
    private func togglePanel() {
        if model.mode == .chat { closeChat() } else { openChat() }
    }

    /// Opens the panel, leaving your keyboard where it was.
    private func openChat() {
        if model.mode != .chat {
            model.topic = store.attention.isEmpty ? .leftOff : .needsYou
            model.showAll = false // always open with the short list
        }
        sync()
        lastInsideAt = Date()
        setMode(.chat)
    }

    private func closeChat(restoreFocus: Bool = true) {
        guard model.mode == .chat else { return }
        let wasKey = panel.isKeyWindow
        hovering = false
        setMode(.resting)
        if wasKey {
            panel.resignKey()
            // Hand the keyboard back to whatever you were using.
            if restoreFocus, let front = NSWorkspace.shared.frontmostApplication { WindowIndex.activate(pid: front.processIdentifier) }
        }
        updatePeek()
    }

    // MARK: Scroll to switch apps

    private func handleScroll(_ event: NSEvent) {
        guard model.mode == .resting || model.mode == .peek || model.mode == .switcher else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        scrollAccumulator += delta
        let step: CGFloat = 26
        var moved = 0
        while scrollAccumulator <= -step { moved += 1; scrollAccumulator += step }
        while scrollAccumulator >= step { moved -= 1; scrollAccumulator -= step }
        guard moved != 0 else { return }

        if model.mode != .switcher {
            sync()
            guard !model.apps.isEmpty else { return }
            model.switcherIndex = 0
            setMode(.switcher)
        }
        let count = model.apps.count
        withAnimation(.easeOut(duration: 0.12)) {
            model.switcherIndex = ((model.switcherIndex + moved) % count + count) % count
        }

        // Switch once you stop scrolling, like letting go of ⌘-Tab.
        switchCommit?.cancel()
        let commit = DispatchWorkItem { [weak self] in
            guard let self, self.model.mode == .switcher else { return }
            let index = self.model.switcherIndex
            self.scrollAccumulator = 0
            self.hovering = false
            self.setMode(.resting)
            if index != 0, index < self.model.apps.count { WindowIndex.activate(pid: self.model.apps[index].pid) }
        }
        switchCommit = commit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: commit)
    }

    // MARK: Data

    private func sync() {
        let now = Date()
        model.attention = store.attention
        model.working = store.working
        model.approvals = store.approvals
        model.projects = Project.build(from: Array(store.sessions.values), links: store.links)
        let projectPaths = Set(model.projects.map(\.path))
        model.looseLinks = store.links.filter { $0.projectPath.map { !projectPaths.contains($0) } ?? true }
        model.apps = appTracker.apps.prefix(10).map {
            AppItem(pid: $0.processIdentifier, name: $0.localizedName ?? "App", icon: $0.icon)
        }
        model.hasWindowAccess = WindowIndex.isTrusted
        model.blockedToday = store.blockedToday
        model.lastActivity = store.sessions.values.filter { $0.state != .ended }.map(\.lastActivity).max() ?? .distantPast
        model.now = now
        model.petStats = store.pet
        if store.lastFedAt > model.ateAt { model.ateAt = store.lastFedAt } // nom nom

        // Something just finished: the pet hops (quietly; the badge shows it's waiting for you).
        let finished = Set(store.attention.filter { $0.state == .done }.map { "\($0.id)@\($0.stateSince.timeIntervalSince1970)" })
        if let seen = seenFinished, !finished.subtracting(seen).isEmpty {
            model.celebratedAt = now
            hopNow()
        }
        seenFinished = finished

        // Escalation: the longer something is blocked on you, the louder the notch gets.
        let oldestBlocked = store.attention.filter(\.state.isBlocked).map { now.timeIntervalSince($0.stateSince) }.max() ?? 0
        let level = oldestBlocked >= config.pushAfterMinutes * 60 ? 2 : oldestBlocked >= config.escalateAfterMinutes * 60 ? 1 : 0
        if level != model.escalation {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                model.escalation = level
                model.earWidth = level > 0 ? 46 : 36
            }
            fitSoon()
        }

        updatePeek()
        updateFullscreenPresence()
        updatePetActivity()
    }

    private func tick() {
        let blockedLong = store.attention.contains { $0.state.isBlocked && Date().timeIntervalSince($0.stateSince) > 300 }
        store.tickPetMood(blockedLong: blockedLong)
        sync()
        guard let pusher else { return }
        let now = Date()
        for s in store.attention where s.state.isBlocked && now.timeIntervalSince(s.stateSince) >= config.pushAfterMinutes * 60 {
            let key = "\(s.id)@\(s.stateSince.timeIntervalSince1970)"
            guard pushedWaits.insert(key).inserted else { continue }
            pusher.send(title: "\(s.folderName) is waiting on you",
                        message: Formatting.oneLine(s.lastMessage ?? s.state.label, max: 140))
        }
    }

    private func open(_ session: Session) {
        store.markViewed(session.id)
        closeChat(restoreFocus: false)
        TerminalJumper.jump(to: session)
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // nonactivating, so your app stays active
    override var canBecomeMain: Bool { false }
}

/// Lets the first click act immediately, and forwards scrolls for app switching.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    var onScroll: ((NSEvent) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
        super.scrollWheel(with: event)
    }
}
