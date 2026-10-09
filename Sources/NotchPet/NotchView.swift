import SwiftUI
import UniformTypeIdentifiers

enum NotchMode: Equatable {
    case resting   // just the notch, pet in the left ear
    case peek      // pet drops out with one speech bubble
    case chat      // you clicked the pet: quick questions, up to 3 cards, ask box
    case switcher  // scrolling on the notch to switch apps
}

enum ChatTopic: Equatable {
    case needsYou, finished, leftOff
    case search(String)
}

struct AppItem: Identifiable {
    let pid: pid_t
    let name: String
    let icon: NSImage?
    var id: pid_t { pid }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var attention: [Session] = []
    @Published var working: [Session] = []
    @Published var approvals: [PendingApproval] = []
    @Published var projects: [Project] = []
    @Published var looseLinks: [SavedLink] = []
    @Published var apps: [AppItem] = []
    @Published var hasWindowAccess = false
    @Published var blockedToday: TimeInterval = 0
    @Published var lastActivity = Date.distantPast
    @Published var now = Date()

    @Published var mode: NotchMode = .resting
    @Published var switcherIndex = 0
    @Published var escalation = 0
    @Published var notchWidth: CGFloat = 180
    @Published var notchHeight: CGFloat = 32
    @Published var earWidth: CGFloat = 36
    @Published var look: CGSize = .zero
    @Published var celebratedAt = Date.distantPast
    @Published var ateAt = Date.distantPast
    @Published var pettedAt = Date.distantPast
    @Published var pokedAt = Date.distantPast
    @Published var petStats = PetStats()
    @Published var hoveredID: String?
    @Published var dropTargetID: String?

    @Published var topic: ChatTopic = .needsYou { didSet { if topic != oldValue { showAll = false } } }
    @Published var showAll = false   // "See more" expanded
    @Published var query = ""
    @Published var answer: String?
    @Published var isAsking = false
    @Published var focusToken = 0

    var onContentSize: ((CGSize) -> Void)?
    var onPet: (() -> Void)?
    var onSkin: ((Skin) -> Void)?
    var rubDistance: CGFloat = 0          // petting: how far the cursor has rubbed the pet lately
    var lastRub: (point: CGPoint, at: Date)?

    var petState: PetState {
        PetState(skin: petStats.skin, mood: mood, look: look, escalation: escalation, sad: petStats.isSad,
                 celebratedAt: celebratedAt, ateAt: ateAt, pettedAt: pettedAt, pokedAt: pokedAt)
    }

    /// Rubbing the cursor back and forth over the pet counts as petting.
    func rub(at point: CGPoint) {
        let now = Date()
        if let last = lastRub, now.timeIntervalSince(last.at) < 0.3 {
            rubDistance += hypot(point.x - last.point.x, point.y - last.point.y)
        } else {
            rubDistance = 0
        }
        lastRub = (point, now)
        if rubDistance > 140, now.timeIntervalSince(pettedAt) > 1.8 {
            rubDistance = 0
            onPet?()
        }
    }
    var onPetTap: (() -> Void)?
    var onOpen: ((Session) -> Void)?
    var onOpenProject: ((Project) -> Void)?
    var onTarget: ((ProjectTarget) -> Void)?
    var onRequestAccess: (() -> Void)?
    var onMarkAllSeen: (() -> Void)?
    var onMarkSeen: ((String) -> Void)?
    var onDecide: ((UUID, ApprovalDecision) -> Void)?
    var onAsk: ((String) -> Void)?
    var onEscape: (() -> Void)?
    var search: ((String) -> [Session])?
    var onDrop: (([URL], String?) -> Void)?
    var onOpenLink: ((SavedLink) -> Void)?
    var onRemoveLink: ((UUID) -> Void)?

    var mood: Mood {
        if !approvals.isEmpty || attention.contains(where: { $0.state.isBlocked }) { return .needsYou }
        if !attention.isEmpty { return .finished }
        if !working.isEmpty { return .working }
        return now.timeIntervalSince(lastActivity) > 15 * 60 ? .sleeping : .idle
    }

    func project(for session: Session) -> Project? {
        let key = Project.groupKey(for: session)
        return projects.first { $0.path == key }
    }

    /// Rows shown per card before "See more".
    static let rowLimit = 4

    /// The cards (ChatGPT, Claude) that have something for the current tab.
    var topicProjects: [Project] {
        projects.filter { !allRows(for: $0).isEmpty }
    }

