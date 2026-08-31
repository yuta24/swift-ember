import Foundation

/// Commit-friendly project defaults for commands that would otherwise repeat
/// the same Xcode container, scheme, and source roots on every invocation.
struct ProjectConfiguration: Decodable {
    static let fileName = ".swift-ember.json"

    let project: String?
    let workspace: String?
    let scheme: String?
    let configuration: String?
    let sources: [String]?
    let startupTimeout: TimeInterval?

    enum ConfigurationError: Error, CustomStringConvertible {
        case unreadable(URL, String)
        case bothContainers(URL)
        case missingScheme(URL)
        case invalidStartupTimeout(URL)
        case unknownKeys(URL, [String])

        var description: String {
            switch self {
            case .unreadable(let url, let reason):
                "cannot read \(url.path): \(reason)"
            case .bothContainers(let url):
                "\(url.path) must contain project or workspace, not both"
            case .missingScheme(let url):
                "\(url.path) needs a scheme with its project or workspace"
            case .invalidStartupTimeout(let url):
                "\(url.path) has an invalid startupTimeout; use a positive number"
            case .unknownKeys(let url, let keys):
                "\(url.path) has unknown keys: \(keys.joined(separator: ", "))"
            }
        }
    }

    static func load(from url: URL) throws -> ProjectConfiguration {
        let configuration: ProjectConfiguration
        do {
            let data = try Data(contentsOf: url)
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let allowed: Set<String> = [
                    "project", "workspace", "scheme", "configuration", "sources", "startupTimeout",
                ]
                let unknown = object.keys.filter { !allowed.contains($0) }.sorted()
                if !unknown.isEmpty { throw ConfigurationError.unknownKeys(url, unknown) }
            }
            configuration = try JSONDecoder().decode(ProjectConfiguration.self, from: data)
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.unreadable(url, error.localizedDescription)
        }

        if configuration.project != nil && configuration.workspace != nil {
            throw ConfigurationError.bothContainers(url)
        }
        if (configuration.project != nil || configuration.workspace != nil)
            && configuration.scheme?.isEmpty != false {
            throw ConfigurationError.missingScheme(url)
        }
        if let timeout = configuration.startupTimeout,
           !timeout.isFinite || timeout <= 0 {
            throw ConfigurationError.invalidStartupTimeout(url)
        }
        return configuration
    }

    static func discover(
        explicitPath: String?,
        environment: [String: String],
        currentDirectory: URL
    ) throws -> (ProjectConfiguration, URL)? {
        if let explicitPath {
            let url = absoluteURL(explicitPath, relativeTo: currentDirectory)
            return (try load(from: url), url)
        }

        var starts: [URL] = []
        if let sourceRoot = environment["SRCROOT"], !sourceRoot.isEmpty {
            starts.append(URL(fileURLWithPath: sourceRoot, isDirectory: true))
        }
        starts.append(currentDirectory)

        var visited: Set<String> = []
        for start in starts {
            var directoryPath = start.standardizedFileURL.path
            while visited.insert(directoryPath).inserted {
                let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
                let candidate = directory.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return (try load(from: candidate), candidate)
                }
                if directoryPath == "/" { break }
                let parent = (directoryPath as NSString).deletingLastPathComponent
                if parent.isEmpty || parent == directoryPath { break }
                directoryPath = parent
            }
        }
        return nil
    }

    func applying(to options: inout Options, from url: URL, explicit: Options.ExplicitOptions) {
        let root = url.deletingLastPathComponent()
        if !explicit.context && !explicit.container {
            options.project = project.map { Self.absoluteURL($0, relativeTo: root).path }
            options.workspace = workspace.map { Self.absoluteURL($0, relativeTo: root).path }
        }
        if !explicit.context && !explicit.container && !explicit.scheme, let scheme {
            options.scheme = scheme
        }
        if !explicit.configuration, let configuration { options.configuration = configuration }
        if !explicit.context && !explicit.sources, let sources {
            options.sourceRoots = sources.map { Self.absoluteURL($0, relativeTo: root).path }
        }
        if !explicit.startupTimeout, let startupTimeout {
            options.startupTimeout = startupTimeout
        }
    }

    private static func absoluteURL(_ path: String, relativeTo root: URL) -> URL {
        URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
    }
}
