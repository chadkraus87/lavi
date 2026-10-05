// CodeBuddy: a floating desktop character that mirrors your Claude Code sessions.
// Reads ~/.claude/codebuddy/sessions/*.json (written by the codebuddy mod) and
// ~/.claude/projects/*/*.jsonl (Claude Code transcripts). No dependencies.
import AppKit
import AVFoundation
import EventKit

let home = FileManager.default.homeDirectoryForCurrentUser
let buddyDir = home.appendingPathComponent(".claude/codebuddy/sessions")
let projectsDir = home.appendingPathComponent(".claude/projects")
let claudeBundleID = "com.anthropic.claudefordesktop"
let sizes: [(String, CGFloat)] = [("Small", 84), ("Medium", 110), ("Large", 140), ("XL", 180), ("XXL", 240)]
var size: CGFloat { let v = UserDefaults.standard.double(forKey: "size"); return v > 0 ? v : 110 }
/// Idle animations per mood (idle-<mood>_00.png …), made with desktop/tools/idle_frames.py.
let idleSets: [String: [NSImage]] = {
    let dir = Bundle.main.resourcePath ?? ""
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("idle-") && $0.hasSuffix(".png") }.sorted()
    return Dictionary(grouping: names) { String($0.dropFirst(5).prefix { $0 != "_" }) }
        .mapValues { $0.compactMap { NSImage(contentsOfFile: dir + "/" + $0) } }
}()
let idleFPS = 8.0 // frames were sampled at 8 fps from the clip
let sayFile = home.appendingPathComponent(".claude/codebuddy/say.json")
let qaFile = home.appendingPathComponent(".claude/codebuddy/qa-prompt.txt")
let openSettingsFile = home.appendingPathComponent(".claude/codebuddy/open-settings")
let readStatusFile = home.appendingPathComponent(".claude/codebuddy/read-aloud-status.txt") // shown by /lavi doctor
let fillFile = home.appendingPathComponent(".claude/codebuddy/fill.json")    // prompt for a session's message box (the mod picks it up)
let fillAckFile = home.appendingPathComponent(".claude/codebuddy/fill-ack.json") // …and its answer
let sleepyAfter: Double = 30 * 60 * 1000 // ms with no activity before the robot dozes off

/// Mood art bundled in Contents/Resources (built from desktop/art). Missing art falls back to the drawn blob.
let art: [String: NSImage] = Dictionary(uniqueKeysWithValues:
    ["happy", "nudge", "worried", "calm", "busy", "blink", "sleepy"].compactMap { name in
        Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:)).map { (name, $0) }
    })

