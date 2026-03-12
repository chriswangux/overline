import AppKit

/// Detects windows from known desktop apps (Electron/.app bundles).
///
/// Configure custom app mappings by setting the `OVERLINE_DESKTOP_APPS` environment variable
/// as a comma-separated list of `bundleId:projectDir` pairs. Example:
///   OVERLINE_DESKTOP_APPS="com.myteam.dashboard:tools/dashboard,com.myteam.editor:tools/editor"
///
/// If not set, desktop app detection is disabled (Overline still works for terminals and browsers).
final class DesktopAppDetector {
    struct DesktopAppWindow {
        let cgWindowId: CGWindowID
        let bundleId: String
        let appName: String
        let title: String
        let frame: CGRect  // CG/AX coordinates
    }

    /// Known desktop app bundle IDs -> project directory mappings.
    static let knownApps: [String: String] = {
        guard let env = ProcessInfo.processInfo.environment["OVERLINE_DESKTOP_APPS"],
              !env.isEmpty else { return [:] }
        var apps: [String: String] = [:]
        for pair in env.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                apps[String(parts[0])] = String(parts[1])
            }
        }
        return apps
    }()

    /// Find all visible windows from known desktop apps.
    func detectDesktopAppWindows() -> [DesktopAppWindow] {
        guard !Self.knownApps.isEmpty else { return [] }

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        // Build a PID -> bundleId lookup for known apps
        var pidToBundleId: [Int: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier, Self.knownApps[bid] != nil {
                pidToBundleId[Int(app.processIdentifier)] = bid
            }
        }

        guard !pidToBundleId.isEmpty else { return [] }

        var results: [DesktopAppWindow] = []
        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  let bundleId = pidToBundleId[ownerPID],
                  let wid = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            let title = info[kCGWindowName as String] as? String ?? ""
            let appName = info[kCGWindowOwnerName as String] as? String ?? bundleId
            let frame = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            if frame.width > 50 && frame.height > 50 {
                results.append(DesktopAppWindow(
                    cgWindowId: CGWindowID(wid),
                    bundleId: bundleId,
                    appName: appName,
                    title: title,
                    frame: frame
                ))
            }
        }

        return results
    }

    /// Get the project directory for a known desktop app bundle ID.
    static func projectDirForBundleId(_ bundleId: String) -> String? {
        knownApps[bundleId]
    }
}
