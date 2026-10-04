// CodeBuddy: a floating desktop character that mirrors your Claude Code sessions.
// Reads ~/.claude/codebuddy/sessions/*.json (written by the codebuddy mod) and
// ~/.claude/projects/*/*.jsonl (Claude Code transcripts). No dependencies.
import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser
let buddyDir = home.appendingPathComponent(".claude/codebuddy/sessions")
let projectsDir = home.appendingPathComponent(".claude/projects")
let claudeBundleID = "com.anthropic.claudefordesktop"
let sizes: [(String, CGFloat)] = [("Small", 84), ("Medium", 110), ("Large", 140)]
var size: CGFloat { let v = UserDefaults.standard.double(forKey: "size"); return v > 0 ? v : 110 }
let sleepyAfter: Double = 30 * 60 * 1000 // ms with no activity before the robot dozes off

/// Mood art bundled in Contents/Resources (built from desktop/art). Missing art falls back to the drawn blob.
let art: [String: NSImage] = Dictionary(uniqueKeysWithValues:
    ["happy", "nudge", "worried", "calm", "busy", "blink", "sleepy"].compactMap { name in
        Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:)).map { (name, $0) }
    })

struct Step: Decodable { let text: String; let why: String }
struct BuddySession: Decodable {
    let id: String, cwd: String, project: String, branch: String
    let status: String, mood: String, steps: [Step], updatedAt: Double
}
struct Transcript { let id: String; let cwd: String; let title: String; let modified: Date }

// MARK: - Data

func loadBuddySessions() -> [BuddySession] {
    let files = (try? FileManager.default.contentsOfDirectory(at: buddyDir, includingPropertiesForKeys: nil)) ?? []
    let dayAgo = Date().timeIntervalSince1970 * 1000 - 86_400_000
    return files.filter { $0.pathExtension == "json" }
        .compactMap { try? JSONDecoder().decode(BuddySession.self, from: Data(contentsOf: $0)) }
        .filter { $0.status != "ended" && $0.updatedAt > dayAgo }
        .sorted { $0.updatedAt > $1.updatedAt }
}

/// Most recent transcripts. Reads only the head of each file for cwd and first prompt.
func loadTranscripts(limit: Int = 15) -> [Transcript] {
    let fm = FileManager.default
    var all: [(URL, Date)] = []
    for dir in (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? [] {
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where f.pathExtension == "jsonl" {
            let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            all.append((f, d))
        }
    }
    return all.sorted { $0.1 > $1.1 }.prefix(limit).map { url, date in
        var cwd = "", title = ""
        if let h = FileHandle(forReadingAtPath: url.path) {
            let head = String(decoding: h.readData(ofLength: 256 * 1024), as: UTF8.self)
            try? h.close()
            for line in head.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
                if title.isEmpty, obj["type"] as? String == "user", obj["isMeta"] as? Bool != true,
                   let msg = obj["message"] as? [String: Any], let text = msg["content"] as? String,
                   !text.hasPrefix("<") { title = text }
                if !cwd.isEmpty && !title.isEmpty { break }
            }
        }
        let oneLine = title.replacingOccurrences(of: "\n", with: " ")
        return Transcript(id: url.deletingPathExtension().lastPathComponent, cwd: cwd,
                          title: oneLine.isEmpty ? "(no prompt yet)" : String(oneLine.prefix(60)), modified: date)
    }
}

func isClaudeRunning() -> Bool {
    if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == claudeBundleID }) { return true }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "claude"]
    p.standardOutput = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}

// MARK: - Character

final class BuddyView: NSView {
    var mood = "calm" { didSet { needsDisplay = true } }
    var phase: CGFloat = 0
    var isBlinking = false
    var onClick: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    private var dragStart: NSPoint?
    private var didDrag = false

    override var isFlipped: Bool { false }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
    override func mouseDown(with e: NSEvent) { dragStart = e.locationInWindow; didDrag = false }
    override func mouseDragged(with e: NSEvent) {
        guard let start = dragStart, let w = window else { return }
        let now = e.locationInWindow
        if !didDrag && hypot(now.x - start.x, now.y - start.y) < 3 { return }
        didDrag = true
        w.setFrameOrigin(NSPoint(x: w.frame.origin.x + now.x - start.x, y: w.frame.origin.y + now.y - start.y))
    }
    override func mouseUp(with e: NSEvent) {
        if didDrag { UserDefaults.standard.set(NSStringFromPoint(window!.frame.origin), forKey: "origin") }
        else { onClick?(e) }
        dragStart = nil
    }

    var color: NSColor {
        switch mood {
        case "worried": return .systemRed
        case "nudge": return .systemOrange
        case "happy": return .systemGreen
        case "busy": return .systemPurple
        default: return .systemTeal
        }
    }