struct Snippet: Decodable { let label: String; let text: String }
struct Step: Decodable { let id: String?; let text: String; let why: String; let snippets: [Snippet]? }
struct Celebrate: Decodable { let kind: String; let at: Double }
struct Waiting: Decodable { let kind: String; let since: Double } // "question" or "approval"
struct BuddySession: Decodable {
    let id: String, cwd: String, project: String, branch: String
    let status: String, mood: String, steps: [Step], updatedAt: Double
    let quiet: Bool?, celebrate: Celebrate?, appId: String?, waiting: Waiting?
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

/// Housekeeping: drop session files untouched for 7 days, and ended ones after a day.
func pruneSessions() {
    let fm = FileManager.default
    for f in (try? fm.contentsOfDirectory(at: buddyDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "json" {
        let age = Date().timeIntervalSince((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date())
        let ended = age > 86_400 && ((try? JSONDecoder().decode(BuddySession.self, from: Data(contentsOf: f)))?.status == "ended")
        if age > 7 * 86_400 || ended { try? fm.removeItem(at: f) }
    }
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

/// The desktop app's own session id ("local_…"), from the session file. Same shape the app's URL handler accepts.
func isAppSessionID(_ s: String) -> Bool { s.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil }

/// CLI session id → desktop app session id, for every session Lavi has seen (including ended ones).
func appSessionIDs() -> [String: String] {
    let files = (try? FileManager.default.contentsOfDirectory(at: buddyDir, includingPropertiesForKeys: nil)) ?? []
    var map: [String: String] = [:]
    for f in files where f.pathExtension == "json" {
        if let s = try? JSONDecoder().decode(BuddySession.self, from: Data(contentsOf: f)), let a = s.appId, isAppSessionID(a) { map[s.id] = a }
    }
    return map
}

/// A Claude Code session id: a UUID, nothing else.
func isSessionID(_ s: String) -> Bool {
    s.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
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
    private var stream: StreamPlayer?
    private var lastSpoke = Date.distantPast
    let minGap: TimeInterval = 20
    var onFinish: (() -> Void)?

    var isOn: Bool {
        get { Prefs.voiceOn }
        set { Prefs.d.set(newValue, forKey: "voiceOn") }
    }
    var volume: Float {
        get { Prefs.volume }
        set { Prefs.d.set(Double(newValue), forKey: "voiceVolume"); player?.volume = newValue; stream?.volume = newValue }
    }
    var quietHoursOn: Bool {
        get { Prefs.quietHours }
        set { Prefs.d.set(newValue, forKey: "quietHours") }
    }
    let quietFrom = 22, quietUntil = 8 // ponytail: fixed 10pm–8am; make it a setting if it ever needs to move
    /// Quiet hours, a calendar event, or a Focus mode.
    var isQuietNow: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return (quietHoursOn && (h >= quietFrom || h < quietUntil)) || Quiet.inMeeting || Quiet.inFocus
    }
    var isSpeaking: Bool { (player?.isPlaying ?? false) || (stream?.isPlaying ?? false) }

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
        if !byYou && (isQuietNow || (!skipGap && Date().timeIntervalSince(lastSpoke) < minGap)) { return nil }
        guard let url = files(for: id).randomElement(), let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        return start(p)
    }

    /// A player for audio you asked for (a read-aloud answer) that plays as it streams in: mute still applies, nothing else.
    func beginStream() -> StreamPlayer? {
        guard isOn, let s = StreamPlayer(volume: volume) else { return nil }
        player?.stop(); stream?.stop()
        s.onFinish = { [weak self] in self?.onFinish?() }
        stream = s
        lastSpoke = Date()
        return s
    }

    private func start(_ p: AVAudioPlayer) -> TimeInterval {
        player?.stop(); stream?.stop()
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
        if let s = stream, s.isPlaying { return s.level() }
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
    var idleImage: NSImage? // the current idle-animation frame for this mood, if it has one
    var bounceStart: Date? // a little hop: after a drag, or when celebrating
    var bounceAmp: CGFloat = 6
    var onDragEnd: (() -> Void)?
    var mouth: Int? // 0 closed, 1 half, 2 open: set while Lavi speaks
    var onClick: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    /// Sessions blocked on you: drawn as a count badge on his head.
    var badge = 0 { didSet { if badge != oldValue { needsDisplay = true } } }
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
        if didDrag { onDragEnd?(); hop(6) }
        else { onClick?(e) }
        dragStart = nil
    }

    func hop(_ amp: CGFloat) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        bounceAmp = amp; bounceStart = Date()
    }

    /// A damped bounce: quick hops that settle within about 0.8 s.
    var bounceOffset: CGFloat {
        guard let t0 = bounceStart else { return 0 }
        let t = Date().timeIntervalSince(t0)
        if t > 0.8 { return 0 }
        return bounceAmp * CGFloat(exp(-5 * t) * abs(sin(t * 14)))
    }

    /// An ink circle with a white count and a lavender ring, top right, bobbing with him.
    func drawBadge(_ bob: CGFloat) {
        guard badge > 0 else { return }
        let d = max(20, bounds.width * 0.17)
        let r = NSRect(x: bounds.maxX - d - 4, y: bounds.maxY - d - 6 + bob, width: d, height: d)
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: -2, dy: -2)); Theme.lavender.setFill(); ring.fill()
        Theme.ink.setFill(); NSBezierPath(ovalIn: r).fill()
        let t = NSAttributedString(string: badge > 9 ? "9+" : "\(badge)", attributes: [.font: BubbleView.rounded(d * 0.55, .bold), .foregroundColor: NSColor.white])
        let ts = t.size()
        t.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2))
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
        let bob = sin(phase) * 3 + bounceOffset
        // Blink only has a matching frame for the calm pose.
        let frame = (isBlinking && (mood == "calm")) ? "blink" : mood
        let idle = idleImage
        // While talking: the calm pose with its mouth moving to the audio.
        let talking: NSImage? = mouth.flatMap { m in m == 0 ? art["calm"] : talkFrames.isEmpty ? nil : talkFrames[min(m, talkFrames.count) - 1] }
        if let img = talking ?? idle ?? art[frame] ?? art["calm"] {
            NSColor.black.withAlphaComponent(0.16).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width * 0.28, y: 2, width: bounds.width * 0.44, height: bounds.height * 0.06)).fill()
            img.draw(in: bounds.insetBy(dx: 2, dy: 2).offsetBy(dx: 0, dy: bob + 2), from: .zero, operation: .sourceOver, fraction: 1)
            drawBadge(bob)
            return
        }
        defer { drawBadge(bob) }
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
    /// "working in <folder> · <branch>", drawn as a lilac pill at the bottom.
    var place: NSAttributedString?
    var tailOnRight = true
    static let ink = Theme.ink
    static let pillPad = NSSize(width: 9, height: 4), pillGap: CGFloat = 9
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

    /// The pill's size, text included.
    func pillSize() -> NSSize? {
        guard let place else { return nil }
        let r = place.boundingRect(with: NSSize(width: Self.maxText - Self.pillPad.width * 2, height: 100), options: [.usesLineFragmentOrigin, .usesFontLeading]).integral
        return NSSize(width: r.width + Self.pillPad.width * 2, height: r.height + Self.pillPad.height * 2)
    }

    /// Window size needed for the current text.
    func fittingSize() -> NSSize {
        let (h, d) = textRects()
        let pill = pillSize()
        let w = max(h.width, d?.width ?? 0, pill?.width ?? 0) + Self.pad.width * 2
        let tH = h.height + (d.map { $0.height + 4 } ?? 0) + (pill.map { $0.height + Self.pillGap } ?? 0) + Self.pad.height * 2
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
        if d == nil && place == nil { y = body.midY - h.height / 2 }
        if let place, let ps = pillSize() {
            let pill = NSRect(x: x, y: body.minY + Self.pad.height, width: ps.width, height: ps.height)
            Theme.lilac.setFill(); NSBezierPath(roundedRect: pill, xRadius: ps.height / 2, yRadius: ps.height / 2).fill()
            place.draw(with: pill.insetBy(dx: Self.pillPad.width, dy: Self.pillPad.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
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
        hidesOnDeactivate = false // panels hide when their app isn't active; Lavi is almost never the active app
        contentView = bubbleView
    }

    private var generation = 0

    /// Shows the bubble, then hides it after `seconds`, unless a newer bubble replaced it by then.
    func flash(_ text: String, detail: String? = nil, place: (String, String)? = nil, near f: NSRect, for seconds: TimeInterval) {
        show(text, detail: detail, place: place, near: f)
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.generation == mine { self?.orderOut(nil) }
        }
    }

    /// `text` is the bold headline; `detail` is the smaller line under it; `place` (project, branch) is the session it's about.
    func show(_ text: String, detail: String? = nil, place: (String, String)? = nil, near f: NSRect) {
        generation += 1
        let para = NSMutableParagraphStyle(); para.lineSpacing = 1
        bubbleView.headline = NSAttributedString(string: text, attributes: [
            .font: BubbleView.rounded(16, .semibold), .foregroundColor: BubbleView.ink, .paragraphStyle: para])
        bubbleView.detail = detail.map { NSAttributedString(string: $0, attributes: [
            .font: BubbleView.rounded(13, .regular), .foregroundColor: BubbleView.ink.withAlphaComponent(0.72), .paragraphStyle: para]) }
        bubbleView.place = place.map { Self.placeText(project: $0.0, branch: $0.1) }
        let sz = bubbleView.fittingSize()
        let minX = screen?.visibleFrame.minX ?? NSScreen.main?.visibleFrame.minX ?? 0
        bubbleView.tailOnRight = f.minX - sz.width + 4 > minX // sit left of Lavi when there's room
        let x = bubbleView.tailOnRight ? f.minX - sz.width + 4 : f.maxX - 4
        let y = f.minY + f.height * 0.6 - (sz.height - BubbleView.margin * 2) * 0.4 - BubbleView.margin + 12 // tail tip lands near Lavi's face
        setFrame(NSRect(x: x, y: y, width: sz.width, height: sz.height), display: true)
        bubbleView.needsDisplay = true
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15; animator().alphaValue = 1 }
        }
    }
}