    /// A card's rows for the current tab: the first few, or all after "See more".
    func rows(for project: Project) -> [Session] {
        let all = allRows(for: project)
        return showAll ? all : Array(all.prefix(Self.rowLimit))
    }

    /// Every session or chat in a card that answers the current tab.
    func allRows(for project: Project) -> [Session] {
        switch topic {
        case .needsYou:
            return project.sessions.filter(\.needsYou) // most urgent first
        case .finished:
            return project.sessions
                .filter { $0.state == .done && now.timeIntervalSince($0.stateSince) < 86400 }
                .sorted { $0.stateSince > $1.stateSince }
        case .leftOff:
            return project.sessions
                .filter { $0.state != .working }
                .sorted { $0.lastActivity > $1.lastActivity }
        case .search(let q):
            let matches = Set((search?(q) ?? []).map(\.id))
            return project.sessions.filter { matches.contains($0.id) }
        }
    }

    /// How many rows "See more" would reveal.
    var hiddenRowCount: Int {
        topicProjects.reduce(0) { $0 + max(0, allRows(for: $1).count - Self.rowLimit) }
    }

    var totalRowCount: Int {
        topicProjects.reduce(0) { $0 + allRows(for: $1).count }
    }
}

// MARK: Root

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @Namespace private var ns

    private var width: CGFloat {
        switch model.mode {
        case .resting: model.notchWidth + 2 * model.earWidth
        case .peek: 400
        case .chat, .switcher: NotchController.panelWidth
        }
    }

    private var shape: UnevenRoundedRectangle {
        let r: CGFloat = model.mode == .resting ? 12 : 24
        return UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack {
                    if model.mode == .resting || model.mode == .switcher {
                        pet(detailed: false)
                            .frame(width: model.earWidth - 2, height: model.notchHeight - 2)
                            .matchedGeometryEffect(id: "pet", in: ns)
                    }
                }
                .frame(width: model.earWidth, height: model.notchHeight)
                Spacer(minLength: 0)
                Badge(model: model)
                    .frame(width: model.earWidth, height: model.notchHeight)
            }
            .frame(height: model.notchHeight)
            .contentShape(Rectangle())
            .onTapGesture { model.onPetTap?() } // one click anywhere on the notch opens (or closes) the panel

            switch model.mode {
            case .resting:
                EmptyView()
            case .peek:
                PeekView(model: model, pet: pet(detailed: true).matchedGeometryEffect(id: "pet", in: ns))
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            case .chat:
                ChatView(model: model, pet: pet(detailed: true).matchedGeometryEffect(id: "pet", in: ns))
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            case .switcher:
                SwitcherStrip(apps: model.apps, selected: model.switcherIndex)
                    .transition(.opacity)
            }
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.black)
        .clipShape(shape)
        .overlay(EscalationRing(level: model.escalation, shape: shape))
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { model.onContentSize?($0) }
        .onDrop(of: [.url, .fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { model.onDrop?($0, nil) }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.mode)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.approvals.count)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private func pet(detailed: Bool) -> PetView {
        PetView(state: model.petState, detailed: detailed)
    }
}

/// Pulls URLs (web links or files) out of a drop.
@MainActor
func loadURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) -> Bool {
    let usable = providers.filter { $0.canLoadObject(ofClass: URL.self) }
    guard !usable.isEmpty else { return false }
    for provider in usable {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { done([url]) }
        }
    }
    return true
}

/// A pulsing outline once something has been blocked on you for a while.
struct EscalationRing: View {
    let level: Int
    let shape: UnevenRoundedRectangle

    var body: some View {
        if level > 0 {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let pulse = 0.35 + 0.45 * abs(sin(t * (level > 1 ? 4 : 2)))
                shape.stroke(Mood.needsYou.color.opacity(pulse), lineWidth: level > 1 ? 2 : 1.2)
            }
            .allowsHitTesting(false)
        }
    }
}

struct Badge: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let count = max(model.attention.count, model.approvals.count)
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .frame(minWidth: 17, minHeight: 17)
                .background(Circle().fill(model.mood.color))
                .transition(.scale)
        } else if !model.working.isEmpty {
            RunningDot(count: model.working.count) // always visible: something is running
                .transition(.scale)
        }
    }
}

// MARK: Peek: the pet says one thing

