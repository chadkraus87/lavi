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

    static var inFocus: Bool { Prefs.focusQuiet && FileManager.default.fileExists(atPath: focusFile.path) }

    /// Shell commands for the two Shortcuts automations (Focus on / Focus off).
    static let focusOnCommand = "mkdir -p ~/.claude/codebuddy && touch ~/.claude/codebuddy/focus-on"
    static let focusOffCommand = "rm -f ~/.claude/codebuddy/focus-on"
}
