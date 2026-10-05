// Lavi's look (shared by the speech bubble, the click menu and Settings) and the click menu itself:
// a speech-bubble card beside Lavi in place of a plain macOS menu.
import AppKit
import SwiftUI

enum Theme {
    static let ink = NSColor(srgbRed: 0.17, green: 0.13, blue: 0.27, alpha: 1)      // outlines and text: Lavi's charcoal-purple
    static let lavender = NSColor(srgbRed: 0.61, green: 0.53, blue: 0.88, alpha: 1) // his body
    static let lilac = NSColor(srgbRed: 0.94, green: 0.92, blue: 0.99, alpha: 1)    // pale fills
    static let mint = NSColor(srgbRed: 0.27, green: 0.82, blue: 0.64, alpha: 1)     // his face glow: "on" states

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .rounded) }
}

extension Color {
    static let ink = Color(nsColor: Theme.ink)
    static let inkSoft = Color(nsColor: Theme.ink.withAlphaComponent(0.68)) // still ≥ 4.5:1 on white
    static let lavender = Color(nsColor: Theme.lavender)
    static let lilac = Color(nsColor: Theme.lilac)
    static let mint = Color(nsColor: Theme.mint)
}

// MARK: - Bubble chrome (same silhouette as BubbleView: white body, 3 pt ink outline, curved tail)

struct BubbleChrome: View {
    static let tail: CGFloat = 22, margin: CGFloat = 10
    var tailOnRight: Bool
    var tailFromBottom: CGFloat // the card grows upward, so the tail stays level with Lavi

    var body: some View {
        GeometryReader { g in
            let tailY = min(max(g.size.height - tailFromBottom, 30), g.size.height - 30)
            let bodyRect = CGRect(x: tailOnRight ? 0 : Self.tail, y: 0, width: g.size.width - Self.tail, height: g.size.height)
            let shapes = [AnyShape(RoundedRectangle(cornerRadius: 18).path(in: bodyRect)), AnyShape(TailShape(body: bodyRect, onRight: tailOnRight, y: tailY))]
            ZStack {
                // stroke both at double width, then fill both white: only the outline of the union is left
                ForEach(0..<2, id: \.self) { shapes[$0].fill(Color.white).shadow(color: .black.opacity(0.28), radius: 7, y: 3) }
                ForEach(0..<2, id: \.self) { shapes[$0].stroke(Color.ink, style: StrokeStyle(lineWidth: 6, lineJoin: .round)) }
                ForEach(0..<2, id: \.self) { shapes[$0].fill(Color.white) }
            }
        }
    }
}

private struct TailShape: Shape {
    let body: CGRect, onRight: Bool, y: CGFloat
    func path(in _: CGRect) -> Path {
        let d: CGFloat = onRight ? 1 : -1, e = onRight ? body.maxX : body.minX, t = BubbleChrome.tail
        var p = Path()
        p.move(to: CGPoint(x: e - d * 14, y: y - 13))
        p.addCurve(to: CGPoint(x: e + d * t, y: y + 12), control1: CGPoint(x: e + d * 4, y: y - 10), control2: CGPoint(x: e + d * 12, y: y + 2))
        p.addCurve(to: CGPoint(x: e - d * 14, y: y + 8), control1: CGPoint(x: e + d * 6, y: y + 10), control2: CGPoint(x: e - d * 2, y: y + 9))
        p.closeSubpath()
        return p
    }
}

// MARK: - Shared controls

/// Lilac pill with an ink outline; darker while pressed.
struct ChipStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(12, .semibold)).foregroundStyle(Color.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(configuration.isPressed ? Color.lavender : prominent ? Color.mint.opacity(0.35) : Color.lilac))
            .overlay(Capsule().strokeBorder(Color.ink, lineWidth: 1.5))
            .contentShape(Capsule())
    }
}

