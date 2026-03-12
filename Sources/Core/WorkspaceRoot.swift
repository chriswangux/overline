import Foundation

/// Resolves the workspace root directory for enrichment features.
///
/// Set the `OVERLINE_WORKSPACE` environment variable to point to your workspace root.
/// If unset, defaults to the user's home directory.
///
/// The workspace root is used by:
/// - SessionEnricher: reads `.active-sessions.json` from this path
/// - PortResolver: reads `ports.json` for dev server port mappings
/// - ProjectNamer: derives short project names from directory paths
///
/// These features gracefully degrade if the files don't exist —
/// Overline works fine without a configured workspace root.
enum WorkspaceRoot {
    static let path: String = {
        if let root = ProcessInfo.processInfo.environment["OVERLINE_WORKSPACE"] { return root }
        return NSHomeDirectory()
    }()
}
