import AppKit
import ApplicationServices

/// Detects browser windows showing localhost URLs and maps them to CGWindowIDs.
final class BrowserDetector {
    struct BrowserWindow {
        let cgWindowId: CGWindowID
        let port: Int
        let browserBundleId: String
        let title: String
        let frame: CGRect  // AX coordinates (origin = top-left of primary screen)
    }

    private let detector = SessionDetector()

    // Cache: results + timestamp
    private var cache: (windows: [BrowserWindow], timestamp: Date)?
    private let cacheTTL: TimeInterval = 5

    /// Find all browser windows with active localhost tabs matching the given ports.
    func detectBrowserWindows(forPorts ports: Set<Int>, browserBundleIds: [String]) -> [BrowserWindow] {
        if let cached = cache, Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            return cached.windows.filter { ports.contains($0.port) }
        }

        var allWindows: [BrowserWindow] = []

        for bundleId in browserBundleIds {
            guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleId }) else {
                continue
            }

            let tabInfo = queryBrowserTabs(bundleId: bundleId)
            let cgWindows = cgWindowsForApp(bundleId: bundleId)

            for tab in tabInfo {
                // Match AppleScript window to CGWindowID via title
                if let cgWin = cgWindows.first(where: { titlesMatch($0.title, tab.windowTitle) }) {
                    allWindows.append(BrowserWindow(
                        cgWindowId: cgWin.id,
                        port: tab.port,
                        browserBundleId: bundleId,
                        title: tab.windowTitle,
                        frame: cgWin.frame
                    ))
                }
            }
        }

        cache = (windows: allWindows, timestamp: Date())
        return allWindows.filter { ports.contains($0.port) }
    }

    /// Invalidate cache (e.g., when ports change).
    func invalidateCache() {
        cache = nil
    }

    // MARK: - AppleScript Tab Enumeration

    private struct TabInfo {
        let windowTitle: String
        let port: Int
    }

    private func queryBrowserTabs(bundleId: String) -> [TabInfo] {
        let script: String
        switch bundleId {
        case BrowserApp.chrome.rawValue, BrowserApp.arc.rawValue:
            script = chromeAppleScript(appName: appNameForBundleId(bundleId))
        case BrowserApp.safari.rawValue:
            script = safariAppleScript()
        default:
            return []
        }

        guard let output = detector.runCommand("/usr/bin/osascript", args: ["-e", script]) else {
            return []
        }

        var results: [TabInfo] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2,
                  let port = Int(parts[0]) else { continue }
            let title = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(TabInfo(windowTitle: title, port: port))
        }
        return results
    }

    private func chromeAppleScript(appName: String) -> String {
        """
        tell application "\(appName)"
            set output to ""
            repeat with w in windows
                set winTitle to title of w
                repeat with t in tabs of w
                    try
                        set tabURL to URL of t
                        set locIdx to offset of "localhost:" in tabURL
                        if locIdx > 0 then
                            set afterHost to text (locIdx + 10) thru -1 of tabURL
                            set portStr to ""
                            repeat with i from 1 to length of afterHost
                                set c to character i of afterHost
                                if c is in "0123456789" then
                                    set portStr to portStr & c
                                else
                                    exit repeat
                                end if
                            end repeat
                            if portStr is not "" then
                                set output to output & portStr & "\t" & winTitle & linefeed
                            end if
                        end if
                    end try
                end repeat
            end repeat
            return output
        end tell
        """
    }

    private func safariAppleScript() -> String {
        """
        tell application "Safari"
            set output to ""
            repeat with w in windows
                set winTitle to name of w
                repeat with t in tabs of w
                    try
                        set tabURL to URL of t
                        set locIdx to offset of "localhost:" in tabURL
                        if locIdx > 0 then
                            set afterHost to text (locIdx + 10) thru -1 of tabURL
                            set portStr to ""
                            repeat with i from 1 to length of afterHost
                                set c to character i of afterHost
                                if c is in "0123456789" then
                                    set portStr to portStr & c
                                else
                                    exit repeat
                                end if
                            end repeat
                            if portStr is not "" then
                                set output to output & portStr & "\t" & winTitle & linefeed
                            end if
                        end if
                    end try
                end repeat
            end repeat
            return output
        end tell
        """
    }

    private func appNameForBundleId(_ bundleId: String) -> String {
        switch bundleId {
        case BrowserApp.chrome.rawValue: return "Google Chrome"
        case BrowserApp.arc.rawValue:    return "Arc"
        case BrowserApp.safari.rawValue: return "Safari"
        default: return "Google Chrome"
        }
    }

    // MARK: - CGWindowList Matching

    private struct CGWindowEntry {
        let id: CGWindowID
        let title: String
        let frame: CGRect
    }

    private func cgWindowsForApp(bundleId: String) -> [CGWindowEntry] {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) else {
            return []
        }
        let pid = app.processIdentifier

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var results: [CGWindowEntry] = []
        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == Int(pid),
                  let wid = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            let title = info[kCGWindowName as String] as? String ?? ""
            let frame = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            if frame.width > 50 && frame.height > 50 {
                results.append(CGWindowEntry(id: CGWindowID(wid), title: title, frame: frame))
            }
        }
        return results
    }

    /// Fuzzy title matching: AppleScript titles and CGWindowList titles can differ slightly.
    private func titlesMatch(_ cgTitle: String, _ asTitle: String) -> Bool {
        if cgTitle == asTitle { return true }
        if cgTitle.isEmpty || asTitle.isEmpty { return false }
        // One might be a prefix of the other, or they share enough characters
        return cgTitle.hasPrefix(asTitle) || asTitle.hasPrefix(cgTitle)
            || cgTitle.contains(asTitle) || asTitle.contains(cgTitle)
    }
}