/// "working in <folder> · <branch>": the session Lavi is talking about.
struct PlacePill: View {
    let project: String, branch: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill").font(.system(size: 10))
            Text("working in \(Text(project).fontWeight(.bold))").lineLimit(1).truncationMode(.middle)
            Text("·").foregroundStyle(Color.inkSoft)
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
            Text(branch.isEmpty ? "no git" : branch).lineLimit(1).truncationMode(.middle)
        }
        .font(Theme.font(11, .medium)).foregroundStyle(Color.ink)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color.lilac))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("working in \(project), branch \(branch.isEmpty ? "none" : branch)")
    }
}

// MARK: - The click menu

struct MenuData {
    struct Tip { let text: String; let why: String; let snippets: [(label: String, text: String)] }
    struct Row: Identifiable {
        let id: String; let cwd: String; let title: String; let subtitle: String
        var busy = false, inApp = true, waiting = false
    }
    var project: String?, branch = ""
    var tips: [Tip] = []
    var live: [Row] = [], recent: [Row] = [], projects: [Row] = []
    var voiceOn = true
    var waitingCount: Int { live.filter(\.waiting).count }

    func rows(_ tab: MenuState.Tab) -> [Row] { tab == .live ? live : tab == .recent ? recent : projects }
}

struct MenuActions {
    /// Puts a prompt in the session's message box (or on the clipboard when it can't).
    var send: (String) -> Void = { _ in }
    var open: (MenuData.Row) -> Void = { _ in }
    var resumeInTerminal: (MenuData.Row) -> Void = { _ in }
    var copyResume: (MenuData.Row) -> Void = { _ in }
    var openProject: (MenuData.Row) -> Void = { _ in }
    var qa: () -> Void = {}, qaCopy: () -> Void = {}, waiting: () -> Void = {}, newSession: () -> Void = {}, handoff: () -> Void = {}
    var relayout: () -> Void = {} // set by the panel: the content changed height
    var checkProjects: () -> Void = {}, toggleVoice: () -> Void = {}, hide: () -> Void = {}, settings: () -> Void = {}, quit: () -> Void = {}
}

/// What the keyboard moves: the tab, and the highlighted row in it.
final class MenuState: ObservableObject {
    enum Tab: String, CaseIterable { case live = "Live", recent = "Recent", projects = "Projects" }
    @Published var tab: Tab
    @Published var selected: Int?
    init(tab: Tab) { self.tab = tab }
}

struct LaviMenuView: View {
    static let rowHeight: CGFloat = 44, maxRows = 5

