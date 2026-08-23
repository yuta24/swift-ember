// Shared driver for every fixture case.
//
// A case supplies `probe()`. The harness prints its output once before any
// patch is loaded and once after each patch, so the diff between generations
// is the observable effect of the reload.
//
// Output is unbuffered so that a case which crashes on load still leaves its
// pre-crash generations on stdout.

import Foundation

@main
enum FixtureMain {
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)

        try await report(generation: 0)

        for (index, path) in CommandLine.arguments.dropFirst().enumerated() {
            guard dlopen(path, RTLD_NOW) != nil else {
                print("load-failed: \(String(cString: dlerror()))")
                exit(2)
            }
            try await report(generation: index + 1)
        }
    }

    private static func report(generation: Int) async throws {
        for line in try await probe() {
            print("g\(generation): \(line)")
        }
    }
}