    override func draw(_ dirty: NSRect) {
        let bob = sin(phase) * 3
        // Blink only has a matching frame for the calm pose.
        let frame = (isBlinking && (mood == "calm")) ? "blink" : mood
        if let img = art[frame] ?? art["calm"] {
            NSColor.black.withAlphaComponent(0.16).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width * 0.28, y: 2, width: bounds.width * 0.44, height: bounds.height * 0.06)).fill()
            img.draw(in: bounds.insetBy(dx: 2, dy: 2).offsetBy(dx: 0, dy: bob + 2), from: .zero, operation: .sourceOver, fraction: 1)
            return
        }
        let body = NSRect(x: 10, y: 8 + bob, width: bounds.width - 20, height: bounds.height - 22)
        // shadow
        NSColor.black.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: 18, y: 2, width: bounds.width - 36, height: 7)).fill()
        // body
        let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.45, yRadius: body.height * 0.5)
        NSGradient(starting: color.blended(withFraction: 0.35, of: .white)!, ending: color)!.draw(in: path, angle: -90)
        NSColor.black.withAlphaComponent(0.25).setStroke(); path.lineWidth = 1.5; path.stroke()
        // eyes
        let eyeY = body.midY + 4, lookUp: CGFloat = mood == "busy" ? 3 : 0
        for dx in [-11.0, 11.0] {
            let c = NSPoint(x: body.midX + dx, y: eyeY)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 7, y: c.y - (isBlinking ? 1 : 8), width: 14, height: isBlinking ? 2 : 16)).fill()
            if !isBlinking {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 3.5, y: c.y - 4 + lookUp, width: 7, height: 8)).fill()
            }
        }
        // mouth
        let m = NSBezierPath(); m.lineWidth = 2.5; m.lineCapStyle = .round
        let mx = body.midX, my = body.midY - 12
        switch mood {
        case "happy": m.move(to: NSPoint(x: mx - 9, y: my + 2)); m.curve(to: NSPoint(x: mx + 9, y: my + 2), controlPoint1: NSPoint(x: mx - 4, y: my - 6), controlPoint2: NSPoint(x: mx + 4, y: my - 6))
        case "worried": m.move(to: NSPoint(x: mx - 8, y: my - 3)); m.curve(to: NSPoint(x: mx + 8, y: my - 3), controlPoint1: NSPoint(x: mx - 3, y: my + 4), controlPoint2: NSPoint(x: mx + 3, y: my + 4))
        case "nudge": m.appendOval(in: NSRect(x: mx - 4, y: my - 4, width: 8, height: 8))
        default: m.move(to: NSPoint(x: mx - 7, y: my)); m.line(to: NSPoint(x: mx + 7, y: my))
        }
        NSColor.black.withAlphaComponent(0.75).setStroke(); m.stroke()
    }
}

