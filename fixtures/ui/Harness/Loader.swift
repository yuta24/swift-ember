import SwiftUI
import Foundation

// Shared by every UI case. A case supplies the views and the container; this
// supplies the two things the runner needs to see from outside the process:
// a heartbeat that stops when the process dies, and a line saying what the
// screen last rendered.
//
// The heartbeat is how "did it crash" is decided. Asking the simulator whether
// the process is still listed answered "yes" for a process that had already
// aborted, which would have made a crashing case pass.
public enum UIHarness {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public static func beat(_ tick: Int, rendered: String) {
        heartbeat(tick)
        render(rendered)
    }

    public static func heartbeat(_ tick: Int) {
        try? "\(tick)".write(to: documents.appendingPathComponent("heartbeat"),
                             atomically: true, encoding: .utf8)
    }

    public static func render(_ rendered: String) {
        try? rendered.write(to: documents.appendingPathComponent("rendered"),
                            atomically: true, encoding: .utf8)
    }

    public static func recordRegistered(_ count: Int?) {
        try? String(count.map(String.init) ?? "unreadable").write(
            to: documents.appendingPathComponent("registered"),
            atomically: true,
            encoding: .utf8)
    }

    /// Polls the inbox the runner delivers into and loads anything new, the
    /// way the real runtime does.
    public static func loadPatches() async {
        let inbox = documents.appendingPathComponent("Patches", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var seen: Set<String> = []
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(300))
            let names = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".dylib") && !seen.contains(name) {
                seen.insert(name)
                let path = inbox.appendingPathComponent(name).path
                NSLog("UIFIXTURE loading \(name)")
                if dlopen(path, RTLD_NOW) != nil {
                    recordRegistered(RegisteredReplacements.count(inImageAt: path))
                }
            }
        }
    }
}
