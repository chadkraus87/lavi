// When Lavi keeps quiet on his own: during calendar events (EventKit) and while a Focus is on.
// Focus has no public API, so a Shortcuts automation flips a marker file (see README).
import EventKit
import Foundation

enum Quiet {
    static let store = EKEventStore()
    static let focusFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/codebuddy/focus-on")
    private static var meetingCache: (at: Date, busy: Bool) = (.distantPast, false)

    static func requestCalendar(_ done: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { ok, _ in DispatchQueue.main.async { done(ok) } }
    }

    /// True while a timed (not all-day, not "free") event is happening. Checked at most once a minute.
    static var inMeeting: Bool {
        guard Prefs.calendarQuiet, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return false }
        if Date().timeIntervalSince(meetingCache.at) < 60 { return meetingCache.busy }
        let now = Date()
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-60), end: now.addingTimeInterval(60), calendars: nil))
        let busy = events.contains { !$0.isAllDay && $0.availability != .free && $0.startDate <= now && $0.endDate > now }
        meetingCache = (now, busy)
        return busy
    }

    /// A Focus turned on by hand (Control Center, Settings, a shortcut) shows up in this file; macOS keeps it readable.
    static let assertionsFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
    static let focusStateFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/codebuddy/focus-state.json")
    private static var focusCache: (at: Date, mode: String?) = (.distantPast, nil)

    /// The Focus that's on right now ("com.apple.focus.work", …), or nil. Checked at most every 30 s.
    static var activeFocus: String? {
        if Date().timeIntervalSince(focusCache.at) < 30 { return focusCache.mode }
        var mode: String?
        // Relayed by the Lavi mod (Claude Code can read Assertions.json; Lavi can't without Full Disk Access).
        if let d = try? Data(contentsOf: focusStateFile),
           let st = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let at = st["at"] as? Double, Date().timeIntervalSince1970 * 1000 - at < 120_000 {
            mode = (st["on"] as? Bool) == true ? (st["mode"] as? String ?? "focus") : nil
        } else if let data = try? Data(contentsOf: assertionsFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let first = (json["data"] as? [[String: Any]])?.first,
           let records = first["storeAssertionRecords"] as? [[String: Any]], let rec = records.first {
            mode = (rec["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String ?? "focus"
        }
        focusCache = (Date(), mode)
        return mode
    }

    /// Quiet while any Focus is on: read straight from macOS, or the marker file for setups that use it
    /// (a Shortcuts automation, e.g. for scheduled Focus modes).
    static var inFocus: Bool {
        Prefs.focusQuiet && (activeFocus != nil || FileManager.default.fileExists(atPath: focusFile.path))
    }

    /// `CodeBuddy --check-quiet` (launched through LaunchServices so it uses Lavi's own permission) writes what
    /// Lavi can see to ~/.claude/codebuddy/calendar-check.txt: access, how many busy timed events are coming up, and
    /// when the next one starts, plus whether a Focus is on. Counts and times only, never titles.
    static func writeCheck() {
        let status = EKEventStore.authorizationStatus(for: .event)
        let canReadFocus = FileManager.default.isReadableFile(atPath: assertionsFile.path)
        let relayed = (try? Data(contentsOf: focusStateFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["at"] as? Double
        let relayAge = relayed.map { Int((Date().timeIntervalSince1970 * 1000 - $0) / 1000) }
        var lines = ["focus: relay from the mod \(relayAge.map { "\($0) s old" } ?? "missing") · direct read \(canReadFocus ? "ok" : "blocked (no Full Disk Access)") · on now: \(activeFocus ?? "none") · focus quiet setting: \(Prefs.focusQuiet ? "on" : "off")",
                     "calendar access: \(status == .fullAccess ? "granted" : "not granted (\(status.rawValue))")",
                     "calendar quiet setting: \(Prefs.calendarQuiet ? "on" : "off")"]
        if status == .fullAccess {
            let now = Date()
            let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-60), end: now.addingTimeInterval(86_400), calendars: nil))
                .filter { !$0.isAllDay && $0.availability != .free }.sorted { $0.startDate < $1.startDate }
            lines.append("calendars visible: \(store.calendars(for: .event).count)")
            lines.append("busy timed events in the next 24 h: \(events.count)")
            if let next = events.first(where: { $0.endDate > now }) {
                let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
                lines.append("next one: \(f.string(from: next.startDate)) – \(f.string(from: next.endDate))\(next.startDate <= now ? " (happening now: Lavi is quiet)" : "")")
            }
        }
        let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/codebuddy/quiet-check.txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    /// Shell commands for the two Shortcuts automations (Focus on / Focus off).
    static let focusOnCommand = "mkdir -p ~/.claude/codebuddy && touch ~/.claude/codebuddy/focus-on"
    static let focusOffCommand = "rm -f ~/.claude/codebuddy/focus-on"
}