final class Bubble: NSPanel {
    let label = NSTextField(wrappingLabelWithString: "")
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false; backgroundColor = .clear; level = .floating; hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; ignoresMouseEvents = true
        let box = NSVisualEffectView(); box.material = .popover; box.state = .active
        box.wantsLayer = true; box.layer?.cornerRadius = 12
        label.font = .systemFont(ofSize: 13); label.maximumNumberOfLines = 4
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 236),
        ])
        contentView = box
    }
    func show(_ text: String, near f: NSRect) {
        label.stringValue = text
        let fit = contentView!.fittingSize
        let x = f.minX - fit.width - 6 > (screen?.visibleFrame.minX ?? 0) ? f.minX - fit.width - 6 : f.maxX + 6
        setFrame(NSRect(x: x, y: f.midY - fit.height / 2, width: fit.width, height: fit.height), display: true)
        orderFront(nil)
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let view = BuddyView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    let bubble = Bubble()
    var sessions: [BuddySession] = []
    var hiddenUntil = Date.distantPast
    var lastMood = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
        let saved = UserDefaults.standard.string(forKey: "origin").map(NSPointFromString)
        let vf = NSScreen.main!.visibleFrame
        panel.setFrameOrigin(saved ?? NSPoint(x: vf.maxX - size - 24, y: vf.minY + 24))
        view.setAccessibilityRole(.button)
        view.onClick = { [weak self] e in self?.showMenu(e) }
        view.onHover = { [weak self] inside in
            guard let self else { return }
            if inside, let s = self.sessions.first, let step = s.steps.first {
                self.bubble.show("\(s.project): \(step.text)\n\(step.why)", near: self.panel.frame)
            } else { self.bubble.orderOut(nil) }
        }
        tick()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.animate() }
        Timer.scheduledTimer(withTimeInterval: 4.5, repeats: true) { [weak self] _ in self?.blink() }
    }

    func tick() {
        let visible = Date() > hiddenUntil && isClaudeRunning()
        if visible != panel.isVisible { visible ? panel.orderFrontRegardless() : panel.orderOut(nil) }
        if !visible { bubble.orderOut(nil) }
        sessions = loadBuddySessions()
        let s = sessions.first
        let idleFor = Date().timeIntervalSince1970 * 1000 - (s?.updatedAt ?? 0)
        view.mood = s == nil || (s!.status == "idle" && idleFor > sleepyAfter) ? "sleepy" : s!.mood
        view.setAccessibilityLabel(s.map { "Code buddy, \($0.project): \($0.steps.first?.text ?? "idle")" } ?? "Code buddy, dozing. No active session.")
        // Speak up briefly when the advice changes.
        let key = "\(s?.id ?? "")|\(s?.steps.first?.text ?? "")"
        if !lastMood.isEmpty, key != lastMood, let s, s.status == "idle", let step = s.steps.first, panel.isVisible {
            bubble.show("\(s.project): \(step.text)", near: panel.frame)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.bubble.orderOut(nil) }
        }
        lastMood = key
    }

    func animate() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard panel.isVisible, !reduce else { if view.phase != 0 { view.phase = 0; view.needsDisplay = true }; return }
        view.phase += view.mood == "busy" ? 0.25 : 0.06
        view.needsDisplay = true
    }

    func blink() {
        view.isBlinking = true; view.needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.view.isBlinking = false; self?.view.needsDisplay = true }
    }

    // MARK: menu

    func showMenu(_ e: NSEvent) {
        bubble.orderOut(nil)
        let menu = NSMenu()
        if let s = sessions.first {
            menu.addItem(header("\(s.project) · \(s.branch.isEmpty ? "no git" : s.branch)"))
            for (i, step) in s.steps.enumerated() {
                let item = NSMenuItem(title: "\(i + 1). \(step.text)", action: nil, keyEquivalent: "")
                item.toolTip = step.why
                menu.addItem(item)
            }
        } else {
            menu.addItem(header("nothing going on right now"))
        }
        menu.addItem(.separator())
        menu.addItem(action("Sessions waiting on you", #selector(openURL(_:)), "claude://code/needs-input"))
        menu.addItem(action("New Claude Code session", #selector(openURL(_:)), "claude://code/new"))
        menu.addItem(.separator())

        let live = Set(sessions.map(\.id))
        if !sessions.isEmpty {
            menu.addItem(header("Live"))
            for s in sessions { menu.addItem(sessionItem(id: s.id, cwd: s.cwd, title: "\(s.status == "busy" ? "● " : "")\(s.project) — \(s.steps.first?.text ?? "")")) }
        }
        menu.addItem(header("Recent"))
        let fmt = RelativeDateTimeFormatter(); fmt.unitsStyle = .short
        for t in loadTranscripts() where !live.contains(t.id) {
            let project = (t.cwd as NSString).lastPathComponent
            menu.addItem(sessionItem(id: t.id, cwd: t.cwd, title: "\(project) · \(t.title) · \(fmt.localizedString(for: t.modified, relativeTo: Date()))"))
        }
        menu.addItem(.separator())
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (name, pts) in sizes {
            let item = action(name, #selector(setSize(_:)), pts)
            item.state = pts == size ? .on : .off
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        menu.addItem(action("Hide for 1 hour", #selector(hideHour), nil))
        menu.addItem(action("Quit CodeBuddy", #selector(NSApplication.terminate(_:)), nil))
        menu.popUp(positioning: nil, at: e.locationInWindow, in: view)
    }

    func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        item.isEnabled = false
        return item
    }

    func action(_ title: String, _ sel: Selector, _ payload: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = sel == #selector(NSApplication.terminate(_:)) ? NSApp : self
        item.representedObject = payload
        return item
    }

    func sessionItem(id: String, cwd: String, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(action("Open in Claude app", #selector(openURL(_:)), "claude://resume?session=\(id)"))
        sub.addItem(action("Resume in Terminal", #selector(resumeInTerminal(_:)), [id, cwd]))
        sub.addItem(action("Copy resume command", #selector(copyResume(_:)), [id, cwd]))
        item.submenu = sub
        return item
    }

    @objc func openURL(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    func resumeCommand(_ sender: NSMenuItem) -> String? {
        guard let p = sender.representedObject as? [String], p.count == 2 else { return nil }
        let quoted = "'" + p[1].replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \(quoted) && claude --resume \(p[0])"
    }

    @objc func resumeInTerminal(_ sender: NSMenuItem) {
        guard let cmd = resumeCommand(sender) else { return }
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\"\ntell application \"Terminal\" to activate"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }

    @objc func copyResume(_ sender: NSMenuItem) {
        guard let cmd = resumeCommand(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    @objc func setSize(_ sender: NSMenuItem) {
        guard let pts = sender.representedObject as? CGFloat else { return }
        UserDefaults.standard.set(Double(pts), forKey: "size")
        let f = panel.frame
        panel.setFrame(NSRect(x: f.maxX - pts, y: f.minY, width: pts, height: pts), display: true)
        view.frame = NSRect(x: 0, y: 0, width: pts, height: pts)
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "origin")
    }

    @objc func hideHour() {
        hiddenUntil = Date().addingTimeInterval(3600)
        panel.orderOut(nil); bubble.orderOut(nil)
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
