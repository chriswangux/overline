import AppKit
import ApplicationServices

/// Private API to get CGWindowID from an AXUIElement.
/// Stable since macOS 10.5, safe for personal tools.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Watches a target app via AXObserver for window events.
/// Event-driven: ~1-5ms latency vs AppleScript round-trips.
final class AppWatcher {
    private let targetPID: pid_t
    private var observer: AXObserver?
    private let app: AXUIElement

    /// Called when a window moves/resizes — (windowID, newFrame)
    var onWindowMoved: ((CGWindowID, CGRect) -> Void)?
    /// Called when a window is minimized
    var onWindowMinimized: ((CGWindowID) -> Void)?
    /// Called when a window is restored from dock
    var onWindowDeminiaturized: ((CGWindowID) -> Void)?
    /// Called when focused window changes
    var onFocusChanged: (() -> Void)?
    /// Called when a window title changes
    var onTitleChanged: ((CGWindowID) -> Void)?
    /// Called when a window is created
    var onWindowCreated: ((CGWindowID) -> Void)?
    /// Called when a window is destroyed
    var onWindowDestroyed: (() -> Void)?

    init(targetPID: pid_t) {
        self.targetPID = targetPID
        self.app = AXUIElementCreateApplication(targetPID)
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        var obs: AXObserver?
        let err = AXObserverCreate(targetPID, axCallback, &obs)
        guard err == .success, let obs else {
            print("[Overline] Failed to create AXObserver: \(err.rawValue)")
            return
        }
        self.observer = obs

        let notifications: [String] = [
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXFocusedWindowChangedNotification,
            kAXTitleChangedNotification,
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
        ]

        for notif in notifications {
            AXObserverAddNotification(obs, app, notif as CFString, Unmanaged.passUnretained(self).toOpaque())
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )
    }

    func stop() {
        if let obs = observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(obs),
                .defaultMode
            )
        }
        observer = nil
    }

    // MARK: - Window Queries

    /// Get all windows with their CGWindowIDs and frames.
    func enumerateWindows() -> [(windowId: CGWindowID, frame: CGRect, title: String?, isMinimized: Bool)] {
        var result: [(CGWindowID, CGRect, String?, Bool)] = []

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return result
        }

        for win in windows {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(win, &wid) == .success, wid != 0 else { continue }

            let frame = frameOf(win)
            let title = titleOf(win)
            let minimized = isMinimized(win)

            result.append((wid, frame, title, minimized))
        }

        return result
    }

    /// Get the frame of a specific window by CGWindowID.
    func frameForWindow(_ windowId: CGWindowID) -> CGRect? {
        guard let element = elementForWindow(windowId) else { return nil }
        let frame = frameOf(element)
        return frame.isEmpty ? nil : frame
    }

    /// Get the title of a specific window.
    func titleForWindow(_ windowId: CGWindowID) -> String? {
        guard let element = elementForWindow(windowId) else { return nil }
        return titleOf(element)
    }

    /// Check if a window is minimized.
    func isWindowMinimized(_ windowId: CGWindowID) -> Bool {
        guard let element = elementForWindow(windowId) else { return false }
        return isMinimized(element)
    }

    // MARK: - AXUIElement Helpers

    private func elementForWindow(_ windowId: CGWindowID) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for win in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(win, &wid) == .success, wid == windowId {
                return win
            }
        }
        return nil
    }

    private func frameOf(_ element: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var pos = CGPoint.zero
        var size = CGSize.zero

        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
           let posRef {
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        }
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let sizeRef {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        }

        return CGRect(origin: pos, size: size)
    }

    private func titleOf(_ element: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success else {
            return nil
        }
        return titleRef as? String
    }

    private func isMinimized(_ element: AXUIElement) -> Bool {
        var miniRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &miniRef) == .success else {
            return false
        }
        return (miniRef as? Bool) ?? false
    }

    // MARK: - Callback Dispatch

    fileprivate func handleNotification(_ notification: String, element: AXUIElement) {
        var wid: CGWindowID = 0
        _ = _AXUIElementGetWindow(element, &wid)

        switch notification {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            guard wid != 0 else { return }
            let frame = frameOf(element)
            onWindowMoved?(wid, frame)

        case kAXWindowMiniaturizedNotification:
            guard wid != 0 else { return }
            onWindowMinimized?(wid)

        case kAXWindowDeminiaturizedNotification:
            guard wid != 0 else { return }
            onWindowDeminiaturized?(wid)

        case kAXFocusedWindowChangedNotification:
            onFocusChanged?()

        case kAXTitleChangedNotification:
            guard wid != 0 else { return }
            onTitleChanged?(wid)

        case kAXWindowCreatedNotification:
            guard wid != 0 else { return }
            onWindowCreated?(wid)

        case kAXUIElementDestroyedNotification:
            onWindowDestroyed?()

        default:
            break
        }
    }
}

/// C-level AX callback — bridges to AppWatcher instance method.
private func axCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let watcher = Unmanaged<AppWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handleNotification(notification as String, element: element)
}