    let data: MenuData, act: MenuActions
    @ObservedObject var state: MenuState
    var tailOnRight = true, tailFromBottom: CGFloat = 60
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            advice
            Divider().overlay(Color.ink.opacity(0.15))
            quickActions
            Divider().overlay(Color.ink.opacity(0.15))
            sessions
            Divider().overlay(Color.ink.opacity(0.15))
            footer
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(width: 340)
        .padding(.leading, tailOnRight ? 0 : BubbleChrome.tail)
        .padding(.trailing, tailOnRight ? BubbleChrome.tail : 0)
        .background(BubbleChrome(tailOnRight: tailOnRight, tailFromBottom: tailFromBottom))
        .padding(BubbleChrome.margin)
        // A little pop from the tail when it opens (none with Reduce Motion).
        .scaleEffect(appeared ? 1 : 0.92, anchor: tailOnRight ? .bottomTrailing : .bottomLeading)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            withAnimation(reduce ? nil : .spring(response: 0.28, dampingFraction: 0.68)) { appeared = true }
        }
        .environment(\.colorScheme, .light) // a cartoon bubble is white in dark mode too
    }

    // What Lavi suggests, with prompts that go straight into Claude's message box.
    @ViewBuilder var advice: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let project = data.project { PlacePill(project: project, branch: data.branch) }
            if let tip = data.tips.first {
                Text(tip.text).font(Theme.font(16, .semibold)).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
                Text(tip.why).font(Theme.font(12)).foregroundStyle(Color.inkSoft).fixedSize(horizontal: false, vertical: true)
                if !tip.snippets.isEmpty {
                    Text("click a prompt to put it in Claude's message box. you press enter.")
                        .font(Theme.font(11, .medium)).foregroundStyle(Color.inkSoft).padding(.top, 2).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tip.snippets.indices, id: \.self) { i in
                            Button { act.send(tip.snippets[i].text) } label: {
                                HStack(spacing: 6) {
                                    Text("\(i + 1)").font(Theme.font(10, .bold)).frame(width: 16, height: 16)
                                        .background(Circle().fill(Color.white)).overlay(Circle().strokeBorder(Color.ink, lineWidth: 1))
                                        .accessibilityHidden(true)
                                    Text(tip.snippets[i].label)
                                }
                            }
                            .buttonStyle(ChipStyle(prominent: i == 0)).help(tip.snippets[i].text + "\n\n(press \(i + 1))")
                            .accessibilityHint("puts this prompt in Claude's message box. shortcut: \(i + 1)")
                        }
                    }
                }
                ForEach(data.tips.indices.dropFirst(), id: \.self) { i in
                    let t = data.tips[i]
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("also").font(Theme.font(10, .bold)).foregroundStyle(Color.inkSoft).textCase(.uppercase)
                        Text(t.text).font(Theme.font(12, .medium)).foregroundStyle(Color.ink).help(t.why)
                        Spacer(minLength: 4)
                        if !t.snippets.isEmpty {
                            Menu {
                                ForEach(t.snippets.indices, id: \.self) { j in Button("Put “\(t.snippets[j].label)” in Claude") { act.send(t.snippets[j].text) } }
                            } label: { Image(systemName: "text.bubble") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("prompts for this")
                        }
                    }
                }
            } else {
                Text("nothing going on right now").font(Theme.font(16, .semibold)).foregroundStyle(Color.ink)
                Text("start a Claude Code session and I'll keep an eye on it.").font(Theme.font(12)).foregroundStyle(Color.inkSoft)
            }
        }
    }

    var quickActions: some View {
        HStack(spacing: 6) {
            Tile(icon: "checkmark.shield.fill", title: "QA + security", action: act.qa)
                .help(data.project == nil ? "copies the full QA + security prompt" : "opens a new session in \(data.project!) with the full QA + security prompt typed in (right-click to just copy it)")
                .contextMenu { Button("Copy the QA prompt", action: act.qaCopy) }
            Tile(icon: "bell.badge.fill", title: "Waiting on you", badge: data.waitingCount, action: act.waiting)
                .help(data.waitingCount > 0 ? "\(data.waitingCount) session\(data.waitingCount == 1 ? "" : "s") need your answer" : "sessions that need your answer")
            Tile(icon: "plus.bubble.fill", title: "New session", action: act.newSession).help("start a new Claude Code session")
            Tile(icon: "doc.text.fill", title: "Handoff", action: act.handoff)
                .help(data.project == nil ? "copies /lavi handoff to paste into a session" : "drafts a SecondBrain handoff for \(data.project!) into its message box")
        }
    }

    var rows: [MenuData.Row] { data.rows(state.tab) }

    var sessions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(MenuState.Tab.allCases, id: \.self) { t in
                    Button { state.tab = t; state.selected = nil } label: {
                        HStack(spacing: 4) {
                            Text(t.rawValue)
                            if t == .live && data.waitingCount > 0 { Circle().fill(Color.ink).frame(width: 6, height: 6).accessibilityLabel("someone's waiting") }
                        }
                        .font(Theme.font(12, .semibold)).foregroundStyle(Color.ink)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(state.tab == t ? Color.lavender.opacity(0.55) : .clear))
                        .overlay(Capsule().strokeBorder(Color.ink.opacity(state.tab == t ? 1 : 0.25), lineWidth: 1.5))
                        .contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(state.tab == t ? .isSelected : [])
                }
                Spacer()
                if state.tab == .projects {
                    Button(action: act.checkProjects) { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(Color.ink).help("check my projects now")
                }
            }
            let height = CGFloat(min(Self.maxRows, max(1, rows.count))) * Self.rowHeight
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if rows.isEmpty {
                            Text(state.tab == .projects ? "every project is committed and pushed." : "no sessions here.")
                                .font(Theme.font(12)).foregroundStyle(Color.inkSoft).frame(maxWidth: .infinity, minHeight: Self.rowHeight)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                            SessionRow(row: r, isProject: state.tab == .projects, isSelected: state.selected == i, act: act).frame(height: Self.rowHeight).id(i)
                        }
                    }
                }
                .onChange(of: state.selected) { _, i in if let i { proxy.scrollTo(i) } }
            }
            .frame(height: height)
            .scrollIndicators(rows.count > Self.maxRows ? .automatic : .never)
            .onChange(of: state.tab) { act.relayout() }
        }
    }

    var footer: some View {
        HStack(spacing: 14) {
            Button(action: act.toggleVoice) {
                Label(data.voiceOn ? "Voice on" : "Muted", systemImage: data.voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }.help(data.voiceOn ? "mute Lavi" : "let Lavi talk")
            Button(action: act.hide) { Label("Hide 1 hr", systemImage: "eye.slash") }.help("hide Lavi for an hour")
            Button(action: act.settings) { Label("Settings", systemImage: "gearshape.fill") }.help("Lavi's settings (⌘,)")
            Spacer(minLength: 0)
            Button(action: act.quit) { Image(systemName: "power") }.help("quit Lavi").accessibilityLabel("Quit Lavi")
        }
        .buttonStyle(.plain).font(Theme.font(12, .semibold)).foregroundStyle(Color.ink)
    }
}

