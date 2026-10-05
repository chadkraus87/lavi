// CodeBuddy: a floating desktop character that mirrors your Claude Code sessions.
// Reads ~/.claude/codebuddy/sessions/*.json (written by the codebuddy mod) and
// ~/.claude/projects/*/*.jsonl (Claude Code transcripts). No dependencies.
import AppKit
import AVFoundation

let home = FileManager.default.homeDirectoryForCurrentUser
let buddyDir = home.appendingPathComponent(".claude/codebuddy/sessions")
let projectsDir = home.appendingPathComponent(".claude/projects")
let claudeBundleID = "com.anthropic.claudefordesktop"
let sizes: [(String, CGFloat)] = [("Small", 84), ("Medium", 110), ("Large", 140)]
var size: CGFloat { let v = UserDefaults.standard.double(forKey: "size"); return v > 0 ? v : 110 }
/// Idle animation frames (idle_00.png …) bundled beside the moods; played in the calm mood.
let idleFrames: [NSImage] = ((try? FileManager.default.contentsOfDirectory(atPath: Bundle.main.resourcePath ?? "")) ?? [])
    .filter { $0.hasPrefix("idle_") && $0.hasSuffix(".png") }.sorted()
    .compactMap { NSImage(contentsOfFile: (Bundle.main.resourcePath ?? "") + "/" + $0) }
let idleFPS = 8.0 // frames were sampled at 8 fps from the clip
let sleepyAfter: Double = 30 * 60 * 1000 // ms with no activity before the robot dozes off

/// Mood art bundled in Contents/Resources (built from desktop/art). Missing art falls back to the drawn blob.
let art: [String: NSImage] = Dictionary(uniqueKeysWithValues:
    ["happy", "nudge", "worried", "calm", "busy", "blink", "sleepy"].compactMap { name in
        Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:)).map { (name, $0) }
    })

struct Snippet: Decodable { let label: String; let text: String }
struct Step: Decodable { let id: String?; let text: String; let why: String; let snippets: [Snippet]? }
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

/// Talking-face frames (calm pose, mouth half / fully open), swapped by loudness while Lavi speaks.
let talkFrames: [NSImage] = ["talk_a", "talk_b"].compactMap { n in
    Bundle.main.url(forResource: n, withExtension: "png").flatMap(NSImage.init(contentsOf:))
}

// MARK: - Voice

/// Plays Lavi's pre-recorded lines (Contents/Resources/voice-<id>[-n].mp3, made with ElevenLabs).
/// Quiet when muted, in quiet hours (except when you click), or within 20 s of the last line.
final class Voice: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var lastSpoke = Date.distantPast
    let minGap: TimeInterval = 20
    var onFinish: (() -> Void)?

    var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "voiceOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voiceOn") }
    }
    var volume: Float {
        get { UserDefaults.standard.object(forKey: "voiceVolume") as? Float ?? 0.6 }
        set { UserDefaults.standard.set(newValue, forKey: "voiceVolume"); player?.volume = newValue }
    }
    var quietHoursOn: Bool {
        get { UserDefaults.standard.object(forKey: "quietHours") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "quietHours") }
    }
    let quietFrom = 22, quietUntil = 8 // ponytail: fixed 10pm–8am; make it a setting if it ever needs to move
    var isQuietHour: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return quietHoursOn && (h >= quietFrom || h < quietUntil)
    }
    var isSpeaking: Bool { player?.isPlaying ?? false }

    /// All recordings for a line id: "voice-greeting-1.mp3", "voice-greeting-2.mp3" … or just "voice-push.mp3".
    private func files(for id: String) -> [URL] {
        let dir = Bundle.main.resourceURL!
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0 == "voice-\(id).mp3" || ($0.hasPrefix("voice-\(id)-") && $0.hasSuffix(".mp3")) }
            .map { dir.appendingPathComponent($0) }
    }

    /// Says a line. `byYou` (a click) skips quiet hours and the spacing rule, never mute.
    /// `skipGap` skips only the spacing rule (a greeting right after a goodbye on relaunch).
    @discardableResult
    func say(_ id: String, byYou: Bool = false, skipGap: Bool = false) -> TimeInterval? {
        guard isOn else { return nil }
        if !byYou && (isQuietHour || (!skipGap && Date().timeIntervalSince(lastSpoke) < minGap)) { return nil }
        guard let url = files(for: id).randomElement(), let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player?.stop()
        p.volume = volume
        p.isMeteringEnabled = true
        p.delegate = self
        p.play()
        player = p
        lastSpoke = Date()
        return p.duration
    }

    /// Loudness 0…1 of what's playing right now, for the mouth.
    func level() -> Float {
        guard let p = player, p.isPlaying else { return 0 }
        p.updateMeters()
        return max(0, min(1, (p.averagePower(forChannel: 0) + 40) / 40))
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish?() }
}

