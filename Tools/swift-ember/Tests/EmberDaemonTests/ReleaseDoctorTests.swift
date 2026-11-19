import Foundation
import Testing
@testable import EmberCLI
import EmberDaemon

@Test func releaseDoctorIgnoresUnrelatedTypesAndLiterals() throws {
    try withReleaseDoctorFixture { directory in
        let source = directory.appendingPathComponent("Fixture.swift")
        let image = directory.appendingPathComponent("App")
        let stripped = directory.appendingPathComponent("App.stripped")
        try Data("""
            final class EmberClient {}
            final class EmberDeviceClient {}
            final class RuntimePatchApplier {}
            enum EmberRuntime {}
            print(EmberClient.self, EmberDeviceClient.self, RuntimePatchApplier.self, EmberRuntime.self)
            print("_TtC12EmberRuntime11EmberClient")
            """.utf8).write(to: source)
        try runFixtureTool(["swiftc", "-module-name", "Unrelated", source.path, "-o", image.path])
        try runFixtureTool(["strip", "-o", stripped.path, image.path])

        #expect(try ReleaseDoctor.inspect(image).isEmpty)
        #expect(try ReleaseDoctor.inspect(stripped).isEmpty)
    }
}

@Test func releaseDoctorDemanglesSubstitutedSwiftSymbols() throws {
    try withReleaseDoctorFixture { directory in
        let source = directory.appendingPathComponent("Fixture.swift")
        let image = directory.appendingPathComponent("App")
        try Data("""
            final class EmberClient {}
            print(EmberClient.self)
            """.utf8).write(to: source)
        // Removing Objective-C interop exercises the symbol check on its own.
        try runFixtureTool(["swiftc", "-module-name", "EmberRuntime", "-Xfrontend", "-disable-objc-interop",
                            source.path, "-o", image.path])
        #expect(try ReleaseDoctor.inspect(image) == ["enabled Ember runtime"])
    }
}

@Test(arguments: [false, true])
func releaseDoctorChecksTheRuntimeWithAndWithoutSymbols(enabled: Bool) throws {
    try withReleaseDoctorFixture { directory in
        let repository = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { directory, _ in
            directory.deletingLastPathComponent()
        }
        let sources = try FileManager.default.contentsOfDirectory(
            at: repository.appendingPathComponent("runtime/Sources"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }.map(\.path).sorted()
        let image = directory.appendingPathComponent("EmberRuntime.dylib")
        let stripped = directory.appendingPathComponent("EmberRuntime.stripped.dylib")
        let compiler = ["swiftc", "-swift-version", "6", "-module-name", "EmberRuntime",
                        "-emit-library", "-o", image.path]
        try runFixtureTool(compiler + (enabled ? ["-D", "EMBER_ENABLED"] : []) + sources)
        try runFixtureTool(["strip", "-x", "-o", stripped.path, image.path])

        let expected = enabled ? ["enabled Ember runtime"] : []
        #expect(try ReleaseDoctor.inspect(image) == expected)
        #expect(try ReleaseDoctor.inspect(stripped) == expected)
    }
}

private func withReleaseDoctorFixture(_ body: (URL) throws -> Void) throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    try body(directory)
}

private func runFixtureTool(_ arguments: [String]) throws {
    let result = try Subprocess.runSeparated("/usr/bin/xcrun", arguments: arguments)
    try #require(result.exitCode == 0, "\(arguments.first ?? "xcrun"): \(result.standardError)")
}