private struct Tile: View {
    let icon: String, title: String
    var badge = 0
    let action: () -> Void
    @State var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(Theme.font(10.5, .semibold)).multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Color.lavender.opacity(0.45) : Color.lilac))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.ink, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(badge)").font(Theme.font(10, .bold)).foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18).background(Circle().fill(Color.ink)).offset(x: 5, y: -5)
                        .accessibilityLabel("\(badge) waiting")
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

private struct SessionRow: View {
    let row: MenuData.Row, isProject: Bool, isSelected: Bool, act: MenuActions
    @State var hover = false
    var body: some View {
        HStack(spacing: 8) {
            Button { isProject ? act.openProject(row) : act.open(row) } label: {
                HStack(spacing: 8) {
                    Circle().fill(row.busy ? Color.mint : Color.clear).overlay(Circle().stroke(Color.ink.opacity(row.busy ? 1 : 0), lineWidth: 1)).frame(width: 8, height: 8)
                        .accessibilityLabel(row.busy ? "working" : "")
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(row.title).font(Theme.font(13, .semibold)).foregroundStyle(Color.ink).lineLimit(1)
                            if row.waiting {
                                Text("needs you").font(Theme.font(10, .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.ink))
                            }
                        }
                        Text(row.subtitle).font(Theme.font(11)).foregroundStyle(Color.inkSoft).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isProject ? "new Claude session in \(row.cwd)" : row.inApp ? "open in the Claude app" : "open in the Claude app (imports it)")
            if !isProject {
                Menu {
                    Button(row.inApp ? "Open in Claude app" : "Open in Claude app (imports it)") { act.open(row) }
                    Button("Resume in Terminal") { act.resumeInTerminal(row) }
                    Button("Copy resume command") { act.copyResume(row) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("more ways to open it")
            }
        }
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.lavender.opacity(0.4) : hover ? Color.lilac : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.ink.opacity(isSelected ? 0.6 : 0), lineWidth: 1.5))
        .onHover { hover = $0 }
    }
}

// MARK: - The panel that holds it

/// Tells the panel when the SwiftUI content wants a different size (switching tabs).
final class ResizingHost<V: View>: NSHostingView<V> {
    var onResize: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }
}

