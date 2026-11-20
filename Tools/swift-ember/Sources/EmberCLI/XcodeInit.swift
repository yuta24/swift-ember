import Foundation

public enum XcodeInit {
    public static func run(options: Options) throws {
        guard let containerPath = options.project ?? options.workspace else {
            throw InitError("init requires an Xcode project or workspace")
        }
        let requestedContainer = URL(fileURLWithPath: containerPath, isDirectory: true).standardizedFileURL
        let containerPaths = try InitPaths(root: requestedContainer.deletingLastPathComponent())
        let container = try containerPaths.validate(requestedContainer).url
        let expectedExtension = options.project == nil ? "xcworkspace" : "xcodeproj"
        guard container.pathExtension == expectedExtension else {
            throw InitError("expected a .\(expectedExtension) at \(container.path)")
        }
        guard let scheme = options.scheme, !scheme.isEmpty, scheme == (scheme as NSString).lastPathComponent else {
            throw InitError("specify a shared Xcode scheme by name")
        }
        let configURL = options.configPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? containerPaths.root.appendingPathComponent(ProjectConfiguration.fileName)
        let configFile = try containerPaths.validate(configURL)
        let projects = options.project == nil ? try workspaceProjects(in: container, paths: containerPaths) : []
        let (schemeFile, schemePaths) = try sharedScheme(scheme, in: container, paths: containerPaths, projects: projects)
        let schemeData = try Data(contentsOf: schemeFile)
        let document = try XMLDocument(data: schemeData, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard let schemeElement = document.rootElement(), schemeElement.name == "Scheme",
              let buildAction = schemeElement.elements(forName: "BuildAction").first else {
            throw InitError("\(schemeFile.path) has no Build action")
        }
        let references = try buildAction.nodes(forXPath: "BuildActionEntries/BuildActionEntry/BuildableReference")
            .compactMap { $0 as? XMLElement }
            .filter { $0.attribute(forName: "BuildableName")?.stringValue?.hasSuffix(".app") == true }
        // doctor and watch also require the scheme to select a single app.
        guard references.count == 1, let reference = references.first,
              let targetID = reference.attribute(forName: "BlueprintIdentifier")?.stringValue,
              let referencedContainer = reference.attribute(forName: "ReferencedContainer")?.stringValue,
              referencedContainer.hasPrefix("container:") else {
            throw InitError("the scheme's Build action must select a single app target")
        }
        // A workspace can expose a scheme owned by one of its projects.
        let requestedProject = URL(fileURLWithPath: String(referencedContainer.dropFirst("container:".count)),
                                   isDirectory: true, relativeTo: schemePaths.root).standardizedFileURL
        guard requestedProject.pathExtension == "xcodeproj" else {
            throw InitError("the app's Build action must reference the selected project or a project in the workspace")
        }
        // Workspaces may explicitly list projects in neighboring directories.
        let projectBoundary = projects.contains(where: { $0.path == requestedProject.path })
            ? try InitPaths(root: requestedProject.deletingLastPathComponent()) : containerPaths
        let projectURL = try projectBoundary.validate(requestedProject).url
        if options.project != nil, projectURL.path != container.path {
            throw InitError("the app's Build action must reference the selected project")
        }
        let projectPaths = try InitPaths(root: projectURL.deletingLastPathComponent())
        let configuration = options.configuration
        guard !configuration.isEmpty, configuration.caseInsensitiveCompare("Release") != .orderedSame,
              !schemeElement.elements(forName: "ArchiveAction").contains(where: {
                  $0.attribute(forName: "buildConfiguration")?.stringValue == configuration
              }) else {
            throw InitError("choose the app's development configuration; init cannot enable Ember for its Archive configuration")
        }

        let projectFile = try projectPaths.validate(projectURL.appendingPathComponent("project.pbxproj")).url
        let project = try InitProject(file: projectFile, root: projectPaths.root)
        let setting = try project.debugConfiguration(targetID: targetID, name: configuration)
        let base = try project.baseConfiguration(setting.object)
        var changes: [Change] = []

        let template = options.emberXCConfig.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let xcconfigs = XCConfigs(paths: projectPaths, template: template)
        if let template {
            guard try xcconfigs.containsEmber(template) else {
                throw InitError("\(template.path) must include the Debug Ember settings")
            }
        }
        if let base, try xcconfigs.containsEmber(base) {
            print("Keep \(base.path) (already includes the Ember settings)")
        } else if base == nil, let projectBase = try project.projectBaseConfiguration(named: configuration),
                  try xcconfigs.containsEmber(projectBase) {
            print("Keep the inherited Ember settings in \(projectBase.path)")
        } else {
            let integration = try template ?? xcconfigs.findTemplate()
            let includeLines = try [base, integration].compactMap { $0 }.map { file in
                let path = relativePath(to: file, from: project.root)
                guard !path.contains(where: { $0.isNewline || $0 == "\"" || $0 == "\\" }) else {
                    throw InitError("cannot quote this xcconfig include path: \(path)")
                }
                return "#include \"\(path)\""
            }
            let name = "Ember.\(setting.targetName).\(configuration).xcconfig"
            guard name == (name as NSString).lastPathComponent,
                  !name.contains(where: { $0.isNewline || $0.isASCII && $0 < " " }) else {
                throw InitError("cannot use '\(name)' as the generated xcconfig filename")
            }
            let wrapper = try projectPaths.validate(project.root.appendingPathComponent(name))
            let text = "// Generated by swift-ember init. Set as the app target's \(configuration) base configuration.\n"
                + includeLines.joined(separator: "\n") + "\n"
            if wrapper.exists {
                guard try Data(contentsOf: wrapper.url) == Data(text.utf8) else {
                    throw InitError("\(wrapper.url.path) already exists with different contents")
                }
            } else {
                changes.append(Change(wrapper.url, in: projectPaths, new: Data(text.utf8), preview: text))
            }
            let updated = try project.settingBaseConfiguration(name, for: setting.id, previous: setting.object)
            changes.append(Change(project.file, in: projectPaths, old: project.data, new: Data(updated.utf8),
                                  preview: "Set the \(setting.targetName) target's \(configuration) Base Configuration to \(name)."))
        }

        if configFile.exists {
            let existing = try ProjectConfiguration.load(from: configFile.url)
            let path = options.project == nil ? existing.workspace : existing.project
            guard let path,
                  URL(fileURLWithPath: path, relativeTo: configURL.deletingLastPathComponent())
                    .standardizedFileURL.resolvingSymlinksInPath().path == container.path,
                  existing.scheme == scheme, (existing.configuration ?? "Debug") == configuration else {
                throw InitError("\(configURL.path) already configures a different target; align it with this project, scheme and configuration")
            }
            print("Keep \(configURL.path)")
        } else {
            let configRoot = configURL.deletingLastPathComponent()
            var values: [String: Any] = [
                options.project == nil ? "workspace" : "project": relativePath(to: container, from: configRoot),
                "scheme": scheme,
                "configuration": configuration,
            ]
            if !options.sourceRoots.isEmpty {
                values["sources"] = options.sourceRoots.map {
                    relativePath(to: URL(fileURLWithPath: $0), from: configRoot)
                }
            }
            if let excludes = options.excludedSourcePaths {
                values["exclude"] = excludes.map { relativePath(to: URL(fileURLWithPath: $0), from: configRoot) }
            }
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                + Data("\n".utf8)
            changes.append(Change(configFile.url, in: containerPaths, new: data, preview: String(decoding: data, as: UTF8.self)))
        }

        var scripts: [String] = []
        var source = try SchemeSource(schemeData, root: schemeElement)
        let configPath = relativePath(to: configURL, from: project.root)
        for (element, action) in [("PreActions", Options.XcodeAction.prepare),
                                  ("PostActions", options.initPostAction ?? .record)] {
            if let script = try addAction(element, action: action, to: buildAction, source: &source,
                                          reference: reference, configuration: configuration, configPath: configPath,
                                          replaceGenerated: options.initPostAction != nil) {
                scripts.append("Build \(element) with settings from \(setting.targetName)\n\(script)")
            }
        }
        if !scripts.isEmpty {
            changes.append(Change(schemeFile, in: schemePaths, old: schemeData, new: try source.data(validating: schemeElement),
                                  preview: scripts.joined(separator: "\n")))
        }

        for change in changes {
            print("\(change.old == nil ? "Create" : "Update") \(change.url.path)\n\(change.preview)")
        }
        if changes.isEmpty {
            print("Already configured.")
        } else if options.writesInit {
            for change in changes { _ = try change.validate() }
            for change in changes { try change.apply() }
            print("Applied \(changes.count) file changes. Clean the build folder before the first recorded build.")
        } else {
            print("Dry run. Pass --write to apply.")
        }
    }

    private static func addAction(_ element: String, action: Options.XcodeAction, to buildAction: XMLElement,
                                  source: inout SchemeSource,
                                  reference: XMLElement, configuration: String, configPath: String,
                                  replaceGenerated: Bool) throws -> String? {
        func script(for action: Options.XcodeAction) -> String {
            """
            [ "${CONFIGURATION:-}" = \(shellQuote(configuration)) ] || exit 0
            export PATH="$HOME/.local/bin:$PATH"
            exec "${SWIFT_EMBER_CLI:-swift-ember}" xcode \(action.rawValue) --config "$PROJECT_DIR/"\(shellQuote(configPath))
            """
        }

        let lists = buildAction.elements(forName: element)
        guard lists.count <= 1 else { throw InitError("the scheme has multiple Build \(element) blocks") }
        let actions = lists.first ?? XMLElement(name: element)
        let verbs = action == .prepare ? "prepare" : "(?:record|start)"
        let matches = try actions.nodes(forXPath: "ExecutionAction/ActionContent").compactMap { $0 as? XMLElement }
            .filter { content in
                content.attribute(forName: "scriptText")?.stringValue?
                    .range(of: "\\bxcode\\s+\(verbs)\\b", options: .regularExpression) != nil
            }
        if !matches.isEmpty {
            let expected = reference.attribute(forName: "BlueprintIdentifier")?.stringValue
            let environments = matches[0].elements(forName: "EnvironmentBuildable")
                .flatMap { $0.elements(forName: "BuildableReference") }
            guard matches.count == 1, environments.count == 1,
                  environments[0].attribute(forName: "BlueprintIdentifier")?.stringValue == expected,
                  environments[0].attribute(forName: "ReferencedContainer")?.stringValue
                    == reference.attribute(forName: "ReferencedContainer")?.stringValue else {
                throw InitError("review the existing Ember Build \(element) in Xcode; keep one action and provide settings from the app target")
            }
            if replaceGenerated && action != .prepare,
               let scriptAttribute = matches[0].attribute(forName: "scriptText"),
               let existing = scriptAttribute.stringValue,
               existing.range(of: "\\bxcode\\s+\(action.rawValue)\\b", options: .regularExpression) == nil {
                let other: Options.XcodeAction = action == .record ? .start : .record
                guard existing == script(for: other) else {
                    throw InitError("the existing Ember action has a custom script; change its post-action in Xcode")
                }
                let updated = script(for: action)
                try source.replace("scriptText", on: matches[0], with: updated)
                scriptAttribute.stringValue = updated
                if let title = matches[0].attribute(forName: "title"), title.stringValue == "swift-ember \(other.rawValue)" {
                    let newTitle = "swift-ember \(action.rawValue)"
                    try source.replace("title", on: matches[0], with: newTitle)
                    title.stringValue = newTitle
                }
                return updated
            }
            print("Keep the existing Ember Build \(element)")
            return nil
        }

        let script = script(for: action)
        let execution = XMLElement(name: "ExecutionAction")
        attribute("ActionType", "Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction", on: execution)
        let content = XMLElement(name: "ActionContent")
        attribute("title", "swift-ember \(action.rawValue)", on: content)
        attribute("scriptText", script, on: content)
        let environment = XMLElement(name: "EnvironmentBuildable")
        environment.addChild(reference.copy() as! XMLElement)
        content.addChild(environment)
        execution.addChild(content)
        if lists.isEmpty {
            // Both sections precede BuildActionEntries in Xcode's schema.
            let next = element == "PreActions" ? ["PostActions", "BuildActionEntries"] : ["BuildActionEntries"]
            guard let anchor = buildAction.children?.compactMap({ $0 as? XMLElement })
                .first(where: { $0.name.map(next.contains) == true }) else {
                throw InitError("cannot find where to add \(element). Set up the Ember Build actions manually in Xcode.")
            }
            actions.addChild(execution)
            try source.insert(actions, before: anchor, in: buildAction)
            buildAction.insertChild(actions, at: anchor.index)
        } else {
            try source.insert(execution, before: actions, in: buildAction, beforeClosingTag: true)
            actions.addChild(execution)
        }
        return script
    }

    private static func attribute(_ name: String, _ value: String, on element: XMLElement) {
        element.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func sharedScheme(_ name: String, in container: URL, paths: InitPaths,
                                     projects: [URL]) throws -> (URL, InitPaths) {
        let suffix = "xcshareddata/xcschemes/\(name).xcscheme"
        let owned = try paths.validate(container.appendingPathComponent(suffix))
        if owned.exists { return (owned.url, paths) }

        var matches: [URL: InitPaths] = [:]
        for project in projects {
            let boundary = try InitPaths(root: project.deletingLastPathComponent())
            let projectURL = try boundary.validate(project).url
            let projectPaths = try InitPaths(root: projectURL.deletingLastPathComponent())
            let scheme = try projectPaths.validate(projectURL.appendingPathComponent(suffix))
            if scheme.exists { matches[scheme.url] = projectPaths }
        }
        if matches.count == 1, let match = matches.first { return (match.key, match.value) }
        if matches.count > 1 {
            throw InitError("multiple workspace projects share a scheme named \(name); use a unique shared scheme")
        }
        throw InitError("no shared scheme named \(name) in \(container.path); share it in Xcode first")
    }

    private static func workspaceProjects(in workspace: URL, paths: InitPaths) throws -> [URL] {
        let file = try paths.validate(workspace.appendingPathComponent("contents.xcworkspacedata")).url
        let document = try XMLDocument(data: Data(contentsOf: file), options: [.nodeLoadExternalEntitiesNever])
        func projects(in node: XMLElement, relativeTo directory: URL) -> [URL] {
            node.children?.compactMap { $0 as? XMLElement }.flatMap { child -> [URL] in
                guard let location = child.attribute(forName: "location")?.stringValue else { return [] }
                let parts = location.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return [] }
                let base: URL
                switch parts[0] {
                case "group": base = directory
                case "container": base = paths.root
                case "absolute": base = URL(fileURLWithPath: "/")
                default: return []
                }
                let url = URL(fileURLWithPath: String(parts[1]), isDirectory: true, relativeTo: base).standardizedFileURL
                if child.name == "Group" { return projects(in: child, relativeTo: url) }
                return child.name == "FileRef" && url.pathExtension == "xcodeproj" ? [url] : []
            } ?? []
        }
        guard let element = document.rootElement() else { return [] }
        return projects(in: element, relativeTo: paths.root)
    }

    private struct XCConfigs {
        let paths: InitPaths
        let template: URL?

        private var templateLocations: [(file: URL, root: URL)] {
            var result: [(URL, URL)] = []
            var directory = paths.root
            while directory.path != "/" {
                result.append((directory.appendingPathComponent("integrations/xcode/Ember.xcconfig"), directory))
                directory.deleteLastPathComponent()
            }
            return result
        }

        private func validate(_ file: URL, in scope: InitPaths) throws -> (InitPaths.Entry, InitPaths) {
            if let template, template.path == file.path {
                let templatePaths = try InitPaths(root: template.deletingLastPathComponent())
                return (try templatePaths.validate(file), templatePaths)
            }
            if let location = templateLocations.first(where: { $0.file.standardizedFileURL.path == file.path }) {
                let directory = try InitPaths(root: location.root).validate(file.deletingLastPathComponent()).url
                let templatePaths = try InitPaths(root: directory)
                return (try templatePaths.validate(file), templatePaths)
            }
            return (try scope.validate(file), scope)
        }

        func findTemplate() throws -> URL {
            let local = paths.root.appendingPathComponent("Ember.xcconfig")
            for file in [local] + templateLocations.map(\.file) {
                if try containsEmber(file, required: false) { return file }
            }
            throw InitError("locate integrations/xcode/Ember.xcconfig in a swift-ember checkout and pass --ember-xcconfig <path>")
        }

        func containsEmber(_ file: URL, required: Bool = true) throws -> Bool {
            let include = try NSRegularExpression(pattern: #"(?m)^\s*#include\??\s+"([^"\r\n]+)""#)
            var pending = [(file, paths, required)]
            var visited: Set<URL> = []
            while let (next, scope, required) = pending.popLast() {
                let (entry, includeScope) = try validate(next.standardizedFileURL, in: scope)
                if !entry.exists {
                    if required { throw InitError("missing xcconfig at \(next.path)") }
                    continue
                }
                guard visited.insert(entry.url).inserted else { continue }
                let text = try String(contentsOf: entry.url, encoding: .utf8)
                if text.range(of: #"(?m)^\s*EMBER_CONFIGURED\s*=\s*YES\b"#, options: .regularExpression) != nil,
                   text.contains("-enable-implicit-dynamic"), text.contains("-enable-private-imports") {
                    return true
                }
                for match in include.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range(at: 1), in: text) else { continue }
                    let path = URL(fileURLWithPath: String(text[range]), relativeTo: next.deletingLastPathComponent())
                        .standardizedFileURL
                    pending.append((path, includeScope, false))
                }
            }
            return false
        }
    }

    private struct Change {
        let url: URL
        let paths: InitPaths
        let old: Data?
        let new: Data
        let preview: String

        init(_ url: URL, in paths: InitPaths, old: Data? = nil, new: Data, preview: String) {
            self.url = url
            self.paths = paths
            self.old = old
            self.new = new
            self.preview = preview
        }

        func validate() throws -> URL {
            let checked = try paths.validate(url)
            guard checked.url.path == url.path else {
                throw InitError("\(url.path) changed while planning init; retry")
            }
            if old == nil {
                guard !checked.exists else { throw InitError("\(url.path) appeared while planning init; retry") }
            } else {
                guard try Data(contentsOf: checked.url) == old else {
                    throw InitError("\(url.path) changed while planning init; retry")
                }
            }
            return checked.url
        }

        func apply() throws {
            let checked = try validate()
            try new.write(to: checked, options: old == nil ? .withoutOverwriting : .atomic)
        }
    }

    private static func relativePath(to file: URL, from directory: URL) -> String {
        let destination = file.standardizedFileURL.pathComponents
        let source = directory.standardizedFileURL.pathComponents
        let shared = zip(destination, source).prefix(while: ==).count
        let components = Array(repeating: "..", count: source.count - shared) + destination.dropFirst(shared)
        return components.isEmpty ? "." : components.joined(separator: "/")
    }
}

struct InitError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
