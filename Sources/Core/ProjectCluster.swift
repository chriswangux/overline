import AppKit

/// The role of a window within a project cluster.
enum WindowRole {
    case terminal       // Terminal running Claude Code
    case browser        // Browser showing localhost dev server
    case desktopApp     // Native/Electron app
}

/// A single window that belongs to a project cluster.
struct ClusteredWindow {
    let cgWindowId: CGWindowID
    let role: WindowRole
    let frame: CGRect           // AX/CG coordinates
    let title: String?
    let bundleId: String        // Owner app's bundle ID

    // Terminal-specific
    var project: String?
    var workingOn: String?
    var hasNotification: Bool = false
    var isWorking: Bool = true

    // Browser-specific
    var port: Int?
}

/// A cluster of windows all belonging to the same project.
struct ProjectCluster {
    let projectName: String
    let cwd: String?            // Working directory (from terminal anchor)
    var color: ClusterColorPalette.ClusterColor
    var windows: [ClusteredWindow]

    /// The terminal window that anchors this cluster (always present).
    var terminalWindows: [ClusteredWindow] {
        windows.filter { $0.role == .terminal }
    }

    /// Browser windows showing this project's dev server.
    var browserWindows: [ClusteredWindow] {
        windows.filter { $0.role == .browser }
    }

    /// Desktop app windows belonging to this project.
    var desktopAppWindows: [ClusteredWindow] {
        windows.filter { $0.role == .desktopApp }
    }
}
