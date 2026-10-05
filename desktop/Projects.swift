// The morning check-in: a quick sweep of your projects folder for uncommitted or unpushed work.
import Foundation

struct ProjectState { let name: String; let path: String; let dirty: Int; let unpushed: Int }

enum Projects {
    private static func git(_ dir: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// Every git repo one level under the projects folder that has uncommitted or unpushed work.
    static func scan(root: String = Prefs.projectsRoot) -> [ProjectState] {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return dirs.sorted().compactMap { name in
            let path = (root as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path + "/.git") else { return nil }
            let dirty = git(path, ["status", "--porcelain"])?.split(separator: "\n").count ?? 0
            let unpushed = Int(git(path, ["rev-list", "--count", "@{u}..HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            return dirty + unpushed > 0 ? ProjectState(name: name, path: path, dirty: dirty, unpushed: unpushed) : nil
        }
    }

    /// One line per project: "runtimelocal: 3 uncommitted · 1 unpushed".
    static func summary(_ p: ProjectState) -> String {
        var bits: [String] = []
        if p.dirty > 0 { bits.append("\(p.dirty) uncommitted") }
        if p.unpushed > 0 { bits.append("\(p.unpushed) unpushed") }
        return "\(p.name): " + bits.joined(separator: " · ")
    }
}
