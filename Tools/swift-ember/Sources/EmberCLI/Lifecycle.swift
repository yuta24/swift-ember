import Darwin
import Foundation
import EmberCore

/// Owns the small amount of process management needed to use `watch` from an
/// Xcode action. The daemon remains the same foreground command; `start` only
/// launches that command in a new session and records how to stop it safely.
public enum Lifecycle {
    private static let recordEnvironment = "SWIFT_EMBER_SESSION_RECORD"
    private static let patchDirectoryEnvironment = "SWIFT_EMBER_PATCH_DIRECTORY"

    public struct Session: Sendable {
        public let name: String
        public let recordURL: URL
        public let contextURL: URL
        public let logURL: URL
        public let patchURL: URL
        public let lockURL: URL
    }

    private struct Record: Codable {
        let pid: Int32
        let executablePath: String
        let startedAtMicroseconds: UInt64
    }

    private struct ProcessIdentity {
        let executablePath: String
        let startedAtMicroseconds: UInt64
    }

    public enum LifecycleError: Error, CustomStringConvertible {
        case noExecutable
        case launch(String)
        case startup(String, URL)
        case unsafeRecord(Int32)
        case stopTimedOut(Int32, URL)
        case sessionLock(String)

        public var description: String {
            switch self {
            case .noExecutable:
                "cannot locate the swift-ember executable"
            case .launch(let reason):
                "cannot start the background watcher: \(reason)"
            case .startup(let reason, let log):
                "the background watcher did not start: \(reason)\nsee \(log.path)"
            case .unsafeRecord(let pid):
                "refusing to stop pid \(pid): it is not the recorded swift-ember process"
            case .stopTimedOut(let pid, let log):
                "pid \(pid) did not stop after SIGTERM\nsee \(log.path)"
            case .sessionLock(let reason):
                "cannot lock the swift-ember session: \(reason)"
            }
        }
    }

    public static func session(for options: Options) -> Session {
        let container: URL
        let label: String
        let descriptor: String

        if let project = options.project {
            container = absoluteURL(project)
            label = options.scheme ?? container.deletingPathExtension().lastPathComponent
            descriptor = "project|\(container.path)|\(options.scheme ?? "")"
        } else if let workspace = options.workspace {
            container = absoluteURL(workspace)
            label = options.scheme ?? container.deletingPathExtension().lastPathComponent
            descriptor = "workspace|\(container.path)|\(options.scheme ?? "")"
        } else {
            container = absoluteURL(options.contextPath)
            label = container.deletingPathExtension().lastPathComponent
            descriptor = "context|\(container.path)"
        }

        let identity = descriptor
            + "|configuration=\(options.configuration)"
            + "|device=\(options.device ?? "simulator")"
        let key = "\(slug(label))-\(hexHash(identity))"
        let root = container.deletingLastPathComponent().appendingPathComponent(".ember")
        return Session(
            name: key,
            recordURL: root.appendingPathComponent("sessions/\(key).json"),
            contextURL: root.appendingPathComponent("sessions/\(key).context.json"),
            logURL: root.appendingPathComponent("logs/\(key).log"),
            patchURL: root.appendingPathComponent("patches/\(key)", isDirectory: true),
            lockURL: root.appendingPathComponent("locks/\(key).lock"))
    }

    public static func start(options: Options, context: BuildContext) throws {
        let session = session(for: options)
        try withSessionLock(session) {
            try startLocked(options: options, context: context, session: session)
        }
    }

    /// Replaces a watcher after Xcode links a new binary. Resolving the new
    /// context happens before this call, then stop/start share one lock so a
    /// concurrent Scheme action cannot slip another owner between them.
    public static func restart(options: Options, context: BuildContext) throws {
        let session = session(for: options)
        try withSessionLock(session) {
            try stopLocked(session: session)
            try startLocked(options: options, context: context, session: session)
        }
    }

