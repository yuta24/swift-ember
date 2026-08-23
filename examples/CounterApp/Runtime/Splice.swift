#if SPLICE_ENABLED

import Foundation

/// The minimal M1 runtime: no daemon, no IPC, no classifier.
///
/// A patch is delivered into the application's Documents directory by
/// `patch.sh` and loaded on demand. Everything this file does deliberately
/// stops at proving that a patch image can be loaded into a live process; the
/// host-side pipeline arrives in M2.
enum Splice {
    struct LoadResult {
        let name: String
        let succeeded: Bool
        let detail: String
    }

    private static var loaded: Set<String> = []
    private static var watcher: Timer?

    /// Polls the inbox so a patch delivered by `patch.sh` applies without the
    /// developer touching the app.
    ///
    /// Polling is the M1 shortcut. In M2 the host daemon pushes over IPC and
    /// this disappears; the runtime should not be deciding when to reload.
    static func startWatching(interval: TimeInterval = 0.5,
                              onLoad: @escaping ([LoadResult]) -> Void) {
        watcher?.invalidate()
        watcher = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            let results = loadPendingPatches()
            if !results.isEmpty { onLoad(results) }
        }
    }

    static var inbox: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Patches", isDirectory: true)
    }

    /// Loads every patch image in the inbox that has not been loaded yet, in
    /// filename order, so generations apply in the order they were produced.
    static func loadPendingPatches() -> [LoadResult] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: nil)) ?? []

        let pending = contents
            .filter { $0.pathExtension == "dylib" }
            .filter { !loaded.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return pending.map { url in
            let name = url.lastPathComponent
            guard dlopen(url.path, RTLD_NOW) != nil else {
                // A failure here is the loud kind: the image never took effect,
                // so the process is still running the previous generation.
                return LoadResult(name: name, succeeded: false,
                                  detail: String(cString: dlerror()))
            }
            loaded.insert(name)
            return LoadResult(name: name, succeeded: true, detail: "loaded")
        }
    }
}

#endif