final class MenuPanel: NSPanel {
    private var clickMonitor: Any?, keyMonitor: Any?
    private var data = MenuData(), act = MenuActions(), state = MenuState(tab: .live)
    var onClose: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false; backgroundColor = .clear; hasShadow = false; level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { true } // for the keyboard, without activating Lavi
    override func cancelOperation(_ sender: Any?) { close() }

    /// Opens beside `lavi` (screen frame) with the tail pointing at his face.
    func show(_ data: MenuData, _ act: MenuActions, beside lavi: NSRect) {
        self.data = data
        state = MenuState(tab: data.live.isEmpty ? .recent : .live)
        var act = act
        act.relayout = { [weak self] in DispatchQueue.main.async { self?.fit() } }
        self.act = act
        let screen = (NSScreen.screens.first { $0.frame.intersects(lavi) } ?? NSScreen.main)?.visibleFrame ?? lavi
        let width = NSHostingView(rootView: LaviMenuView(data: data, act: act, state: state)).fittingSize.width
        let onRight = lavi.minX - width + 4 > screen.minX // sit left of Lavi when there's room, like the bubble
        let face = lavi.minY + lavi.height * 0.62
        let bottom = max(screen.minY + 4, face - 70)
        let host = ResizingHost(rootView: LaviMenuView(data: data, act: act, state: state, tailOnRight: onRight, tailFromBottom: face - bottom - BubbleChrome.margin))
        host.onResize = { [weak self] in self?.fit() }
        contentView = host
        setFrame(NSRect(x: onRight ? lavi.minX - width + 4 : lavi.maxX - 4, y: bottom, width: width, height: host.fittingSize.height), display: true)
        fit()
        makeKeyAndOrderFront(nil)
        // A click anywhere else closes it, like a menu.
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, self.isVisible, e.window === self || NSApp.keyWindow === self else { return e }
                return self.handleKey(e) ? nil : e
            }
        }
    }

    /// 1–9 put that prompt in Claude · ↑↓ pick a session · ←→ switch tabs · ⏎ open it · esc close · ⌘, settings.
    func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        if mods == .command, e.charactersIgnoringModifiers == "," { act.settings(); return true }
        guard mods.isEmpty else { return false }
        let rows = data.rows(state.tab)
        switch e.keyCode {
        case 53: close() // esc
        case 125: state.selected = rows.isEmpty ? nil : min((state.selected ?? -1) + 1, rows.count - 1) // ↓
        case 126: state.selected = rows.isEmpty ? nil : max((state.selected ?? rows.count) - 1, 0) // ↑
        case 123, 124: // ← →
            let tabs = MenuState.Tab.allCases, i = tabs.firstIndex(of: state.tab)!
            state.tab = tabs[(i + (e.keyCode == 124 ? 1 : tabs.count - 1)) % tabs.count]
            state.selected = nil
        case 36, 76: // return, enter
            guard let i = state.selected, rows.indices.contains(i) else { return false }
            state.tab == .projects ? act.openProject(rows[i]) : act.open(rows[i])
        default:
            guard let n = Int(e.charactersIgnoringModifiers ?? ""), n >= 1, let tip = data.tips.first, n <= tip.snippets.count else { return false }
            act.send(tip.snippets[n - 1].text)
        }
        return true
    }

    /// Keeps the bottom (and the tail) where it is and grows upward, staying on screen.
    private func fit() {
        guard let h = contentView?.fittingSize.height, h > 0 else { return }
        var f = frame
        f.size.height = h
        if let top = screen?.visibleFrame.maxY, f.maxY > top { f.origin.y = max(top - h, screen?.visibleFrame.minY ?? 0) }
        if f != frame { setFrame(f, display: true) }
    }

    override func close() {
        for m in [clickMonitor, keyMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(m) }
        clickMonitor = nil; keyMonitor = nil
        guard isVisible else { return }
        orderOut(nil)
        onClose?()
    }
}
