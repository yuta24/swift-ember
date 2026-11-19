import Foundation

/// Read the project with Foundation's OpenStep parser. Edit only the selected
/// configuration and its new file reference so Xcode comments and unrelated
/// settings survive the update.
struct InitProject {
    let root: URL
    let file: URL
    let data: Data
    private let text: String
    private let objects: [String: [String: Any]]
    private let mainGroup: String
    private let projectConfigurationIDs: [String]

    init(at project: URL) throws {
        root = project.deletingLastPathComponent()
        file = project.appendingPathComponent("project.pbxproj")
        data = try Data(contentsOf: file)
        guard let text = String(data: data, encoding: .utf8),
              let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = propertyList["objects"] as? [String: [String: Any]],
              let rootID = propertyList["rootObject"] as? String,
              let projectObject = objects[rootID],
              let mainGroup = projectObject["mainGroup"] as? String,
              (projectObject["projectDirPath"] as? String ?? "").isEmpty else {
            throw InitError("unsupported Xcode project layout at \(file.path)")
        }
        self.text = text
        self.objects = objects
        self.mainGroup = mainGroup
        let configurationList = projectObject["buildConfigurationList"] as? String ?? ""
        self.projectConfigurationIDs = objects[configurationList]?["buildConfigurations"] as? [String] ?? []
    }

    func debugConfiguration(targetID: String, name: String) throws -> (targetName: String, id: String, object: [String: Any]) {
        guard let target = objects[targetID], target["isa"] as? String == "PBXNativeTarget",
              target["productType"] as? String == "com.apple.product-type.application",
              let targetName = target["name"] as? String,
              let configurationList = target["buildConfigurationList"] as? String,
              let identifiers = objects[configurationList]?["buildConfigurations"] as? [String] else {
            throw InitError("the scheme does not reference an application target in \(file.path)")
        }
        let matching = identifiers.filter { objects[$0]?["name"] as? String == name }
        guard matching.count == 1, let id = matching.first, let object = objects[id] else {
            throw InitError("there is no unique \(name) configuration for the \(targetName) target")
        }
        let overrides = (object["buildSettings"] as? [String: Any] ?? [:]).compactMap { key, value -> String? in
            let setting = key.split(separator: "[", maxSplits: 1).first
            let values = value as? [String] ?? [value as? String ?? ""]
            switch setting {
            case "SWIFT_ACTIVE_COMPILATION_CONDITIONS", "OTHER_SWIFT_FLAGS":
                return values.contains { $0.contains("$(inherited)") || $0.contains("${inherited}") } ? nil : key
            case "ENABLE_TESTABILITY", "SWIFT_ENABLE_TESTABILITY":
                return values == ["YES"] ? nil : key
            case "SWIFT_OPTIMIZATION_LEVEL":
                return values == ["-Onone"] ? nil : key
            default:
                return nil
            }
        }
        if !overrides.isEmpty {
            throw InitError("\(targetName) (\(name)) overrides \(overrides.sorted().joined(separator: ", ")). In Xcode, inherit the xcconfig values (use $(inherited) for flags and conditions), then rerun init.")
        }
        return (targetName, id, object)
    }

    func baseConfiguration(_ configuration: [String: Any]) throws -> URL? {
        if let reference = configuration["baseConfigurationReference"] as? String {
            guard configuration["baseConfigurationReferenceAnchor"] == nil,
                  configuration["baseConfigurationReferenceRelativePath"] == nil,
                  let url = location(of: reference) else {
                throw InitError("cannot resolve the existing Base Configuration; configure its Ember include manually")
            }
            return url
        }
        let anchor = configuration["baseConfigurationReferenceAnchor"] as? String
        let relative = configuration["baseConfigurationReferenceRelativePath"] as? String
        if anchor == nil && relative == nil { return nil }
        guard let anchor, let relative, !relative.isEmpty, !relative.hasPrefix("/"),
              let directory = location(of: anchor) else {
            throw InitError("cannot resolve the existing folder-relative Base Configuration; configure its Ember include manually")
        }
        return directory.appendingPathComponent(relative).standardizedFileURL
    }

    func projectBaseConfiguration(named name: String) throws -> URL? {
        guard let configuration = projectConfigurationIDs.compactMap({ objects[$0] })
            .first(where: { $0["name"] as? String == name }) else { return nil }
        return try baseConfiguration(configuration)
    }

