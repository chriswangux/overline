import Foundation

/// Reads a ports.json file and provides mappings between project directories and port numbers.
///
/// Expected format:
/// ```json
/// {
///   "projects": {
///     "my-app": { "backend": 3000, "vite": 5173, "dir": "apps/my-app" }
///   }
/// }
/// ```
///
/// Set `OVERLINE_PORTS_JSON` environment variable to override the default path.
/// If no ports.json exists, port-based browser clustering is disabled (Overline still works).
final class PortResolver {
    struct PortEntry {
        let projectKey: String
        let backend: Int?
        let vite: Int?
        let dir: String
    }

    private var entries: [PortEntry] = []
    private var lastModified: Date?
    private let portsPath: String

    init(portsPath: String? = nil) {
        self.portsPath = portsPath
            ?? ProcessInfo.processInfo.environment["OVERLINE_PORTS_JSON"]
            ?? WorkspaceRoot.path + "/ports.json"
        reload()
    }

    /// Reload ports.json from disk (only if file has changed).
    func reload() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: portsPath),
              let modified = attrs[.modificationDate] as? Date else { return }

        if let last = lastModified, modified <= last { return }
        lastModified = modified

        guard let data = fm.contents(atPath: portsPath) else { return }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let projects = json["projects"] as? [String: [String: Any]] else { return }

            var parsed: [PortEntry] = []
            for (key, value) in projects {
                let backend = value["backend"] as? Int
                let vite = value["vite"] as? Int
                let dir = value["dir"] as? String ?? ""
                parsed.append(PortEntry(projectKey: key, backend: backend, vite: vite, dir: dir))
            }
            entries = parsed
        } catch {
            // Keep existing entries on parse failure
        }
    }

    /// Find all port numbers for a given working directory (absolute path).
    /// Matches by checking if the cwd ends with the port entry's dir.
    func portsForCwd(_ cwd: String) -> [Int] {
        let workspace = WorkspaceRoot.path
        let relPath: String
        if cwd.hasPrefix(workspace + "/") {
            relPath = String(cwd.dropFirst(workspace.count + 1))
        } else {
            relPath = cwd
        }

        var ports: [Int] = []
        for entry in entries {
            if relPath == entry.dir || relPath.hasPrefix(entry.dir + "/") || cwd.hasSuffix("/" + entry.dir) {
                if let b = entry.backend { ports.append(b) }
                if let v = entry.vite { ports.append(v) }
            }
        }
        return ports
    }

    /// Reverse lookup: find project directory for a given port number.
    func projectDirForPort(_ port: Int) -> String? {
        for entry in entries {
            if entry.backend == port || entry.vite == port {
                return entry.dir
            }
        }
        return nil
    }

    /// Reverse lookup: find project key for a given port number.
    func projectKeyForPort(_ port: Int) -> String? {
        for entry in entries {
            if entry.backend == port || entry.vite == port {
                return entry.projectKey
            }
        }
        return nil
    }

    /// All known ports across all projects.
    var allPorts: [Int] {
        var result: [Int] = []
        for entry in entries {
            if let b = entry.backend { result.append(b) }
            if let v = entry.vite { result.append(v) }
        }
        return result
    }
}
