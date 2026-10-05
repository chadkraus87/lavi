// Lavi's Settings window (menu → Settings…, or ⌘, while the menu is open).
import AppKit
import SwiftUI

let launchAgent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.chadkraus.codebuddy.plist")

struct SettingsView: View {
    @AppStorage("voiceOn") var voiceOn = true
    @AppStorage("voiceVolume") var volume = 0.6
    @AppStorage("quietHours") var quietHours = true
    @AppStorage("calendarQuiet") var calendarQuiet = false
    @AppStorage("focusQuiet") var focusQuiet = true
    @AppStorage("breakNudges") var breakNudges = false
    @AppStorage("breakMinutes") var breakMinutes = 90.0
    @AppStorage("morningCheckIn") var morningCheckIn = true
    @AppStorage("projectsRoot") var projectsRoot = Prefs.projectsRoot
    @AppStorage("hotkeyOn") var hotkeyOn = true
    @AppStorage("size") var size = 110.0
    @State var startAtLogin = FileManager.default.fileExists(atPath: launchAgent.path)
    @State var apiKey = ""
    @State var keySaved = Keychain.get() != nil
    @State var keyNote = ""
    @State var calendarNote = ""

    var body: some View {
        Form {
            Section("Read Ask Lavi answers aloud") {
                Text("Only when you press 🔊 read it to me: about 1 ElevenLabs credit per character, so roughly 300–500 credits (~$0.05–0.10) per answer, capped at 600 characters. Lavi's everyday lines are pre-recorded and free. The key is kept only in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField(keySaved ? "saved in Keychain ✓ (paste to replace)" : "ElevenLabs API key", text: $apiKey)
                    Button("Save") { keySaved = Keychain.set(apiKey) && !apiKey.isEmpty; apiKey = "" }
                    // One click: whatever's on the clipboard goes straight to the Keychain, then the clipboard is cleared.
                    Button("Paste & Save") {
                        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                            keySaved = Keychain.set(clip)
                            if keySaved { NSPasteboard.general.clearContents() }
                            keyNote = keySaved ? "saved, and cleared from your clipboard." : "couldn't save to the Keychain."
                        } else { keyNote = "your clipboard is empty. copy the key from ElevenLabs first." }
                    }
                    if keySaved { Button("Remove") { Keychain.set(""); keySaved = false } }
                }
                if !keyNote.isEmpty { Text(keyNote).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Voice") {
                Toggle("Lavi talks", isOn: $voiceOn)
                HStack { Text("Volume"); Slider(value: $volume, in: 0.1...1) }
                Toggle("Quiet 10pm–8am (clicking still works)", isOn: $quietHours)
            }
            Section("Stay quiet automatically") {
                Toggle("During calendar events", isOn: $calendarQuiet)
                    .onChange(of: calendarQuiet) { _, on in
                        if on { Quiet.requestCalendar { ok in calendarNote = ok ? "" : "calendar access was denied. allow it in System Settings → Privacy & Security → Calendars."; if !ok { calendarQuiet = false } } }
                    }
                if !calendarNote.isEmpty { Text(calendarNote).font(.caption).foregroundStyle(.secondary) }
                Toggle("While a Focus mode is on", isOn: $focusQuiet)
                Text("macOS doesn't tell apps about Focus, so add two Shortcuts automations (Shortcuts → Automation → New → Focus): when it turns on, Run Shell Script with the first command; when it turns off, the second.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copy “Focus on” command") { copy(Quiet.focusOnCommand) }
                    Button("Copy “Focus off” command") { copy(Quiet.focusOffCommand) }
                }
            }
            Section("Lavi") {
                Picker("Size", selection: $size) { ForEach(sizes, id: \.1) { Text($0.0).tag(Double($0.1)) } }
                Toggle("Global shortcut ⌃⌥L opens Lavi's menu", isOn: $hotkeyOn)
                Toggle("Start at login", isOn: $startAtLogin).onChange(of: startAtLogin) { _, on in setStartAtLogin(on) }
            }
            Section("Nudges") {
                Toggle("Suggest a stretch break", isOn: $breakNudges)
                if breakNudges { Stepper("after \(Int(breakMinutes)) min of steady work", value: $breakMinutes, in: 30...180, step: 15) }
                Toggle("Morning check-in across my projects", isOn: $morningCheckIn)
                HStack {
                    TextField("Projects folder", text: $projectsRoot)
                    Button("Choose…") { chooseFolder() }
                }
            }
            Section("Phone pings") {
                Text("Pings are set per session: /lavi pings on, off or test.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 700) // a scrolling Form has no natural height; without this the window collapses to its title bar
    }

    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: projectsRoot)
        if p.runModal() == .OK, let url = p.url { projectsRoot = url.path }
    }

    /// Start at login = the LaunchAgent plist is in place. Off parks it as .disabled (Lavi keeps running for now).
    func setStartAtLogin(_ on: Bool) {
        let parked = launchAgent.appendingPathExtension("disabled")
        if on { try? FileManager.default.moveItem(at: parked, to: launchAgent) }
        else { try? FileManager.default.moveItem(at: launchAgent, to: parked) }
    }
}

enum SettingsWindow {
    private static var window: NSWindow?
    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Lavi Settings"
            w.styleMask = [.titled, .closable]
            w.setContentSize(NSSize(width: 500, height: 700))
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