struct PeekView<Pet: View>: View {
    @ObservedObject var model: NotchModel
    let pet: Pet

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            pet.frame(width: 70, height: 70)
                .contentShape(Rectangle())
                .onTapGesture { model.onPetTap?() }
                .onContinuousHover { phase in
                    if case .active(let p) = phase { model.rub(at: p) }
                }
                .help("Click to chat · rub to pet")
            SpeechBubble { content }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        let others = max(0, max(model.attention.count, model.approvals.count) - 1)
        VStack(alignment: .leading, spacing: 8) {
            if let approval = model.approvals.first {
                ApprovalContent(model: model, approval: approval)
            } else if let session = model.attention.first {
                SessionLine(model: model, session: session)
            } else if !model.working.isEmpty {
                RunningList(model: model, title: "Running")
            } else {
                PetSays(text: model.mood == .sleeping ? "Zzz… nothing's running. Click me if you need something." : "All quiet. Nothing needs you right now.")
            }
            if !model.working.isEmpty && (model.approvals.first != nil || model.attention.first != nil) {
                RunningList(model: model, title: "Also running")
            }
            if others > 0 {
                Button { model.topic = .needsYou; model.onPetTap?() } label: {
                    Text("\(others) more waiting →").font(.system(size: 11, weight: .medium)).foregroundStyle(model.mood.color)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SpeechBubble<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(
                BubbleShape()
                    .fill(Color(white: 0.13))
                    .overlay(BubbleShape().stroke(.white.opacity(0.08), lineWidth: 1))
            )
    }
}

/// Rounded rectangle with a little tail pointing left at the pet.
struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 13, tail: CGFloat = 7
        var p = Path(roundedRect: rect, cornerRadius: r)
        let y = min(rect.midY, rect.minY + 30)
        p.move(to: CGPoint(x: rect.minX + 1, y: y - tail))
        p.addLine(to: CGPoint(x: rect.minX - tail, y: y))
        p.addLine(to: CGPoint(x: rect.minX + 1, y: y + tail))
        p.closeSubpath()
        return p
    }
}

struct PetSays: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SessionLine: View {
    @ObservedObject var model: NotchModel
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                switch session.state {
                case .done:
                    Text("**\(session.folderName)** is done") + Text(detail.map { ": \($0)" } ?? ".")
                case .needsInput:
                    Text("**\(session.folderName)** has a question for you") + Text(detail.map { ": \($0)" } ?? ".")
                default:
                    Text("**\(session.folderName)** needs you.")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                PillButton(title: "Take me there", style: .primary) { model.onOpen?(session) }
                PillButton(title: "Later", style: .quiet) { model.onMarkSeen?(session.id) }
            }
        }
    }

    private var detail: String? {
        (session.title ?? session.lastMessage).map { Formatting.oneLine($0, max: 90) }
    }
}

struct ApprovalContent: View {
    @ObservedObject var model: NotchModel
    let approval: PendingApproval

    private var verb: String {
        switch approval.toolName {
        case "Bash": "wants to run"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": "wants to edit"
        case "WebFetch": "wants to open"
        default: "wants to use \(approval.toolName)"
        }
    }

    private var shownDetail: String {
        ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(approval.toolName)
            ? (approval.detail as NSString).lastPathComponent : approval.detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text("**\(approval.projectName)** ") + Text(verb))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.92))
            Text(shownDetail)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.07)))
            HStack(spacing: 6) {
                PillButton(title: "Allow", style: .primary) { model.onDecide?(approval.id, .allow) }
                if approval.suggestions != nil {
                    PillButton(title: "Always", style: .quiet) { model.onDecide?(approval.id, .allowAlways) }
                }
                PillButton(title: "Deny", style: .quiet) { model.onDecide?(approval.id, .deny) }
            }
        }
    }
}