    private static func startLocked(options: Options, context: BuildContext, session: Session) throws {
        if let record = try readRecord(at: session.recordURL) {
            if processMatches(record) {
                print("already running pid \(record.pid)")
                print("log                \(session.logURL.path)")
                return
            }
            try? FileManager.default.removeItem(at: session.recordURL)
            try? FileManager.default.removeItem(at: session.contextURL)
        }

        guard let executable = Bundle.main.executableURL?.standardizedFileURL else {
            throw LifecycleError.noExecutable
        }
        try FileManager.default.createDirectory(
            at: session.recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: session.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try context.write(to: session.contextURL)
        FileManager.default.createFile(atPath: session.logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: session.logURL)
        defer { try? log.close() }

        var environment = backgroundEnvironment(from: ProcessInfo.processInfo.environment)
        environment[recordEnvironment] = session.recordURL.path
        environment[patchDirectoryEnvironment] = session.patchURL.path
        let pid = try spawnDetached(
            executable: executable,
            arguments: [Options.Command.watch.rawValue, "--context", session.contextURL.path],
            environment: environment,
            logDescriptor: log.fileDescriptor)

        // The child writes its record only after the listener, session file,
        // and file watcher are ready. Do not make an Xcode action race that
        // initialization just because Process.run() returned.
        let deadline = Date().addingTimeInterval(options.startupTimeout)
        repeat {
            if let record = try readRecord(at: session.recordURL),
               record.pid == pid,
               processMatches(record) {
                print("started            pid \(record.pid)")
                print("log                \(session.logURL.path)")
                return
            }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                removeSessionFiles(session)
                throw LifecycleError.startup("exited with wait status \(status)", session.logURL)
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline

        _ = kill(pid, SIGTERM)
        waitForChildExit(pid, timeout: 5)
        removeSessionFiles(session)
        throw LifecycleError.startup("timed out while initializing", session.logURL)
    }

    /// A daemon outlives the Xcode action that launched it. Keep only the
    /// process environment needed to locate tools, temporary storage, and the
    /// selected Xcode; debugger and build-script variables must not leak into
    /// that long-running process.
    static func backgroundEnvironment(from parent: [String: String]) -> [String: String] {
        let allowed = ["HOME", "PATH", "TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL", "LC_CTYPE"]
        return Dictionary(uniqueKeysWithValues: allowed.compactMap { key in
            parent[key].map { (key, $0) }
        })
    }

    /// Idempotent so an Xcode post-action can run even if the build action did
    /// not start a watcher.
    public static func stop(options: Options) throws {
        let session = session(for: options)
        try withSessionLock(session) {
            try stopLocked(session: session)
        }
    }

    private static func stopLocked(session: Session) throws {
        guard let record = try readRecord(at: session.recordURL) else {
            try? FileManager.default.removeItem(at: session.contextURL)
            print("not running")
            return
        }
        guard processMatches(record) else {
            if processIdentity(record.pid) == nil {
                try? FileManager.default.removeItem(at: session.recordURL)
                try? FileManager.default.removeItem(at: session.contextURL)
                print("not running; removed a stale session record")
                return
            }
            throw LifecycleError.unsafeRecord(record.pid)
        }

        guard kill(record.pid, SIGTERM) == 0 || errno == ESRCH else {
            throw LifecycleError.launch("cannot signal pid \(record.pid): errno \(errno)")
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !processMatches(record) {
                try? FileManager.default.removeItem(at: session.recordURL)
                try? FileManager.default.removeItem(at: session.contextURL)
                print("stopped            pid \(record.pid)")
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw LifecycleError.stopTimedOut(record.pid, session.logURL)
    }

    public static func runningPID(options: Options) -> Int32? {
        let session = session(for: options)
        guard let record = try? readRecord(at: session.recordURL),
              processMatches(record) else { return nil }
        return record.pid
    }

    public static func patchDirectory(
        for options: Options,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let path = environment[patchDirectoryEnvironment] {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }

        // Foreground watches have no lifecycle record enforcing a single
        // owner. Keep even two watches of the same scheme from compiling the
        // same Patch_001 files over one another.
        let owner = "watch-\(getpid())-\(UUID().uuidString.lowercased())"
        return session(for: options).patchURL.appendingPathComponent(owner, isDirectory: true)
    }

    /// Written by a background `watch` once it is ready to accept edits.
    public static func markReady(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let path = environment[recordEnvironment] else { return }
        guard let identity = processIdentity(getpid()) else {
            throw LifecycleError.launch("cannot inspect the background process")
        }
        let record = Record(
            pid: getpid(),
            executablePath: identity.executablePath,
            startedAtMicroseconds: identity.startedAtMicroseconds)
        let data = try JSONEncoder().encode(record)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func removeOwnedRecord(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment[recordEnvironment],
              let record = try? readRecord(at: URL(fileURLWithPath: path)),
              record.pid == getpid(), processMatches(record) else { return }
        try? FileManager.default.removeItem(atPath: path)
        let context = URL(fileURLWithPath: path)
            .deletingPathExtension().appendingPathExtension("context.json")
        try? FileManager.default.removeItem(at: context)
    }

    private static func readRecord(at url: URL) throws -> Record? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(Record.self, from: data)
        } catch is DecodingError {
            // A partial file cannot name a process safely and cannot become
            // valid later. Treat it like a stale PID rather than making every
            // future start require manual cleanup.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private static func removeSessionFiles(_ session: Session) {
        try? FileManager.default.removeItem(at: session.recordURL)
        try? FileManager.default.removeItem(at: session.contextURL)
    }

    private static func absoluteURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let bytes = buffer[..<end].map { UInt8(bitPattern: $0) }
        return standardizedPath(String(decoding: bytes, as: UTF8.self))
    }

    private static func processIdentity(_ pid: Int32) -> ProcessIdentity? {
        guard let executablePath = processPath(pid) else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard result == Int32(size) else { return nil }
        return ProcessIdentity(
            executablePath: executablePath,
            startedAtMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }

    private static func processMatches(_ record: Record) -> Bool {
        guard let identity = processIdentity(record.pid) else { return false }
        return identity.executablePath == standardizedPath(record.executablePath)
            && identity.startedAtMicroseconds == record.startedAtMicroseconds
    }

    private static func waitForChildExit(_ pid: Int32, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// The lock file is deliberately persistent. Removing a locked file would
    /// let another process create a new inode and acquire a second, unrelated
    /// lock for the same session.
    static func withSessionLock<T>(_ session: Session, operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: session.lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = session.lockURL.path.withCString {
            open($0, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else {
            throw LifecycleError.sessionLock("cannot open \(session.lockURL.path): errno \(errno)")
        }
        defer { close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw LifecycleError.sessionLock("cannot acquire \(session.lockURL.path): errno \(errno)")
            }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    /// Spawn directly into a new session. `Process` creates a process-group
    /// leader on macOS, which makes a later `setsid()` fail with EPERM and is
    /// exactly the lifecycle Xcode tears down with its action.
    private static func spawnDetached(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        logDescriptor: Int32
    ) throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw LifecycleError.launch("cannot initialize file actions")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        let nullResult = "/dev/null".withCString {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, $0, O_RDONLY, 0)
        }
        guard nullResult == 0,
              posix_spawn_file_actions_adddup2(&actions, logDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, logDescriptor, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, logDescriptor) == 0 else {
            throw LifecycleError.launch("cannot configure standard streams")
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw LifecycleError.launch("cannot initialize spawn attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0 else {
            throw LifecycleError.launch("cannot request a detached session")
        }

        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }

        var pid: Int32 = 0
        let result = executable.path.withCString { path in
            posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
        }
        guard result == 0 else {
            throw LifecycleError.launch("posix_spawn failed with errno \(result)")
        }
        return pid
    }

    private static func slug(_ value: String) -> String {
        let mapped = value.lowercased().map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let value = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? "session" : value
    }

    /// Stable across Swift versions and process launches; unlike Hasher this
    /// is suitable for a filename that has to be found by a later invocation.
    private static func hexHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