extension Bubble {
    /// 📁 working in **codebuddy** · ⎇ master
    static func placeText(project: String, branch: String) -> NSAttributedString {
        let font = BubbleView.rounded(11, .medium), bold = BubbleView.rounded(11, .bold)
        let ink: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.ink]
        func icon(_ name: String) -> NSAttributedString {
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [Theme.ink]))) else { return NSAttributedString() }
            let a = NSTextAttachment(); a.image = img
            a.bounds = NSRect(x: 0, y: -1, width: img.size.width, height: img.size.height)
            return NSAttributedString(attachment: a)
        }
        let short = { (s: String) in s.count > 26 ? String(s.prefix(24)) + "…" : s }
        let out = NSMutableAttributedString()
        out.append(icon("folder.fill")); out.append(NSAttributedString(string: " working in ", attributes: ink))
        out.append(NSAttributedString(string: short(project), attributes: [.font: bold, .foregroundColor: Theme.ink]))
        out.append(NSAttributedString(string: "  ·  ", attributes: [.font: font, .foregroundColor: Theme.ink.withAlphaComponent(0.5)]))
        out.append(icon("arrow.triangle.branch")); out.append(NSAttributedString(string: " " + (branch.isEmpty ? "no git" : short(branch)), attributes: ink))
        return out
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let view = BuddyView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    let bubble = Bubble()
    let menuPanel = MenuPanel()
    var sessions: [BuddySession] = []
    var hiddenUntil = Date.distantPast
    var lastMood = ""
    let voice = Voice()
    var seen: [String: (status: String, top: String, busySince: Date?)] = [:]
    var isFirstTick = true
    var lastGreeting = Date.distantPast
    var holdVisibleUntil = Date.distantPast
    let hotkey = Hotkey()
    var seenCelebrate: [String: Double] = [:]
    var celebrateUntil = Date.distantPast
    var lastSayAt: Double = 0 // newest read-aloud request already handled
    var lastSynthesis = Date.distantPast
    var activeSince: Date? // steady work, for break nudges
    var lastBreakNudge = Date()
    var checkIn: [ProjectState] = [] // last morning check-in
    var ticks = 0
    var appIDs: [String: String] = [:] // refreshed each time the menu opens
    var seenWaiting: Set<String> = [] // "<session>|<since>" already announced
    var lastCheckInAt = Date.distantPast
    var fillTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
        let saved = UserDefaults.standard.string(forKey: "origin").map(NSPointFromString)
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(saved ?? NSPoint(x: vf.maxX - size - 24, y: vf.minY + 24))
        clampOnScreen()
        view.onDragEnd = { [weak self] in self?.clampOnScreen() }
        pruneSessions()
        // Session files and say.json (your last Ask Lavi answer) are yours alone: lock the folder to your account.
        let dataDir = buddyDir.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: buddyDir, withIntermediateDirectories: true)
        for d in [dataDir, buddyDir] { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path) }
        // Displays changed (monitor unplugged, resolution): make sure Lavi is still somewhere you can see.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.clampOnScreen() }
        // Settings window edits land in UserDefaults; apply size and hotkey changes live.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.applySettings() }
        installEditMenu()
        // Requests already in say.json at launch are old: don't replay them. (A missing file means none, so the first press counts.)
        lastSayAt = ((try? Data(contentsOf: sayFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["at"] as? Double) ?? 0
        Hotkey.onPress = { [weak self] in self?.showMenu() }
        applySettings()
        // `open ~/Applications/CodeBuddy.app --args --settings` opens Settings straight away.
        if CommandLine.arguments.contains("--settings") { DispatchQueue.main.async { SettingsWindow.show() } }
        view.setAccessibilityRole(.button)
        view.onClick = { [weak self] _ in self?.showMenu() }
        view.onHover = { [weak self] inside in
            guard let self else { return }
            if inside, !self.menuPanel.isVisible, let s = self.sessions.first, let step = s.steps.first {
                self.bubble.show(step.text, detail: step.why, place: (s.project, s.branch), near: self.panel.frame)
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
            if self.morningCheckIn() { return }
            if self.voice.say("greeting", skipGap: true) != nil {
                self.bubble.flash("hey, welcome back!", detail: "lavi here. click me any time for what's next.", near: self.panel.frame, for: 5)
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
        if !visible { bubble.orderOut(nil); menuPanel.close() }
        sessions = loadBuddySessions()
        let s = sessions.first
        let idleFor = Date().timeIntervalSince1970 * 1000 - (s?.updatedAt ?? 0)
        view.mood = s == nil || (s!.status == "idle" && idleFor > sleepyAfter) ? "sleepy" : s!.mood
        let waitingN = sessions.filter { $0.waiting != nil && $0.status != "ended" }.count
        view.setAccessibilityLabel((s.map { "Lavi, \($0.project): \($0.steps.first?.text ?? "idle")" } ?? "Lavi, dozing. No active session.")
            + (waitingN > 0 ? ". \(waitingN) session\(waitingN == 1 ? "" : "s") waiting on you." : ""))
        // Speak up briefly when the advice changes.
        let key = "\(s?.id ?? "")|\(s?.steps.first?.text ?? "")"
        if !lastMood.isEmpty, key != lastMood, let s, s.status == "idle", let step = s.steps.first, panel.isVisible {
            bubble.flash(step.text, place: (s.project, s.branch), near: panel.frame, for: 6)
        }
        lastMood = key
        if Date() < celebrateUntil { view.mood = "happy" }
        noticeWaiting()
        // `/lavi settings` (or touching this file) opens the Settings window in the running Lavi.
        if FileManager.default.fileExists(atPath: openSettingsFile.path) {
            try? FileManager.default.removeItem(at: openSettingsFile)
            SettingsWindow.show()
        }
        if panel.isVisible { speakIfSomethingChanged(); breakNudge(); readAloudIfAsked() }
        if isFirstTick && panel.isVisible { _ = morningCheckIn() }
        if panel.isVisible && !isFirstTick { wrapUpIfItsTime() }
        isFirstTick = false
        ticks += 1
        if ticks % 1800 == 0 { pruneSessions() } // hourly
    }

    /// Lavi has no menu bar (he's a background app), and without an Edit menu macOS never routes
    /// ⌘C/⌘V/⌘X/⌘A to text fields, so pasting into Settings silently did nothing. This hidden menu fixes that.
    func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit Lavi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    /// Pull Lavi back onto a visible screen (after a monitor change, a resize, or a wild drag).
    func clampOnScreen() {
        let f = panel.frame
        let screens = NSScreen.screens.map(\.visibleFrame)
        if !screens.contains(where: { $0.intersection(f).width > f.width * 0.6 && $0.intersection(f).height > f.height * 0.6 }) {
            guard let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return } // no display yet
            let x = min(max(f.minX, vf.minX), vf.maxX - f.width), y = min(max(f.minY, vf.minY), vf.maxY - f.height)
            panel.setFrameOrigin(screens.contains(where: { $0.contains(NSPoint(x: f.midX, y: f.midY)) }) ? NSPoint(x: x, y: y)
                                 : NSPoint(x: vf.maxX - f.width - 24, y: vf.minY + 24))
        }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "origin")
    }

    var appliedSize: CGFloat = 0
    func applySettings() {
        if size != appliedSize {
            appliedSize = size
            let f = panel.frame
            panel.setFrame(NSRect(x: f.maxX - size, y: f.minY, width: size, height: size), display: true)
            view.frame = NSRect(x: 0, y: 0, width: size, height: size)
            clampOnScreen()
        }
        Prefs.hotkeyOn ? hotkey.register() : hotkey.unregister()
        // Calendar quiet needs calendar access. A rebuilt (unsigned) app counts as a new app to macOS, which
        // forgets the old grant, so ask again whenever the setting is on and access isn't decided yet.
        if Prefs.calendarQuiet && EKEventStore.authorizationStatus(for: .event) == .notDetermined && !askedCalendar {
            askedCalendar = true
            Quiet.requestCalendar { _ in }
        }
    }
    var askedCalendar = false

    /// First time Lavi's around on a new day: a sweep of your projects for loose ends. True if it ran.
    @discardableResult
    func morningCheckIn(force: Bool = false) -> Bool {
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        guard force || (Prefs.morningCheckIn && Prefs.d.string(forKey: "lastCheckInDay") != today) else { return false }
        Prefs.d.set(today, forKey: "lastCheckInDay")
        lastCheckInAt = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Projects.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkIn = found
                self.voice.say("morning", byYou: force, skipGap: true)
                let lines = found.prefix(4).map(Projects.summary)
                self.bubble.flash(found.isEmpty ? "morning! everything's committed and pushed." : "morning! here's where things stand.",
                                 detail: found.isEmpty ? "clean slate across \((Prefs.projectsRoot as NSString).lastPathComponent)." :
                                    lines.joined(separator: "\n") + (found.count > 4 ? "\n+\(found.count - 4) more in my menu" : ""),
                                 near: self.panel.frame, for: 9)
            }
        }
        return true
    }

    /// After a long stretch of steady work, suggest a break (off by default).
    func breakNudge() {
        let idle = secondsSinceInput()
        if idle > 300 { activeSince = nil; return } // you already took a break
        if activeSince == nil { activeSince = Date() }
        guard Prefs.breakNudges, let since = activeSince,
              Date().timeIntervalSince(since) > Prefs.breakMinutes * 60,
              Date().timeIntervalSince(lastBreakNudge) > Prefs.breakMinutes * 60 else { return }
        lastBreakNudge = Date(); activeSince = Date()
        voice.say("break")
        bubble.flash("stretch break?", detail: "you've been at it \(Int(Prefs.breakMinutes)) min straight. stand up, grab water, look far away for a minute.", near: panel.frame, for: 10)
    }

    /// The mod's "read it to me" button drops a request in say.json; read it out in Lavi's live voice.
    func readAloudIfAsked() {
        guard let data = try? Data(contentsOf: sayFile),
              let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = req["text"] as? String, let at = req["at"] as? Double else { return }
        guard at > lastSayAt else { return }
        lastSayAt = at
        // Each request costs ElevenLabs credits: at most one every 5 s, whatever writes the file.
        guard Date().timeIntervalSince(lastSynthesis) > 5 else { return }
        lastSynthesis = Date()
        func status(_ s: String) { try? "\(Date().formatted(date: .abbreviated, time: .standard)): \(s)".write(to: readStatusFile, atomically: true, encoding: .utf8) }
        status("asked ElevenLabs (\(text.count) characters)…")
        let preview = String(text.prefix(140)) + (text.count > 140 ? "…" : "")
        // Checked before asking ElevenLabs, so a muted Lavi never spends credits.
        guard let stream = voice.beginStream() else {
            status("didn't ask: Lavi's voice is off (or no audio output)")
            bubble.flash("my voice is off", detail: "turn it on in Lavi's settings to hear answers.", near: panel.frame, for: 6)
            return
        }
        bubble.flash("reading it out…", detail: preview, near: panel.frame, for: 35) // up to the timeout; trimmed once all audio is in
        let asked = Date()
        Speech.stream(text, into: stream) { [weak self] err in
            guard let self else { return }
            if let err {
                status("failed: \(err.message)")
                if !stream.started { self.bubble.flash("can't read it out yet", detail: err.message, near: self.panel.frame, for: 7) }
            } else {
                status("streamed \(String(format: "%.1f", stream.seconds)) s of audio in \(String(format: "%.1f", Date().timeIntervalSince(asked))) s (Eleven v4 Turbo)")
                self.bubble.flash("reading it out…", detail: preview, near: self.panel.frame, for: max(stream.remaining + 0.8, 2))
            }
        }
    }

    /// Claude blocked on you somewhere: a badge with the count, and a hop + bubble the first time each one appears.
    func noticeWaiting() {
        let now = Date().timeIntervalSince1970 * 1000
        let blocked = sessions.filter { $0.status != "ended" && $0.waiting != nil && now - $0.updatedAt < 6 * 3_600_000 }
        view.badge = blocked.count
        let keys = Set(blocked.map { "\($0.id)|\($0.waiting!.since)" })
        defer { seenWaiting = keys }
        guard !isFirstTick, panel.isVisible, let s = blocked.first(where: { !seenWaiting.contains("\($0.id)|\($0.waiting!.since)") }), s.quiet != true else { return }
        view.hop(10)
        voice.say("waiting")
        bubble.flash("\(s.project) needs you", detail: s.waiting!.kind == "question" ? "Claude asked you a question. click me to jump to it." : "Claude needs your OK to run something. click me to jump to it.",
                     place: (s.project, s.branch), near: panel.frame, for: 8)
    }

    /// End of the day: what's not committed or pushed across your projects, and a nudge to write the handoff.
    func wrapUpIfItsTime() {
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        guard Prefs.wrapUp, Calendar.current.component(.hour, from: Date()) >= Prefs.wrapUpHour,
              Prefs.d.string(forKey: "lastWrapUpDay") != today, secondsSinceInput() < 300, // only while you're here
              Date().timeIntervalSince(lastCheckInAt) > 600 else { return } // not right on top of the morning check-in
        Prefs.d.set(today, forKey: "lastWrapUpDay")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Projects.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkIn = found
                self.voice.say("wrapup")
                let lines = found.prefix(4).map(Projects.summary)
                self.bubble.flash(found.isEmpty ? "wrapping up? everything's committed and pushed." : "wrapping up? a few things aren't saved yet.",
                                  detail: (found.isEmpty ? "" : lines.joined(separator: "\n") + (found.count > 4 ? "\n+\(found.count - 4) more in my menu" : "") + "\n")
                                    + "click me, then Handoff, to write today's notes.", near: self.panel.frame, for: 12)
            }
        }
    }

    /// Puts a prompt (or `/lavi handoff`'s draft) in the session's message box through the mod. You still press Enter.
    /// No answer within 2.5 s (the session is closed, busy in a dialog, or has no box): the clipboard instead.
    func sendToSession(_ text: String?, handoff: Bool = false) {
        guard let s = sessions.first, isSessionID(s.id), s.status != "ended" else {
            return handoff ? copy("/lavi handoff") : copy(text ?? "")
        }
        let id = UUID().uuidString
        var req: [String: Any] = ["to": s.id, "at": Date().timeIntervalSince1970 * 1000, "id": id]
        if handoff { req["action"] = "handoff" } else { req["text"] = text ?? "" }
        guard let data = try? JSONSerialization.data(withJSONObject: req), (try? data.write(to: fillFile, options: .atomic)) != nil else { return copy(text ?? "") }
        let started = Date()
        fillTimer?.invalidate()
        fillTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            let ack = (try? Data(contentsOf: fillAckFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if ack?["id"] as? String == id {
                t.invalidate()
                if ack?["ok"] as? Bool == true {
                    // Bring that session forward in the Claude app so you can see the draft.
                    if let app = s.appId, isAppSessionID(app), let url = URL(string: "claude://claude.ai/epitaxy/\(app)") { NSWorkspace.shared.open(url) }
                    self.bubble.flash(handoff ? "drafting your handoff…" : "it's in your message box!",
                                      detail: handoff ? "give me a few seconds. it lands in \(s.project)'s message box for you to review." : "tweak it if you want, then hit enter.",
                                      place: (s.project, s.branch), near: self.panel.frame, for: 4)
                    self.voice.say(handoff ? "handoff" : "sent", byYou: true)
                } else { self.copy(handoff ? "/lavi handoff" : text ?? "") }
            } else if Date().timeIntervalSince(started) > 2.5 {
                t.invalidate()
                self.copy(handoff ? "/lavi handoff" : text ?? "")
            }
        }
    }

    func celebrate(_ kind: String) {
        celebrateUntil = Date().addingTimeInterval(4)
        view.mood = "happy"
        view.hop(14)
        voice.say(kind == "push" ? "celebrate-push" : "celebrate-tests")
        bubble.flash(kind == "push" ? "pushed! 🚀" : "tests are green again! 🎉", detail: kind == "push" ? "your work's backed up on the remote." : "nice fix.", near: panel.frame, for: 4)
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
            let cAt = s.celebrate?.at ?? 0
            defer { seenCelebrate[s.id] = max(seenCelebrate[s.id] ?? 0, cAt) }
            if isFirstTick { continue } // don't chatter about sessions that were already open
            if s.quiet == true { continue } // a repo's .lavi.json asked for quiet

            if cAt > (seenCelebrate[s.id] ?? 0), before != nil, Date().timeIntervalSince1970 * 1000 - cAt < 120_000 {
                celebrate(s.celebrate!.kind)
            } else if before == nil {
                if now.timeIntervalSince(lastGreeting) > 600 { lastGreeting = now; if !morningCheckIn() { voice.say("greeting") } }
            } else if before!.status == "busy" && s.status == "idle",
                      let start = before!.busySince, now.timeIntervalSince(start) >= 180, secondsSinceInput() < 120 {
                voice.say("done") // a long task finished while you're here
            } else if s.status == "idle" && top != before!.top && !top.isEmpty && s.id == sessions.first?.id {
                voice.say("advice-\(top)")
            }
        }
    }

    func animate() {
        if view.bounceStart != nil { view.needsDisplay = true }
        if voice.isSpeaking {
            let l = voice.level()
            let m = l < 0.35 ? 0 : l < 0.6 ? 1 : 2
            if view.mouth != m { view.mouth = m; view.needsDisplay = true }
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard panel.isVisible, !reduce else { if view.phase != 0 || view.idleImage != nil { view.phase = 0; view.idleImage = nil; view.needsDisplay = true }; return }
        view.phase += view.mood == "busy" ? 0.25 : 0.06
        // A mood with an idle clip (calm, happy, worried) plays it instead of the bob.
        if let frames = idleSets[view.mood], !frames.isEmpty {
            view.phase = 0
            // Ping-pong: forward through the clip, then back, so the loop never jumps.
            let n = frames.count, cycle = max(1, 2 * n - 2)
            let t = Int(Date().timeIntervalSince1970 * idleFPS) % cycle
            view.idleImage = frames[t < n ? t : cycle - t]
        } else {
            view.idleImage = nil
        }
        view.needsDisplay = true
    }

    func blink() {
        if view.idleImage != nil { return } // the idle clip blinks on its own
        view.isBlinking = true; view.needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.view.isBlinking = false; self?.view.needsDisplay = true }
    }

    // MARK: menu

    /// Click (or ⌃⌥L): Lavi's menu, a speech-bubble card beside him. Clicking him again closes it.
    func showMenu() {
        bubble.orderOut(nil)
        if menuPanel.isVisible { menuPanel.close(); return }
        if let top = sessions.first?.steps.first?.id, sessions.first?.status == "idle", view.mood != "sleepy" {
            voice.say(top == "next" ? "allgood" : "advice-\(top)", byYou: true)
        } else {
            voice.say("allgood", byYou: true)
        }
        appIDs = appSessionIDs()
        var d = MenuData(voiceOn: voice.isOn)
        if let s = sessions.first {
            d.project = s.project; d.branch = s.branch
            d.tips = s.steps.map { .init(text: $0.text, why: $0.why, snippets: ($0.snippets ?? []).map { ($0.label, $0.text) }) }
        }
        // Ids come from file names and session files on disk: only real session ids become rows,
        // so a crafted file can't turn "Resume in Terminal" into a shell command.
        // Sessions waiting on you go first.
        d.live = sessions.filter { isSessionID($0.id) }.sorted { ($0.waiting != nil ? 0 : 1) < ($1.waiting != nil ? 0 : 1) }.map {
            .init(id: $0.id, cwd: $0.cwd, title: $0.project,
                  subtitle: $0.waiting.map { $0.kind == "question" ? "Claude asked you a question" : "Claude needs your OK" } ?? $0.steps.first?.text ?? $0.status,
                  busy: $0.status == "busy" && $0.waiting == nil, inApp: appIDs[$0.id] != nil, waiting: $0.waiting != nil && $0.status != "ended")
        }
        let live = Set(sessions.map(\.id))
        let fmt = RelativeDateTimeFormatter(); fmt.unitsStyle = .short
        d.recent = loadTranscripts().filter { !live.contains($0.id) && isSessionID($0.id) }.map {
            .init(id: $0.id, cwd: $0.cwd, title: ($0.cwd as NSString).lastPathComponent, subtitle: "\($0.title) · \(fmt.localizedString(for: $0.modified, relativeTo: Date()))", inApp: appIDs[$0.id] != nil)
        }
        d.projects = checkIn.prefix(12).map { .init(id: $0.path, cwd: $0.path, title: $0.name, subtitle: Projects.summary($0).components(separatedBy: ": ").last ?? "") }

        func done(_ f: @escaping () -> Void) -> () -> Void { { [weak self] in self?.menuPanel.close(); f() } }
        let focus = sessions.first
        var a = MenuActions()
        a.send = { [weak self] t in self?.menuPanel.close(); self?.sendToSession(t) }
        a.handoff = done { [weak self] in self?.sendToSession(nil, handoff: true) }
        a.open = { [weak self] r in self?.menuPanel.close(); self?.open(self?.appIDs[r.id].map { "claude://claude.ai/epitaxy/\($0)" } ?? "claude://resume?session=\(r.id)") }
        a.resumeInTerminal = { [weak self] r in self?.menuPanel.close(); self?.resumeInTerminal(id: r.id, cwd: r.cwd) }
        a.copyResume = { [weak self] r in self?.menuPanel.close(); self?.resumeCommand(id: r.id, cwd: r.cwd).map { self?.copy($0, announce: false) } }
        a.openProject = { [weak self] r in self?.menuPanel.close(); self.map { $0.open($0.newSessionURL(folder: r.cwd, prompt: nil)) } }
        a.qa = done { [weak self] in
            guard let self else { return }
            if let focus { self.open(self.newSessionURL(folder: focus.cwd, prompt: self.qaPrompt())) } else { self.copy(self.qaPrompt()) }
        }
        a.qaCopy = done { [weak self] in self.map { $0.copy($0.qaPrompt()) } }
        // One session waiting: straight to it. Otherwise the app's own waiting list.
        a.waiting = done { [weak self] in
            guard let self else { return }
            let blocked = self.sessions.filter { $0.waiting != nil && $0.status != "ended" }
            if blocked.count == 1, let app = blocked[0].appId, isAppSessionID(app) { self.open("claude://claude.ai/epitaxy/\(app)") }
            else { self.open("claude://code/needs-input") }
        }
        a.newSession = done { [weak self] in self?.open("claude://code/new") }
        a.checkProjects = done { [weak self] in self?.morningCheckIn(force: true) }
        a.toggleVoice = done { [weak self] in self?.voice.isOn.toggle() }
        a.hide = done { [weak self] in self?.hideHour() }
        a.settings = done { SettingsWindow.show() }
        a.quit = { NSApp.terminate(nil) }
        view.hop(7)
        menuPanel.show(d, a, beside: panel.frame)
    }

    func open(_ s: String) { if let url = URL(string: s) { NSWorkspace.shared.open(url) } }

    func resumeCommand(id: String, cwd: String) -> String? {
        guard isSessionID(id) else { return nil }
        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \(quoted) && claude --resume '\(id)'"
    }

    func resumeInTerminal(id: String, cwd: String) {
        guard let cmd = resumeCommand(id: id, cwd: cwd) else { return }
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\"\ntell application \"Terminal\" to activate"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }

    func copy(_ text: String, announce: Bool = true) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        guard announce else { return }
        bubble.flash("copied!", detail: "paste it into Claude (⌘V), tweak it, then hit enter.", near: panel.frame, for: 3)
        voice.say("copied", byYou: true)
    }

    /// The mod keeps the canonical QA prompt in qa-prompt.txt; this is the fallback.
    func qaPrompt() -> String {
        (try? String(contentsOf: qaFile, encoding: .utf8)) ??
            "do a full QA pass and security audit of this project, fix bugs along the way without committing, then give me a full report of what you checked, found (with severity), fixed, and what's left."
    }

    /// claude://code/new opens a new Claude Code session in a folder, optionally with a prompt typed in (not sent).
    func newSessionURL(folder: String, prompt: String?) -> String {
        var c = URLComponents(string: "claude://code/new")!
        c.queryItems = [URLQueryItem(name: "folder", value: folder)] + (prompt.map { [URLQueryItem(name: "q", value: $0)] } ?? [])
        return c.url!.absoluteString
    }

    func hideHour() {
        hiddenUntil = Date().addingTimeInterval(3600)
        panel.orderOut(nil); bubble.orderOut(nil); menuPanel.close()
    }
}

if CommandLine.arguments.contains("--check-quiet") { Quiet.writeCheck(); exit(0) }
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