/// Seconds since you last touched the mouse or keyboard: "are you at the Mac?"
func secondsSinceInput() -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

// MARK: - Character

final class BuddyView: NSView {
    var mood = "calm" { didSet { needsDisplay = true } }
    var phase: CGFloat = 0
    var isBlinking = false
    var idleFrame: Int? // set while the idle animation plays
    var mouth: Int? // 0 closed, 1 half, 2 open: set while Lavi speaks
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
        let idle = mood == "calm" ? idleFrame.map { idleFrames[$0 % idleFrames.count] } : nil
        // While talking: the calm pose with its mouth moving to the audio.
        let talking: NSImage? = mouth.flatMap { m in m == 0 ? art["calm"] : talkFrames.isEmpty ? nil : talkFrames[min(m, talkFrames.count) - 1] }
        if let img = talking ?? idle ?? art[frame] ?? art["calm"] {
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

/// Lavi's speech bubble: a cartoon callout with a bold outline and a tail pointing at Lavi.
final class BubbleView: NSView {
    var headline = NSAttributedString(), detail: NSAttributedString?
    var tailOnRight = true
    static let ink = NSColor(srgbRed: 0.17, green: 0.13, blue: 0.27, alpha: 1) // Lavi's charcoal-purple
    static let pad = NSSize(width: 18, height: 14), tail: CGFloat = 22, margin: CGFloat = 10, maxText: CGFloat = 300

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    func textRects() -> (NSRect, NSRect?) {
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let h = headline.boundingRect(with: NSSize(width: Self.maxText, height: 1000), options: opts).integral
        let d = detail?.boundingRect(with: NSSize(width: Self.maxText, height: 1000), options: opts).integral
        return (h, d)
    }

    /// Window size needed for the current text.
    func fittingSize() -> NSSize {
        let (h, d) = textRects()
        let w = max(h.width, d?.width ?? 0) + Self.pad.width * 2
        let tH = h.height + (d.map { $0.height + 4 } ?? 0) + Self.pad.height * 2
        return NSSize(width: w + Self.tail + Self.margin * 2, height: max(tH, 52) + Self.margin * 2)
    }

    override func draw(_ dirty: NSRect) {
        let body = NSRect(x: Self.margin + (tailOnRight ? 0 : Self.tail), y: Self.margin,
                          width: bounds.width - Self.margin * 2 - Self.tail, height: bounds.height - Self.margin * 2)
        let bubble = NSBezierPath(roundedRect: body, xRadius: 18, yRadius: 18)
        // The tail: a wide curved wedge whose base sits inside the body, so the two read as one shape.
        let ty = body.minY + body.height * 0.4
        let dir: CGFloat = tailOnRight ? 1 : -1
        let edge = tailOnRight ? body.maxX : body.minX
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: edge - dir * 14, y: ty + 13))
        tail.curve(to: NSPoint(x: edge + dir * Self.tail, y: ty - 12),
                   controlPoint1: NSPoint(x: edge + dir * 4, y: ty + 10), controlPoint2: NSPoint(x: edge + dir * 12, y: ty - 2))
        tail.curve(to: NSPoint(x: edge - dir * 14, y: ty - 8),
                   controlPoint1: NSPoint(x: edge + dir * 6, y: ty - 10), controlPoint2: NSPoint(x: edge - dir * 2, y: ty - 9))
        tail.close()
        let shapes = [bubble, tail]

        // 1. soft drop shadow under the whole silhouette
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowBlurRadius = 7
        shadow.set()
        NSColor.white.setFill(); shapes.forEach { $0.fill() }
        NSGraphicsContext.restoreGraphicsState()
        // 2. a double-width stroke on both shapes, then 3. a white fill over both: what's left is a
        //    3pt outline around the union only, with no seam where the tail joins.
        Self.ink.setStroke()
        for p in shapes { p.lineWidth = 6; p.lineJoinStyle = .round; p.stroke() }
        NSColor.white.setFill(); shapes.forEach { $0.fill() }

        let (h, d) = textRects()
        let x = body.minX + Self.pad.width
        var y = body.maxY - Self.pad.height - h.height
        if d == nil { y = body.midY - h.height / 2 }
        headline.draw(with: NSRect(x: x, y: y, width: Self.maxText, height: h.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
        if let detail, let d { detail.draw(with: NSRect(x: x, y: y - 4 - d.height, width: Self.maxText, height: d.height), options: [.usesLineFragmentOrigin, .usesFontLeading]) }
    }
}

final class Bubble: NSPanel {
    let bubbleView = BubbleView()
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 90), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false; backgroundColor = .clear; level = .floating; hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; ignoresMouseEvents = true
        contentView = bubbleView
    }