struct PillButton: View {
    enum Style { case primary, quiet }
    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style == .primary ? .black : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(style == .primary ? Color.white : .white.opacity(0.13)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Chat: ask the pet

struct ChatView<Pet: View>: View {
    @ObservedObject var model: NotchModel
    let pet: Pet
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(spacing: 2) {
                    pet.frame(width: 64, height: 64)
                        .onContinuousHover { phase in
                            if case .active(let p) = phase { model.rub(at: p) }
                        }
                        .help("Rub to pet")
                    PetStatsLine(stats: model.petStats)
                }
                SpeechBubble {
                    if model.isAsking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            PetSays(text: "Thinking…")
                        }
                    } else {
                        PetSays(text: model.answer ?? headline)
                    }
                }
            }

            HStack(spacing: 6) {
                Chip(title: "What needs me?", selected: model.topic == .needsYou) { select(.needsYou) }
                Chip(title: "Where did I leave off?", selected: model.topic == .leftOff) { select(.leftOff) }
            }

            ForEach(model.approvals.prefix(1)) { approval in
                SpeechBubble { ApprovalContent(model: model, approval: approval) }
            }

            if !model.working.isEmpty {
                RunningList(model: model, title: "Running now")
            }

            VStack(spacing: 6) {
                ForEach(model.topicProjects) { ProjectCard(model: model, project: $0) }
                let hidden = model.hiddenRowCount
                if hidden > 0 || model.showAll && model.topicProjects.contains(where: { model.allRows(for: $0).count > NotchModel.rowLimit }) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.showAll.toggle() }
                    } label: {
                        Text(model.showAll ? "Show less" : "See more (\(hidden))")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            askField

            HStack(spacing: 12) {
                if model.blockedToday >= 60 {
                    Label("Blocked on you \(Formatting.duration(model.blockedToday)) today", systemImage: "hourglass")
                }
                if !model.hasWindowAccess {
                    Button("Allow window access") { model.onRequestAccess?() }
                        .foregroundStyle(Mood.needsYou.color)
                }
                Spacer()
                Menu {
                    Menu("Color") {
                        ForEach(Skin.allCases, id: \.self) { skin in
                            Button((skin == model.petStats.skin ? "✓ " : "") + skin.label) { model.onSkin?(skin) }
                        }
                    }
                    Button("Mark everything seen") { model.onMarkAllSeen?() }
                    Divider()
                    Button("Quit NotchPet") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .onChange(of: model.focusToken) { focused = true }
    }

    private var headline: String {
        let count = model.totalRowCount
        switch model.topic {
        case .needsYou:
            return count == 0 ? "Nothing needs you right now. Nice." : count == 1 ? "This one needs you:" : "These \(count) need you:"
        case .finished:
            return count == 0 ? "Nothing finished in the last day." : "Finished recently:"
        case .leftOff:
            return count == 0 ? "No past sessions yet." : "Here's where you left off:"
        case .search(let q):
            return count == 0 ? "I couldn't find \"\(q)\"." : "Found these for \"\(q)\":"
        }
    }

    private func select(_ topic: ChatTopic) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            model.topic = topic
            model.answer = nil
        }
    }

    private var askField: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkle").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            TextField("Ask me anything about your agents…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit {
                    let q = model.query.trimmingCharacters(in: .whitespaces)
                    guard !q.isEmpty else { return }
                    model.topic = .search(q)
                    model.onAsk?(q)
                }
                .onExitCommand { model.onEscape?() }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? .black : .white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? Color.white : .white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}

/// One project, as a compact card: status, what it's about, where it stands, what's next.
struct ProjectCard: View {
    @ObservedObject var model: NotchModel
    let project: Project

    private var session: Session { project.lead }
    private var hovering: Bool { model.hoveredID == project.id }
    private var dropping: Bool { model.dropTargetID == project.id }

    private var accent: Color {
        switch session.state {
        case .needsPermission, .needsInput: Mood.needsYou.color
        case .done: session.needsYou ? Mood.finished.color : .white.opacity(0.35)
        case .working: Mood.working.color
        default: .white.opacity(0.35)
        }
    }

    /// The real app icon: ChatGPT (which may ship under Codex's ID) or Claude.
    private var appIcon: NSImage? {
        let ids = project.name == "ChatGPT" ? ["com.openai.chat", "com.openai.codex"] : ["com.anthropic.claudefordesktop"]
        for id in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }

    var body: some View {
        let waiting = project.sessions.filter(\.needsYou).count
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                AppIcon(icon: appIcon, size: 16)
                Text(project.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 0)
                if waiting > 0 {
                    Text("\(waiting) need\(waiting == 1 ? "s" : "") you")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(accent)
                }
            }
            SessionRows(model: model, sessions: model.rows(for: project))
            if !project.links.isEmpty {
                LinkChips(model: model, links: project.links)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(dropping ? 0.16 : 0.06))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Mood.finished.color.opacity(dropping ? 0.7 : 0), lineWidth: 1))
        )
        .onDrop(of: [.url, .fileURL], isTargeted: Binding(
            get: { dropping },
            set: { model.dropTargetID = $0 ? project.id : (dropping ? nil : model.dropTargetID) }
        )) { providers in
            loadURLs(providers) { model.onDrop?($0, project.path) }
        }
    }
}