    private func location(of id: String, visited: Set<String> = []) -> URL? {
        guard let object = objects[id], !visited.contains(id),
              let sourceTree = object["sourceTree"] as? String else { return nil }
        let path = object["path"] as? String ?? ""
        guard !path.contains("$("), !path.contains("${") else { return nil }
        switch sourceTree {
        case "<absolute>":
            return path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL : nil
        case "SOURCE_ROOT", "PROJECT_DIR":
            return root.appendingPathComponent(path).standardizedFileURL
        case "<group>":
            if id == mainGroup { return root.appendingPathComponent(path).standardizedFileURL }
            let parents = objects.filter { ($0.value["children"] as? [String])?.contains(id) == true }
            guard parents.count == 1, let parent = parents.first,
                  let base = location(of: parent.key, visited: visited.union([id])) else { return nil }
            return base.appendingPathComponent(path).standardizedFileURL
        default:
            return nil
        }
    }

    func settingBaseConfiguration(_ name: String, for configuration: String, previous: [String: Any]) throws -> String {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))
        let quotedName = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let objectsStart = try uniqueMatch(#"(?m)^[\t ]*objects\s*=\s*\{"#, in: text)
        let group = try objectRange(mainGroup)
        let children = try uniqueMatch(#"(?m)^[\t ]*children\s*=\s*\("#, in: text, within: group)
        let childrenInsertion = children.upperBound
        let selected = try objectRange(configuration)
        var body = String(text[selected])
        for key in ["baseConfigurationReference", "baseConfigurationReferenceAnchor", "baseConfigurationReferenceRelativePath"]
        where previous[key] != nil {
            let field = try uniqueMatch(#"(?m)^[\t ]*\#(key)\s*=\s*(?:"(?:\\.|[^"\\])*"|[^;\r\n])+;[\t ]*\r?\n"#, in: body)
            body.removeSubrange(field)
        }
        body = newline + "\t\t\tbaseConfigurationReference = \(id);" + body
        let edits: [(Range<String.Index>, String)] = [
            (selected, body),
            (childrenInsertion..<childrenInsertion, newline + "\t\t\t\t\(id),"),
            (objectsStart.upperBound..<objectsStart.upperBound,
             newline + "\t\t\(id) = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; "
                 + "path = \"\(quotedName)\"; sourceTree = SOURCE_ROOT; };"),
        ]
        var updated = text
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            updated.replaceSubrange(range, with: replacement)
        }
        guard let propertyList = try PropertyListSerialization.propertyList(from: Data(updated.utf8), format: nil) as? [String: Any],
              let updatedObjects = propertyList["objects"] as? [String: [String: Any]],
              updatedObjects[configuration]?["baseConfigurationReference"] as? String == id,
              updatedObjects[id]?["path"] as? String == name,
              (updatedObjects[mainGroup]?["children"] as? [String])?.contains(id) == true else {
            throw InitError("could not verify the Base Configuration edit for \(file.path)")
        }
        return updated
    }

    private func objectRange(_ id: String) throws -> Range<String.Index> {
        let key = NSRegularExpression.escapedPattern(for: id)
        let open = try uniqueMatch(#"(?m)^[\t ]*\#(key)(?:[\t ]*/\*[^\r\n]*?\*/)?\s*=\s*\{"#, in: text)
        // Skip braces inside strings and comments while finding the end of
        // the selected object, which also contains a buildSettings dictionary.
        let tokens = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|/\*[\s\S]*?\*/|//[^\r\n]*|[{}]"#)
        var depth = 1
        var close: Range<String.Index>?
        tokens.enumerateMatches(in: text, range: NSRange(open.upperBound..., in: text)) { match, _, stop in
            guard let match, let range = Range(match.range, in: text) else { return }
            switch text[range] {
            case "{": depth += 1
            case "}": depth -= 1
            default: break
            }
            if depth == 0 {
                close = range
                stop.pointee = true
            }
        }
        guard let close else { throw InitError("no closing brace for \(id) in \(file.path)") }
        return open.upperBound..<close.lowerBound
    }

    private func uniqueMatch(_ pattern: String, in source: String,
                             within range: Range<String.Index>? = nil) throws -> Range<String.Index> {
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: source, range: NSRange(range ?? source.startIndex..<source.endIndex, in: source))
        guard matches.count == 1, let match = matches.first, let range = Range(match.range, in: source) else {
            throw InitError("cannot edit this formatting in \(file.path); configure the Base Configuration manually")
        }
        return range
    }
}
