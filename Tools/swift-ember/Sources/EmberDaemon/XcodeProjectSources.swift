import Foundation
import EmberCore

extension XcodeProject {
    static func projectSources(in settings: [[String: String]])
        -> (test: BuildContext.XcodeProjectSources, other: BuildContext.XcodeProjectSources) {
        var visited: Set<String> = []
        var test = BuildContext.XcodeProjectSources()
        var other = BuildContext.XcodeProjectSources()
        for settings in settings {
            guard let project = settings["PROJECT_FILE_PATH"], visited.insert(project).inserted,
                  let plist = readProject(at: project),
                  let objects = plist["objects"] as? [String: [String: Any]],
                  let root = plist["rootObject"] as? String,
                  let main = objects[root]?["mainGroup"] as? String else { continue }
            let directory = settings["SRCROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? URL(fileURLWithPath: project).deletingLastPathComponent()
            var paths: [String: URL] = [:]
            var visitedGroups: Set<String> = []
            func collect(_ id: String, in parent: URL) {
                guard let object = objects[id], visitedGroups.insert(id).inserted else { return }
                let path = object["path"] as? String
                let url: URL
                switch object["sourceTree"] as? String {
                case "<group>", nil: url = path.map { parent.appendingPathComponent($0) } ?? parent
                case "SOURCE_ROOT", "PROJECT_DIR": url = path.map { directory.appendingPathComponent($0) } ?? directory
                case "<absolute>":
                    guard let path, path.hasPrefix("/") else { return }
                    url = URL(fileURLWithPath: path)
                default: return
                }
                if path != nil { paths[id] = url }
                for child in object["children"] as? [String] ?? [] { collect(child, in: url) }
            }
            collect(main, in: directory)

            for (id, target) in objects where target["isa"] as? String == "PBXNativeTarget" {
                var sources = BuildContext.XcodeProjectSources()
                let sourcePhases = (target["buildPhases"] as? [String] ?? []).filter {
                    objects[$0]?["isa"] as? String == "PBXSourcesBuildPhase"
                }
                for phase in sourcePhases {
                    for file in objects[phase]?["files"] as? [String] ?? [] {
                        guard let ref = objects[file]?["fileRef"] as? String,
                              let url = paths[ref], url.pathExtension == "swift" else { continue }
                        sources.files.append(url.path)
                    }
                }
                for group in target["fileSystemSynchronizedGroups"] as? [String] ?? [] {
                    guard let path = paths[group], let object = objects[group] else { continue }
                    let exceptions = (object["exceptions"] as? [String] ?? []).flatMap { exception -> [String] in
                        guard let entry = objects[exception] else { return [] }
                        switch entry["isa"] as? String {
                        case "PBXFileSystemSynchronizedBuildFileExceptionSet" where entry["target"] as? String == id,
                             "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet"
                             where (entry["buildPhase"] as? String).map(sourcePhases.contains) == true:
                            return entry["membershipExceptions"] as? [String] ?? []
                        default:
                            return []
                        }
                    }
                    sources.directories.append(.init(path: path.path, excludedPaths: exceptions.map {
                        path.appendingPathComponent($0).path
                    }))
                }
                if isTestTarget(target["productType"] as? String) {
                    test.files += sources.files
                    test.directories += sources.directories
                } else {
                    other.files += sources.files
                    other.directories += sources.directories
                }
            }
        }
        return (test, other)
    }
}
