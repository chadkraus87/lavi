// Lavi's Settings window (menu → Settings…, or ⌘, while the menu is open).
import AppKit
import SwiftUI
import EventKit

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
    @AppStorage("wrapUp") var wrapUp = true
    @AppStorage("wrapUpHour") var wrapUpHour = 18.0
    @AppStorage("projectsRoot") var projectsRoot = Prefs.projectsRoot
    @AppStorage("hotkeyOn") var hotkeyOn = true
    @AppStorage("size") var size = 110.0
    @State var startAtLogin = FileManager.default.fileExists(atPath: launchAgent.path)
    @State var apiKey = ""
    @State var keySaved = Keychain.get() != nil
    @State var keyNote = ""
    @State var calendarNote = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Card("Voice", icon: "speaker.wave.2.fill") {
                    Toggle("Lavi talks", isOn: $voiceOn)
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill").foregroundStyle(Color.inkSoft)
                        Slider(value: $volume, in: 0.1...1).tint(Color.lavender).accessibilityLabel("Volume")
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(Color.inkSoft)
                    }
                    Toggle("Quiet 10pm–8am (clicking him still works)", isOn: $quietHours)
                }
                Card("Read answers aloud", icon: "waveform") {
                    Note("Only when you press 🔊 read it to me under an Ask Lavi answer. Uses ElevenLabs' Eleven v4 Turbo, so he starts talking in under a second. A full answer (capped at 600 characters) costs about 2–3¢ in ElevenLabs credits. His everyday lines are pre-recorded and free. The key is kept only in your Keychain.")
                    HStack(spacing: 8) {
                        SecureField(keySaved ? "saved in Keychain ✓ (paste to replace)" : "ElevenLabs API key", text: $apiKey).textFieldStyle(.roundedBorder)
                        Button("Save") { keySaved = Keychain.set(apiKey) && !apiKey.isEmpty; apiKey = "" }.buttonStyle(ChipStyle())
                    }
                    HStack(spacing: 8) {
                        // One click: whatever's on the clipboard goes straight to the Keychain, then the clipboard is cleared.
                        Button("Paste & Save") {
                            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                                keySaved = Keychain.set(clip)
                                if keySaved { NSPasteboard.general.clearContents() }
                                keyNote = keySaved ? "saved, and cleared from your clipboard." : "couldn't save to the Keychain."
                            } else { keyNote = "your clipboard is empty. copy the key from ElevenLabs first." }
                        }.buttonStyle(ChipStyle(prominent: true))
                        if keySaved { Button("Remove key") { Keychain.set(""); keySaved = false }.buttonStyle(ChipStyle()) }
                        Spacer()
                        Label(keySaved ? "key saved" : "no key yet", systemImage: keySaved ? "checkmark.seal.fill" : "key")
                            .font(Theme.font(11, .semibold)).foregroundStyle(Color.inkSoft)
                    }
                    if !keyNote.isEmpty { Note(keyNote) }
                }
                Card("Stay quiet automatically", icon: "moon.zzz.fill") {
                    Toggle("During calendar events", isOn: $calendarQuiet)
                        .onChange(of: calendarQuiet) { _, on in
                            if on { Quiet.requestCalendar { ok in calendarNote = ok ? "" : "calendar access was denied. allow it in System Settings → Privacy & Security → Calendars."; if !ok { calendarQuiet = false } } }
                        }
                    if calendarQuiet {
                        // Show the real permission, not just the switch: macOS can forget it when the app's signature changes.
                        let st = EKEventStore.authorizationStatus(for: .event)
                        HStack {
                            Note(st == .fullAccess ? "calendar access: granted ✓" : st == .notDetermined ? "calendar access: not asked yet" : "calendar access: off. allow CodeBuddy in System Settings → Privacy & Security → Calendars.")
                            if st == .notDetermined { Button("Allow…") { Quiet.requestCalendar { ok in calendarNote = ok ? "" : "access wasn't granted." } }.buttonStyle(ChipStyle(prominent: true)) }
                        }
                    }
                    if !calendarNote.isEmpty { Note(calendarNote) }
                    Toggle("While a Focus mode is on", isOn: $focusQuiet)
                    Note("Works on its own for any Focus you turn on. Scheduled Focus modes may not show up; for those, add Shortcuts automations that run these commands when the Focus turns on and off.")
                    HStack(spacing: 8) {
                        Button("Copy “Focus on” command") { copy(Quiet.focusOnCommand) }.buttonStyle(ChipStyle())
                        Button("Copy “Focus off” command") { copy(Quiet.focusOffCommand) }.buttonStyle(ChipStyle())
                    }
                }
                Card("Lavi", icon: "face.smiling.inverse") {
                    HStack {
                        Text("Size")
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(sizes, id: \.1) { name, pts in
                                Button(name) { size = Double(pts) }
                                    .buttonStyle(ChipStyle(prominent: size == Double(pts)))
                                    .accessibilityAddTraits(size == Double(pts) ? .isSelected : [])
                            }
                        }
                    }
                    Toggle("Global shortcut ⌃⌥L opens Lavi's menu", isOn: $hotkeyOn)
                    Toggle("Start at login", isOn: $startAtLogin).onChange(of: startAtLogin) { _, on in setStartAtLogin(on) }
                }
                Card("Nudges", icon: "hand.wave.fill") {
                    Toggle("Suggest a stretch break", isOn: $breakNudges)
                    if breakNudges { Stepper("after \(Int(breakMinutes)) min of steady work", value: $breakMinutes, in: 30...180, step: 15) }
                    Toggle("Morning check-in across my projects", isOn: $morningCheckIn)
                    Toggle("End-of-day wrap-up (what's unsaved, plus a handoff nudge)", isOn: $wrapUp)
                    if wrapUp {
                        Stepper("from \(hourName(Int(wrapUpHour))), once a day", value: $wrapUpHour, in: 12...23, step: 1)
                    }
                    HStack(spacing: 8) {
                        TextField("Projects folder", text: $projectsRoot).textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseFolder() }.buttonStyle(ChipStyle())
                    }
                }
                Card("Phone pings", icon: "iphone.radiowaves.left.and.right") {
                    Note("Pings are set per session: type /lavi pings on, off or test in Claude.")
                }
            }
            .padding(20)
        }
        .toggleStyle(.switch).tint(Color.mint)
        .font(Theme.font(13)).foregroundStyle(Color.ink)
        .background(LinearGradient(colors: [Color.lilac, Color(nsColor: Theme.lavender.blended(withFraction: 0.75, of: .white) ?? Theme.lilac)], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .light) // Lavi's palette is a light one; keep it readable in dark mode too
        .frame(width: 520, height: 720)
    }

    var header: some View {
        HStack(spacing: 14) {
            if let face = art["happy"] {
                Image(nsImage: face).resizable().scaledToFit().frame(width: 64, height: 64).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Lavi").font(Theme.font(26, .heavy))
                Text("your coding buddy's settings. changes apply right away.").font(Theme.font(12)).foregroundStyle(Color.inkSoft)
            }
        }
        .padding(.top, 18) // clear of the window buttons
    }

    func hourName(_ h: Int) -> String { h == 12 ? "noon" : h < 12 ? "\(h) am" : "\(h - 12) pm" }

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

/// A white card with Lavi's ink outline and a lavender icon badge.
struct Card<Content: View>: View {
    let title: String, icon: String
    @ViewBuilder let content: Content
    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) { self.title = title; self.icon = icon; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ink)
                    .frame(width: 26, height: 26).background(Circle().fill(Color.lavender.opacity(0.55))).overlay(Circle().stroke(Color.ink, lineWidth: 1.5))
                Text(title).font(Theme.font(15, .bold))
            }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white).shadow(color: .black.opacity(0.12), radius: 6, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.ink, lineWidth: 2.5))
    }
}

/// Small explanatory text.
struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(Theme.font(11.5)).foregroundStyle(Color.inkSoft).fixedSize(horizontal: false, vertical: true) }
}

enum SettingsWindow {
    private static var window: NSWindow?
    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Lavi Settings"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
            w.backgroundColor = Theme.lilac
            w.setContentSize(NSSize(width: 520, height: 720))
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
