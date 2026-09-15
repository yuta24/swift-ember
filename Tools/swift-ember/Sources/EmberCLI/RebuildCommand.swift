import Foundation
import Darwin
import EmberCore

enum RebuildCommand {
    struct Failure: Error, CustomStringConvertible {
        let command: String
        let status: Int32

        var description: String {
            "rebuild command exited with status \(status): \(command)"
        }
    }

    static func shouldRun(for failure: EmberError) -> Bool {
        failure.stage == .classify && failure.recovery == .rebuild
    }

    /// One watch session owns one runner so SIGINT/SIGTERM can stop the shell
    /// and every build process it launched, even while the watch loop is
    /// suspended awaiting command completion.
    final class Runner: @unchecked Sendable {
        private let lock = NSLock()
        private var activeProcessGroup: pid_t?
        private var stopping = false

        /// Runs an explicitly configured command through zsh.
        /// stdout/stderr are inherited by design so Xcode diagnostics remain
        /// attached to the watcher log.
        func run(_ command: String, in directory: URL) async throws {
            try throwIfStopping()

            var environment = ProcessInfo.processInfo.environment
            environment["SWIFT_EMBER_REBUILD"] = "1"
            let pid = try Self.spawn(
                executable: "/bin/zsh", arguments: ["/bin/zsh", "-lc", command],
                environment: environment, directory: directory.path)
            let shouldStop = lock.withLock { () -> Bool in
                activeProcessGroup = pid
                return stopping
            }
            if shouldStop { terminate(processGroup: pid) }

            let waitResult = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        var status: Int32 = 0
                        var result: pid_t
                        repeat {
                            result = waitpid(pid, &status, 0)
                        } while result == -1 && errno == EINTR
                        continuation.resume(returning: (
                            status: status,
                            error: result == -1 ? errno : 0))
                    }
                }
            } onCancel: {
                self.cancel()
            }

            let cancelled = lock.withLock { stopping || Task.isCancelled }
            if cancelled {
                // The shell may exit before a descendant that ignored TERM.
                // Keep the group registered until every descendant is gone.
                // The forced-kill closure checks this registration, so it
                // cannot act after that group was observed gone and its
                // numeric process-group id stopped belonging to this runner.
                await Self.waitForTermination(of: pid)
                lock.withLock {
                    if activeProcessGroup == pid { activeProcessGroup = nil }
                }
                throw CancellationError()
            }
            lock.withLock {
                if activeProcessGroup == pid { activeProcessGroup = nil }
            }
            if waitResult.error != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: waitResult.error) ?? .ECHILD)
            }
            let exitCode = Self.exitCode(from: waitResult.status)
            guard exitCode == 0 else { throw Failure(command: command, status: exitCode) }
        }

        /// Checks both structured task cancellation and the process-wide signal
        /// state. The latter remains relevant after the rebuild command exits,
        /// while the watcher is waiting for the replacement app to connect.
        func throwIfStopping() throws {
            try Task.checkCancellation()
            guard !lock.withLock({ stopping }) else { throw CancellationError() }
        }

        func cancel() {
            let pid = lock.withLock { () -> pid_t? in
                guard !stopping else { return nil }
                stopping = true
                return activeProcessGroup
            }
            if let pid { terminate(processGroup: pid) }
        }

        private func terminate(processGroup pid: pid_t) {
            guard kill(-pid, SIGTERM) == 0 else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                let stillOwned = lock.withLock {
                    stopping && activeProcessGroup == pid
                }
                guard stillOwned else { return }
                if kill(-pid, 0) == 0 { _ = kill(-pid, SIGKILL) }
            }
        }

        private static func waitForTermination(of processGroup: pid_t) async {
            for _ in 0..<32 {
                errno = 0
                if kill(-processGroup, 0) == -1 && errno == ESRCH { return }
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
                        continuation.resume()
                    }
                }
            }
        }

        private static func exitCode(from status: Int32) -> Int32 {
            let signal = status & 0x7f
            return signal == 0 ? (status >> 8) & 0xff : 128 + signal
        }

        private static func spawn(
            executable: String, arguments: [String],
            environment: [String: String], directory: String
        ) throws -> pid_t {
            var actions: posix_spawn_file_actions_t? = nil
            guard posix_spawn_file_actions_init(&actions) == 0 else {
                throw POSIXError(.ENOMEM)
            }
            defer { posix_spawn_file_actions_destroy(&actions) }
            var attributes: posix_spawnattr_t? = nil
            guard posix_spawnattr_init(&attributes) == 0 else {
                throw POSIXError(.ENOMEM)
            }
            defer { posix_spawnattr_destroy(&attributes) }
            let changeDirectory = posix_spawn_file_actions_addchdir_np(&actions, directory)
            guard changeDirectory == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: changeDirectory) ?? .EINVAL)
            }
            var defaultSignals = sigset_t()
            sigemptyset(&defaultSignals)
            sigaddset(&defaultSignals, SIGINT)
            sigaddset(&defaultSignals, SIGTERM)
            let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF)
            guard posix_spawnattr_setflags(&attributes, flags) == 0,
                  posix_spawnattr_setpgroup(&attributes, 0) == 0,
                  posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0 else {
                throw POSIXError(.EINVAL)
            }

            var pid: pid_t = 0
            let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
            let result = withMutableCStrings(arguments) { argv in
                withMutableCStrings(environmentStrings) { envp in
                    posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
                }
            }
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL)
            }
            return pid
        }
    }
}

private func withMutableCStrings<Result>(
    _ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    let storage = strings.map { strdup($0) }
    defer { storage.forEach { free($0) } }
    var pointers = storage + [nil]
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
