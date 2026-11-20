import Foundation
import EmberCore
import EmberDaemon

public struct SimulatorSelection: Codable, Sendable {
    public let identifier: String
    let multipleBooted: Bool

    var warning: String? {
        guard multipleBooted else { return nil }
        return "warning: multiple Simulators were booted at startup. Selected \(identifier). Use --simulator <UDID> to choose a Simulator explicitly."
    }

    static func resolve(context: BuildContext) throws -> Self? {
        guard context.deviceIdentifier == nil else { return nil }
        if let identifier = context.simulatorIdentifier {
            return Self(identifier: identifier, multipleBooted: false)
        }
        let result = try Subprocess.runSeparated(
            "/usr/bin/xcrun", arguments: ["simctl", "list", "devices", "booted", "--json"])
        guard result.exitCode == 0 else {
            throw EmberError(stage: .watch, subject: "Simulator selection",
                             reason: result.standardError, recovery: .restart)
        }
        return try select(from: Data(result.standardOutput.utf8))
    }

    static func select(from bootedDevicesJSON: Data) throws -> Self {
        struct Device: Decodable { let udid: String; let state: String }
        struct DeviceList: Decodable { let devices: [String: [Device]] }
        let devices = try JSONDecoder().decode(DeviceList.self, from: bootedDevicesJSON).devices
        let identifiers = Set(devices.values.joined()
            .filter { $0.state == "Booted" }.map { $0.udid })
        guard let identifier = identifiers.min() else {
            throw EmberError(stage: .watch, subject: "Simulator selection",
                             reason: "no Simulator is booted. Boot a Simulator, then start the watcher.",
                             recovery: .restart)
        }
        return Self(identifier: identifier, multipleBooted: identifiers.count > 1)
    }
}
