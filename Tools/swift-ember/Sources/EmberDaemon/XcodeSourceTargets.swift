import Foundation
import EmberCore

extension XcodeProject {
    static func sourceTargets(
        appSettings: [String: String], queriedTargets: [[String: String]]
    ) -> [BuildContext.XcodeSourceTarget] {
        let settings = [appSettings] + queriedTargets.filter {
            $0["WRAPPER_EXTENSION"] == "framework" || isTestTarget($0["PRODUCT_TYPE"])
                || $0["WRAPPER_EXTENSION"] == "xctest"
        }
        var seenDirectories: Set<String> = []
        var targets = settings.compactMap { target -> BuildContext.XcodeSourceTarget? in
            guard let directory = target["TARGET_TEMP_DIR"], directory.hasPrefix("/"),
                  let module = target["PRODUCT_MODULE_NAME"] ?? target["PRODUCT_NAME"], !module.isEmpty,
                  seenDirectories.insert(directory).inserted else { return nil }
            let isTest = isTestTarget(target["PRODUCT_TYPE"]) || target["WRAPPER_EXTENSION"] == "xctest"
            return .init(directory: directory, productName: target["PRODUCT_NAME"],
                         module: module, compilerFlags: isTest ? nil : compilerFlags(from: target), isTest: isTest)
        }

        // xcodebuild reports scheme entries. The build action environment
        // contains only the app's settings. Follow local project dependencies
        // in both cases to find frameworks that actually belong to the graph.
        for target in settings {
            guard let directory = target["CONFIGURATION_TEMP_DIR"], directory.hasPrefix("/") else { continue }
            for name in localFrameworkDependencies(from: target) {
                let buildDirectory = URL(fileURLWithPath: directory).appendingPathComponent(name + ".build").path
                if seenDirectories.insert(buildDirectory).inserted {
                    targets.append(.init(directory: buildDirectory))
                }
            }
        }
        return targets
    }

    private static func localFrameworkDependencies(from settings: [String: String]) -> [String] {
        guard let project = settings["PROJECT_FILE_PATH"], let name = settings["TARGET_NAME"],
              let objects = readProject(at: project)?["objects"] as? [String: [String: Any]],
              let root = objects.first(where: {
                  $0.value["isa"] as? String == "PBXNativeTarget" && $0.value["name"] as? String == name
              })?.key else { return [] }

        let targetsByProduct = objects.reduce(into: [String: String]()) { products, object in
            if let ref = object.value["productReference"] as? String { products[ref] = object.key }
        }
        var visited: Set<String> = [root]
        var pending = [root]
        var frameworks: [String] = []
        while let id = pending.popLast(), let target = objects[id] {
            if target["productType"] as? String == "com.apple.product-type.framework",
               let name = target["name"] as? String, name != settings["TARGET_NAME"] {
                frameworks.append(name)
            }

            for dependency in target["dependencies"] as? [String] ?? [] {
                if let id = objects[dependency]?["target"] as? String, visited.insert(id).inserted {
                    pending.append(id)
                }
            }

            // Link phases can make another target an implicit dependency.
            for phase in target["buildPhases"] as? [String] ?? []
            where objects[phase]?["isa"] as? String == "PBXFrameworksBuildPhase" {
                for file in objects[phase]?["files"] as? [String] ?? [] {
                    if let ref = objects[file]?["fileRef"] as? String,
                       let id = targetsByProduct[ref], visited.insert(id).inserted {
                        pending.append(id)
                    }
                }
            }
        }
        return frameworks.sorted()
    }

    static func readProject(at path: String) -> [String: Any]? {
        let file = URL(fileURLWithPath: path).appendingPathComponent("project.pbxproj")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    static func isTestTarget(_ productType: String?) -> Bool {
        productType == "com.apple.product-type.bundle.unit-test"
            || productType == "com.apple.product-type.bundle.ui-testing"
    }
}