/// The rows inside a ChatGPT / Claude card: one per chat or Claude Code session. Clicking a row
/// opens that exact chat or session.
struct SessionRows: View {
    @ObservedObject var model: NotchModel
    let sessions: [Session]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(sessions) { session in
                let key = "row-\(session.id)"
                Button { model.onOpen?(session) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(color(for: session)).frame(width: 5, height: 5)
                        KindIcon(kind: session.kind)
                        Text(label(for: session))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.88))
                        Spacer(minLength: 4)
                        Text(status(for: session))
                            .font(.system(size: 10.5))
                            .foregroundStyle(statusColor(for: session))
                    }
                    .lineLimit(1)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(model.hoveredID == key ? 0.1 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { model.hoveredID = key } else if model.hoveredID == key { model.hoveredID = nil }
                }
                .help(session.kind == .chat ? "Open this chat" : "Open this session (\(session.cwd))")
            }
        }
    }

    /// Chats by their title; Claude Code sessions as "folder · what it's about".
    private func label(for s: Session) -> String {
        if s.kind == .chat { return s.title ?? "Untitled chat" }
        let about = s.title ?? s.lastPrompt.map { Formatting.oneLine($0, max: 60) }
        return [s.folderName, about].compactMap { $0 }.joined(separator: " · ")
    }

    private func status(for s: Session) -> String {
        switch s.state {
        case .working: return s.kind == .chat ? "writing…" : "working…"
        case .needsPermission, .needsInput: return s.state.label
        case .done where s.needsYou: return "finished"
        default: return Formatting.ago(s.lastActivity)
        }
    }

    private func color(for s: Session) -> Color {
        switch s.state {
        case .working: return Mood.working.color
        case .needsPermission, .needsInput: return Mood.needsYou.color
        case .done where s.needsYou: return Mood.finished.color
        default: return .white.opacity(0.3)
        }
    }

    private func statusColor(for s: Session) -> Color {
        switch s.state {
        case .working, .needsPermission, .needsInput: return color(for: s)
        case .done where s.needsYou: return color(for: s)
        default: return .white.opacity(0.4)
        }
    }
}

struct KindIcon: View {
    let kind: SessionKind

    var body: some View {
        switch kind {
        case .claude: EmptyView()
        case .codex:
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5)).help("Codex")
        case .job:
            Image(systemName: "terminal")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).help("Shell job (notch-run)")
        case .chat:
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).help("Desktop chat (Claude or ChatGPT)")
        }
    }
}

struct LinkChips: View {
    @ObservedObject var model: NotchModel
    let links: [SavedLink]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(links.prefix(3)) { link in
                Button { model.onOpenLink?(link) } label: {
                    Label(link.label, systemImage: link.symbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help(link.url.absoluteString)
                .contextMenu { Button("Remove") { model.onRemoveLink?(link.id) } }
            }
            if links.count > 3 {
                Text("+\(links.count - 3)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

// MARK: Scroll switcher

struct SwitcherStrip: View {
    let apps: [AppItem]
    let selected: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    AppIcon(icon: app.icon, size: index == selected ? 38 : 28)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(index == selected ? 0.18 : 0)))
                }
            }
            if selected < apps.count {
                Text(apps[selected].name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }
}

struct AppIcon: View {
    let icon: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                RoundedRectangle(cornerRadius: size / 4).fill(.white.opacity(0.2))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: Running now

/// A pulsing green dot (with a count when more than one): something is running.
struct RunningDot: View {
    let count: Int

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let pulse = 0.5 + 0.5 * abs(sin(context.date.timeIntervalSinceReferenceDate * 2.4))
            HStack(spacing: 3) {
                Circle()
                    .fill(Mood.working.color)
                    .frame(width: 8, height: 8)
                    .shadow(color: Mood.working.color.opacity(pulse), radius: 4)
                if count > 1 {
                    Text("\(count)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Mood.working.color)
                }
            }
        }
        .help("\(count) running")
    }
}

/// The sessions working right now, in green, with how long they've been at it.
struct RunningList: View {
    @ObservedObject var model: NotchModel
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Mood.working.color.opacity(0.8))
            ForEach(model.working.prefix(4)) { session in
                Button { model.onOpen?(session) } label: {
                    HStack(spacing: 7) {
                        RunningDot(count: 1).frame(width: 10)
                        KindIcon(kind: session.kind)
                        Text(session.folderName).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        if let what = session.title ?? session.lastPrompt {
                            Text(Formatting.oneLine(what, max: 40)).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer(minLength: 4)
                        Text(Formatting.duration(model.now.timeIntervalSince(session.stateSince)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Mood.working.color)
                    }
                    .lineLimit(1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if model.working.count > 4 {
                Text("+\(model.working.count - 4) more").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// The pet's name under it in the panel.
struct PetStatsLine: View {
    let stats: PetStats

    var body: some View {
        Text(stats.name)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.8))
    }
}