    /// `text` is the bold headline; `detail` is the smaller line under it.
    func show(_ text: String, detail: String? = nil, near f: NSRect) {
        let para = NSMutableParagraphStyle(); para.lineSpacing = 1
        bubbleView.headline = NSAttributedString(string: text, attributes: [
            .font: BubbleView.rounded(16, .semibold), .foregroundColor: BubbleView.ink, .paragraphStyle: para])
        bubbleView.detail = detail.map { NSAttributedString(string: $0, attributes: [
            .font: BubbleView.rounded(13, .regular), .foregroundColor: BubbleView.ink.withAlphaComponent(0.72), .paragraphStyle: para]) }
        let sz = bubbleView.fittingSize()
        let minX = screen?.visibleFrame.minX ?? NSScreen.main?.visibleFrame.minX ?? 0
        bubbleView.tailOnRight = f.minX - sz.width + 4 > minX // sit left of Lavi when there's room
        let x = bubbleView.tailOnRight ? f.minX - sz.width + 4 : f.maxX - 4
        let y = f.minY + f.height * 0.6 - (sz.height - BubbleView.margin * 2) * 0.4 - BubbleView.margin + 12 // tail tip lands near Lavi's face
        setFrame(NSRect(x: x, y: y, width: sz.width, height: sz.height), display: true)
        bubbleView.needsDisplay = true
        if !isVisible {
            alphaValue = 0
            orderFront(nil)
            NSAnimationContext.runAnimationGroup { $0.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15; animator().alphaValue = 1 }
        }
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
    let voice = Voice()
    var seen: [String: (status: String, top: String, busySince: Date?)] = [:]
    var isFirstTick = true
    var lastGreeting = Date.distantPast
    var holdVisibleUntil = Date.distantPast

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
                self.bubble.show(step.text, detail: "\(s.project) · \(step.why)", near: self.panel.frame)
            } else { self.bubble.orderOut(nil) }
        }
        tick()
        // .common so the animation and mouth keep moving while a menu is open.
        for (interval, f) in [(2.0, { [weak self] in self?.tick() }), (1.0 / 30, { [weak self] in self?.animate() }), (4.5, { [weak self] in self?.blink() })] as [(Double, () -> Void)] {
            RunLoop.main.add(Timer(timeInterval: interval, repeats: true) { _ in f() }, forMode: .common)
        }
        voice.onFinish = { [weak self] in self?.view.mouth = nil; self?.view.needsDisplay = true }
        // Hello again: Claude.app (re)opened. Show up right away and greet, with a bubble too.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == claudeBundleID else { return }
            self.tick()
            guard self.panel.isVisible else { return } // hidden for an hour, etc.
            self.lastGreeting = Date() // so a new session file doesn't greet twice
            if self.voice.say("greeting", skipGap: true) != nil {
                self.bubble.show("hey, welcome back!", detail: "lavi here. click me any time for what's next.", near: self.panel.frame)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.bubble.orderOut(nil) }
            }
        }
        // Goodbye: macOS can't delay another app's quit, so Lavi says it as Claude closes and lingers for the clip.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == claudeBundleID,
                  self.panel.isVisible, let secs = self.voice.say("goodbye") else { return }
            self.holdVisibleUntil = Date().addingTimeInterval(secs + 0.5)
        }
    }

    func tick() {
        let visible = Date() < holdVisibleUntil || (Date() > hiddenUntil && isClaudeRunning())
        if visible != panel.isVisible { visible ? panel.orderFrontRegardless() : panel.orderOut(nil) }
        if !visible { bubble.orderOut(nil) }
        sessions = loadBuddySessions()
        let s = sessions.first
        let idleFor = Date().timeIntervalSince1970 * 1000 - (s?.updatedAt ?? 0)
        view.mood = s == nil || (s!.status == "idle" && idleFor > sleepyAfter) ? "sleepy" : s!.mood
        view.setAccessibilityLabel(s.map { "Lavi, \($0.project): \($0.steps.first?.text ?? "idle")" } ?? "Lavi, dozing. No active session.")
        // Speak up briefly when the advice changes.
        let key = "\(s?.id ?? "")|\(s?.steps.first?.text ?? "")"
        if !lastMood.isEmpty, key != lastMood, let s, s.status == "idle", let step = s.steps.first, panel.isVisible {
            bubble.show(step.text, detail: s.project, near: panel.frame)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.bubble.orderOut(nil) }
        }
        lastMood = key
        if panel.isVisible { speakIfSomethingChanged() }
        isFirstTick = false
    }

    /// Greeting, "done" and advice lines, decided from how the session files changed since the last tick.
    func speakIfSomethingChanged() {
        let now = Date()
        for s in sessions {
            let top = s.steps.first?.id ?? ""
            let before = seen[s.id]
            var busySince = before?.busySince
            if s.status == "busy" && busySince == nil { busySince = now }
            defer { seen[s.id] = (s.status, top, s.status == "busy" ? busySince : nil) }
            if isFirstTick { continue } // don't chatter about sessions that were already open

            if before == nil {
                if now.timeIntervalSince(lastGreeting) > 600 { lastGreeting = now; voice.say("greeting") }
            } else if before!.status == "busy" && s.status == "idle",
                      let start = before!.busySince, now.timeIntervalSince(start) >= 180, secondsSinceInput() < 120 {
                voice.say("done") // a long task finished while you're here
            } else if s.status == "idle" && top != before!.top && !top.isEmpty && s.id == sessions.first?.id {
                voice.say("advice-\(top)")
            }
        }
    }

    func animate() {
        if voice.isSpeaking {
            let l = voice.level()
            let m = l < 0.35 ? 0 : l < 0.6 ? 1 : 2
            if view.mouth != m { view.mouth = m; view.needsDisplay = true }
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard panel.isVisible, !reduce else { if view.phase != 0 || view.idleFrame != nil { view.phase = 0; view.idleFrame = nil; view.needsDisplay = true }; return }
        view.phase += view.mood == "busy" ? 0.25 : 0.06
        // The idle clip has its own motion (and blink), so it replaces the bob in the calm mood.
        if view.mood == "calm" && !idleFrames.isEmpty {
            view.phase = 0
            // Ping-pong: forward through the clip, then back, so the loop never jumps.
            let n = idleFrames.count, cycle = max(1, 2 * n - 2)
            let t = Int(Date().timeIntervalSince1970 * idleFPS) % cycle
            view.idleFrame = t < n ? t : cycle - t
        } else {
            view.idleFrame = nil
        }
        view.needsDisplay = true
    }

    func blink() {
        if view.idleFrame != nil { return } // the idle clip blinks on its own
        view.isBlinking = true; view.needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.view.isBlinking = false; self?.view.needsDisplay = true }
    }

    // MARK: menu

    func showMenu(_ e: NSEvent) {
        bubble.orderOut(nil)
        if let top = sessions.first?.steps.first?.id, sessions.first?.status == "idle", view.mood != "sleepy" {
            voice.say(top == "next" ? "allgood" : "advice-\(top)", byYou: true)
        } else {
            voice.say("allgood", byYou: true)
        }
        let menu = NSMenu()
        if let s = sessions.first {
            menu.addItem(header("\(s.project) · \(s.branch.isEmpty ? "no git" : s.branch)"))
            for (i, step) in s.steps.enumerated() {
                let item = NSMenuItem(title: "\(i + 1). \(step.text)", action: nil, keyEquivalent: "")
                item.toolTip = step.why
                // Ready-to-send prompts: copied, so you paste them into the session and press Enter yourself.
                if let snippets = step.snippets, !snippets.isEmpty {
                    let sub = NSMenu()
                    sub.addItem(header("copy a prompt, then paste it in Claude"))
                    for sn in snippets {
                        let it = action(sn.label, #selector(copySnippet(_:)), sn.text)
                        it.toolTip = sn.text
                        sub.addItem(it)
                    }
                    item.submenu = sub
                }
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
        let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let vm = NSMenu()
        let onItem = action("Lavi talks", #selector(toggleVoice), nil); onItem.state = voice.isOn ? .on : .off; vm.addItem(onItem)
        for (name, v) in [("Volume: low", Float(0.3)), ("Volume: medium", 0.6), ("Volume: high", 1.0)] as [(String, Float)] {
            let it = action(name, #selector(setVolume(_:)), v); it.state = abs(voice.volume - v) < 0.01 ? .on : .off; vm.addItem(it)
        }
        let qh = action("Quiet 10pm–8am", #selector(toggleQuietHours), nil); qh.state = voice.quietHoursOn ? .on : .off; vm.addItem(qh)
        voiceItem.submenu = vm
        menu.addItem(voiceItem)
        menu.addItem(action("Quit Lavi", #selector(NSApplication.terminate(_:)), nil))
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

    @objc func copySnippet(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        bubble.show("copied!", detail: "paste it into Claude (⌘V), tweak it, then hit enter.", near: panel.frame)
        voice.say("copied", byYou: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.bubble.orderOut(nil) }
    }

    @objc func copyResume(_ sender: NSMenuItem) {
        guard let cmd = resumeCommand(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    @objc func toggleVoice() { voice.isOn.toggle() }
    @objc func toggleQuietHours() { voice.quietHoursOn.toggle() }
    @objc func setVolume(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Float { voice.volume = v; voice.say("allgood", byYou: true) }
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
