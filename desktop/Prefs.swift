// Lavi's settings, all in UserDefaults (domain com.chadkraus.codebuddy). The Settings window binds to these keys.
import Foundation

enum Prefs {
    static let d = UserDefaults.standard
    static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
    static func num(_ k: String, _ def: Double) -> Double { (d.object(forKey: k) as? NSNumber)?.doubleValue ?? def }

    static var voiceOn: Bool { bool("voiceOn", true) }
    static var volume: Float { Float(num("voiceVolume", 0.6)) }
    static var quietHours: Bool { bool("quietHours", true) }
    static var calendarQuiet: Bool { bool("calendarQuiet", false) }
    static var focusQuiet: Bool { bool("focusQuiet", true) }
    static var breakNudges: Bool { bool("breakNudges", false) }
    static var breakMinutes: Double { num("breakMinutes", 90) }
    static var morningCheckIn: Bool { bool("morningCheckIn", true) }
    static var hotkeyOn: Bool { bool("hotkeyOn", true) }
    static var projectsRoot: String {
        d.string(forKey: "projectsRoot") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Development/Projects").path
    }
}
