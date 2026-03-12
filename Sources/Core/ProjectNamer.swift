import Foundation

/// Derives a human-readable project name from an absolute working directory path.
enum ProjectNamer {
    static let workspace = WorkspaceRoot.path

    /// Derive a project name from an absolute path.
    /// - Workspace root -> last component of workspace path
    /// - Workspace child -> first 2-3 path segments relative to workspace
    /// - Outside workspace -> last 2 path components
    static func projectFromCwd(_ cwd: String) -> String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd

        if trimmed == workspace {
            return (workspace as NSString).lastPathComponent
        }

        let prefix = workspace + "/"
        if trimmed.hasPrefix(prefix) {
            let rel = String(trimmed.dropFirst(prefix.count))
            if rel.isEmpty { return (workspace as NSString).lastPathComponent }

            let parts = rel.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
            return parts.prefix(3).joined(separator: "/")
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        if components.count >= 2 {
            return components.suffix(2).joined(separator: "/")
        }
        return components.last.map(String.init) ?? trimmed
    }
}
