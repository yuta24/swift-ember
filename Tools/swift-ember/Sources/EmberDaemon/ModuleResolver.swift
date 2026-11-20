import Foundation
import EmberCore

/// Resolves Swift sources in the selected build. The same lookup serves
/// startup diagnostics and the patch pipeline.
public struct ModuleResolver: Sendable {
    public struct Resolution: Hashable, Sendable {
        public let module: String
        public let manifest: URL?
        let packageTarget: String?
    }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        private let file: URL
        private let reason: String

        let hasNoOwner: Bool

        fileprivate init(_ file: URL, reason: String, hasNoOwner: Bool = false) {
            self.file = file
            self.reason = reason
            self.hasNoOwner = hasNoOwner
        }

        var rebuildDescription: String {
            "\(file.path): this new Swift source is missing from the current build. Add it to the target if needed, then rebuild and relaunch the app."
        }

        public var description: String {
            "\(file.path): \(reason). Build the selected targets and check the source roots, or set `sourceModules` in .swift-ember.json."
        }
    }

    public enum Membership: Sendable {
        case patchable(Resolution)
        case test
        case unresolved(Failure)
    }

    private struct ProjectMembership: Sendable {
        let files: Set<String>
        let directories: [(includes: SourcePathFilter, excludes: SourcePathFilter)]

        init(_ sources: BuildContext.XcodeProjectSources?) {
            let urls = (sources?.files ?? []).map { Self.canonicalPath($0) }
            files = Set(urls.map(\.path))
            directories = (sources?.directories ?? []).map {
                (SourcePathFilter(excluding: [Self.canonicalPath($0.path)]),
                 SourcePathFilter(excluding: $0.excludedPaths.map(Self.canonicalPath)))
            }
        }

        func contains(_ file: URL) -> Bool {
            files.contains(file.path) || directories.contains {
                $0.includes.excludes(file) && !$0.excludes.excludes(file)
            }
        }

        private static func canonicalPath(_ path: String) -> URL {
            ModuleResolver.canonical(URL(fileURLWithPath: path))
        }
    }

    private struct PackageDescription: Decodable {
        struct Target: Decodable {
            let name: String
            let module: String
            let type: String
            let moduleType: String
            let path: String
            let sources: [String]

            enum CodingKeys: String, CodingKey {
                case name, type, path, sources
                case module = "c99name"
                case moduleType = "module_type"
            }
        }

        let targets: [Target]
    }

    private struct PackageIndex: Sendable {
        let files: [String: Set<Resolution>]
        let testFiles: Set<String>
        let targetDirectories: SourcePathFilter
    }

    private struct PackageSources: Sendable {
        let manifestFiles: [URL: SourceFileStamp]
        let sources: Result<PackageIndex, PackageManifest.EvaluationError>
    }

    private let context: BuildContext
    private let cacheDirectory: URL
    private let overrides: [(path: String, module: String)]
    private let customAppSources: SourcePathFilter
    private let xcodeProjectTests: ProjectMembership
    private let xcodeProjectOthers: ProjectMembership
    private var xcodeTestSources: Set<String> = []
    private var packageSettings: [Resolution: PackageCompilerSettings] = [:]
    private var xcodeSources: [String: Set<String>] = [:]
    private var packages: [URL: PackageSources] = [:]
    private var packagesWithNewSources: Set<URL> = []

    public init(context: BuildContext, cacheDirectory: URL) {
        self.context = context
        self.cacheDirectory = cacheDirectory
        overrides = context.sourceModules.map {
            (Self.canonical(URL(fileURLWithPath: $0.key)).path, $0.value)
        }.sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return ($0.path, $0.module) < ($1.path, $1.module)
        }
        customAppSources = SourcePathFilter(excluding: context.sourceRoots.map {
            Self.canonical(URL(fileURLWithPath: $0))
        })
        xcodeProjectTests = ProjectMembership(context.xcodeTestSources)
        xcodeProjectOthers = ProjectMembership(context.xcodeNonTestSources)
        reset()
    }

    mutating func reset() {
        packages.removeAll()
        packagesWithNewSources.removeAll()
        packageSettings.removeAll()
        xcodeSources = [:]
        xcodeTestSources.removeAll()
        let arch = String(context.targetTriple.prefix { $0 != "-" })
        for target in context.xcodeSourceTargets ?? [] {
            let objects = URL(fileURLWithPath: target.directory)
                .appendingPathComponent("Objects-normal/\(arch)")
            let artifacts = (try? FileManager.default.contentsOfDirectory(
                at: objects, includingPropertiesForKeys: nil)) ?? []
            let modules = artifacts.filter { $0.pathExtension == "swiftmodule" }
            let module = target.module ?? (modules.count == 1
                ? modules[0].deletingPathExtension().lastPathComponent : nil)
            let lists = artifacts.filter {
                $0.pathExtension == "SwiftFileList"
                    && (target.productName == nil || $0.deletingPathExtension().lastPathComponent == target.productName)
            }
            guard lists.count == 1,
                  let paths = try? String(contentsOf: lists[0], encoding: .utf8) else { continue }
            for path in paths.split(whereSeparator: \.isNewline) where path.hasPrefix("/") {
                let file = Self.canonical(URL(fileURLWithPath: String(path)))
                if target.isTest == true {
                    xcodeTestSources.insert(file.path)
                } else if let module {
                    xcodeSources[file.path, default: []].insert(module)
                }
            }
        }
    }

    func compilerFlags(for module: String) -> [String]? {
        if module == context.moduleName { return context.extraCompilerFlags }
        return context.xcodeSourceTargets?.first { $0.module == module }?.compilerFlags
    }

    mutating func compilerSettings(for resolution: Resolution) -> PackageCompilerSettings {
        guard let manifest = resolution.manifest else {
            return compilerFlags(for: resolution.module).map(PackageCompilerSettings.flags)
                ?? .unknown("include the target in the watched Xcode scheme when invoking watch from the terminal")
        }
        if let cached = packageSettings[resolution] { return cached }
        let settings = PackageCompilerSettings.read(
            module: resolution.packageTarget ?? resolution.module, manifest: manifest,
            swiftCompilerPath: context.swiftCompilerPath, sdkName: context.sdkName, cacheDirectory: cacheDirectory)
        // A temporary SwiftPM error must remain retryable after startup.
        if case .flags = settings { packageSettings[resolution] = settings }
        return settings
    }

    /// New files can extend the file list even when the manifest is unchanged.
    mutating func refreshPackageSources(for added: Set<URL>) {
        for url in added {
            if let manifest = Self.nearestManifest(to: Self.canonical(url)) {
                packagesWithNewSources.insert(manifest)
            }
        }
    }

    public mutating func resolve(_ url: URL) -> Result<Resolution, Failure> {
        switch membership(of: url) {
        case .patchable(let resolution): return .success(resolution)
        case .test: return .failure(Failure(url, reason: "belongs to a test target"))
        case .unresolved(let failure): return .failure(failure)
        }
    }

    public mutating func isTestSource(_ url: URL) -> Bool {
        if case .test = membership(of: url) { return true }
        return false
    }

    public mutating func membership(of url: URL) -> Membership {
        let file = Self.canonical(url)
        let owningOverrides = overrides.filter { Self.contains(file.path, in: $0.path) }
        let explicit = owningOverrides.first
        if let explicit, Set(owningOverrides.prefix { $0.path == explicit.path }.map(\.module)).count > 1 {
            return .unresolved(Failure(url, reason: "conflicting sourceModules entries for the same path"))
        }

        func selection(_ candidates: Set<Resolution>) -> Membership? {
            if candidates.count > 1 {
                let names = Set(candidates.map(\.module)).sorted().joined(separator: ", ")
                return .unresolved(Failure(url, reason: "multiple targets compile this source (\(names))"))
            }
            return candidates.first.map(Membership.patchable)
        }

        let xcode = Set((xcodeSources[file.path] ?? []).map {
            Resolution(module: $0, manifest: nil, packageTarget: nil)
        })
        if let match = selection(xcode.filter { explicit == nil || $0.module == explicit?.module }) {
            return match
        }

        let declaredNonTest = xcodeProjectOthers.contains(file)
        let xcodeTest = explicit == nil && !declaredNonTest
            && (xcodeTestSources.contains(file.path) || xcodeProjectTests.contains(file))
        if let manifest = Self.nearestManifest(to: file) {
            switch packageSources(for: manifest) {
            case .success(let sources):
                let matches = sources.files[file.path] ?? []
                if let match = selection(matches.filter { explicit == nil || $0.module == explicit?.module }) {
                    return match
                }
                if xcodeTest || (explicit == nil && !declaredNonTest && sources.testFiles.contains(file.path)) {
                    return .test
                }
                if explicit == nil && (context.xcodeSourceTargets != nil || customAppSources.excludes(manifest)
                    || sources.targetDirectories.excludes(file)) {
                    return .unresolved(Failure(url, reason: "no selected Xcode or SwiftPM target includes this source", hasNoOwner: true))
                }
            case .failure(let error):
                if xcodeTest { return .test }
                if explicit == nil {
                    return .unresolved(Failure(url, reason: "could not read SwiftPM sources for \(manifest.path): \(error)"))
                }
            }
        }

        if xcodeTest { return .test }
        if let explicit {
            return .patchable(Resolution(module: explicit.module, manifest: nil, packageTarget: nil))
        }
        if context.xcodeSourceTargets == nil && customAppSources.excludes(file) {
            // Older hand-written build contexts declare the app's source tree
            // through sourceRoots. Xcode contexts always require membership.
            return .patchable(Resolution(module: context.moduleName, manifest: nil, packageTarget: nil))
        }
        return .unresolved(Failure(url, reason: "no selected build target includes this source", hasNoOwner: true))
    }

    private mutating func packageSources(
        for manifest: URL
    ) -> Result<PackageIndex, PackageManifest.EvaluationError> {
        let root = manifest.deletingLastPathComponent()
        let stamps = Dictionary(uniqueKeysWithValues: PackageManifest.files(beside: manifest).compactMap { url in
            (try? SourceFileStamp.read(from: url)).map { (url, $0) }
        })
        let hasNewSources = packagesWithNewSources.remove(manifest) != nil
        if let cached = packages[manifest], cached.manifestFiles == stamps, !hasNewSources {
            return cached.sources
        }

        if packages[manifest]?.manifestFiles != stamps {
            packageSettings = packageSettings.filter { $0.key.manifest != manifest }
        }
        let sources: Result<PackageIndex, PackageManifest.EvaluationError>
        do {
            let data = try PackageManifest.run(
                ["describe", "--type", "json"], manifest: manifest,
                swiftCompilerPath: context.swiftCompilerPath, cacheDirectory: cacheDirectory)
            let package = try JSONDecoder().decode(PackageDescription.self, from: data)
            var files: [String: Set<Resolution>] = [:]
            var testFiles: Set<String> = []
            for target in package.targets where target.moduleType == "SwiftTarget" {
                let directory = root.appendingPathComponent(target.path, isDirectory: true)
                let resolution = Resolution(module: target.module, manifest: manifest, packageTarget: target.name)
                for source in target.sources where source.hasSuffix(".swift") {
                    let path = Self.canonical(directory.appendingPathComponent(source)).path
                    switch target.type {
                    case "library", "executable": files[path, default: []].insert(resolution)
                    case "test": testFiles.insert(path)
                    default: break
                    }
                }
            }
            let targets = package.targets.map { Self.canonical(root.appendingPathComponent($0.path)) }
            sources = .success(PackageIndex(files: files, testFiles: testFiles, targetDirectories: SourcePathFilter(excluding: targets)))
        } catch {
            sources = .failure(PackageManifest.EvaluationError(description: String(describing: error)))
        }
        packages[manifest] = PackageSources(manifestFiles: stamps, sources: sources)
        return sources
    }

    private static func nearestManifest(to file: URL) -> URL? {
        var directory = file.deletingLastPathComponent()
        while true {
            let manifest = directory.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: manifest.path) { return manifest }
            if directory.path == "/" { return nil }
            directory = directory.deletingLastPathComponent()
        }
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? root : root + "/")
    }
}
