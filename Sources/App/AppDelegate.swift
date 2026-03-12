import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var watcher: AppWatcher?
    private var detector = SessionDetector()
    private var enricher = SessionEnricher()
    private var overlays: [CGWindowID: OverlayWindow] = [:]
    private var scanTimer: Timer?
    private var occlusionTimer: Timer?
    private var statusItem: NSStatusItem?

    // Track which windows have which sessions
    private var windowSessions: [CGWindowID: (project: String, workingOn: String?)] = [:]

    // Custom label names — session-only, reset on quit
    private var customNames: [CGWindowID: String] = [:]

    // Overlay click monitor (global, since overlays ignore mouse events)
    private var overlayClickMonitor: Any?
    private var pendingSingleClick: DispatchWorkItem?

    // Drag tracking
    private var dragDownMonitor: Any?
    private var dragMoveMonitor: Any?
    private var dragUpMonitor: Any?
    private var dragState: (windowId: CGWindowID, offsetX: CGFloat, offsetY: CGFloat, winW: CGFloat, winH: CGFloat)?

    // Z-index: track whether target app is the frontmost app
    private var targetIsActive = false

    // Notification badges
    private var focusedWindowId: CGWindowID = 0
    private var windowTitleIcons: [CGWindowID: String] = [:]
    private var windowNotified: Set<CGWindowID> = []

    /// Current target bundle ID (from Settings).
    private var targetBundleId: String { Settings.shared.targetBundleId }

    // MARK: - Multi-App Clustering

    private var clusterEngine = ClusterEngine()
    private var borderOverlays: [CGWindowID: BorderOverlayWindow] = [:]
    private var clusterScanTimer: Timer?
    private var borderTrackingTimer: Timer?
    private var currentColorAssignments: [String: ClusterColorPalette.ClusterColor] = [:]

    // MARK: - Bento Mode
    private var bentoManager = BentoManager()
    private var bentoModeItem: NSMenuItem!

    /// Maps each window ID (terminal, browser, desktop) to its cluster's project name.
    private var windowToCluster: [CGWindowID: String] = [:]
    /// Maps cluster project name to all its window IDs.
    private var clusterWindows: [String: Set<CGWindowID>] = [:]
    /// Maps cluster project name to its associated localhost ports.
    private var clusterPorts: [String: Set<Int>] = [:]

    /// Whether we're in multi-app mode.
    private var isMultiAppMode: Bool { Settings.shared.mode == .multiApp }

    private func log(_ msg: String) {
        let line = "[Overline] \(msg)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private var hasAccessibility = false
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("Starting (target: \(Settings.shared.targetAppName), mode: \(Settings.shared.mode.rawValue))")

        setupMenuBar()

        hasAccessibility = AXIsProcessTrusted()
        if !hasAccessibility {
            AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            )
            log("Accessibility permission required. Waiting...")
            updatePermissionUI()

            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self?.permissionTimer = nil
                    self?.hasAccessibility = true
                    self?.updatePermissionUI()
                    self?.startWatching()
                    self?.setupDragMonitors()
                    self?.setupOverlayClickMonitor()
                }
            }
        } else {
            updatePermissionUI()
            startWatching()
            setupDragMonitors()
            setupOverlayClickMonitor()
        }

        // Watch for app launch/quit
        let ws = NSWorkspace.shared
        ws.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil
        )
        ws.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil
        )

        // Z-index: watch app activation changes
        ws.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        // Global hotkey: Cmd+Shift+B for Bento arrangement
        setupBentoHotkey()
    }

    private var bentoHotkeyMonitor: Any?

    private func setupBentoHotkey() {
        bentoHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Cmd+Shift+B triggers one-shot Arrange Bento
            if event.modifierFlags.contains([.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "b" {
                self?.arrangeBentoAction()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        bentoManager.deactivate()
        destroyAllOverlays()
        destroyAllBorderOverlays()
        watcher?.stop()
        scanTimer?.invalidate()
        occlusionTimer?.invalidate()
        clusterScanTimer?.invalidate()
        borderTrackingTimer?.invalidate()
        teardownDragMonitors()
        if let m = overlayClickMonitor { NSEvent.removeMonitor(m) }
        if let m = bentoHotkeyMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Menu Bar

    private var accentBarItem: NSMenuItem!
    private var borderLoopItem: NSMenuItem!
    private var targetMenuItems: [NSMenuItem] = []
    private var customTargetItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var permissionSeparator: NSMenuItem!

    // Mode menu items
    private var singleAppModeItem: NSMenuItem!
    private var multiAppModeItem: NSMenuItem!

    // Target App and Browsers menu items (top-level, for show/hide)
    private var targetMenuItem: NSMenuItem!
    private var browsersMenuItem: NSMenuItem!
    private var browserMenuItems: [NSMenuItem] = []

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "line.horizontal.star.fill.line.horizontal", accessibilityDescription: "Overline")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Overline", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        // Permission status
        permissionItem = NSMenuItem(title: "Grant Accessibility Access\u{2026}", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permissionItem.target = self
        permissionItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        menu.addItem(permissionItem)
        permissionSeparator = NSMenuItem.separator()
        menu.addItem(permissionSeparator)

        // Mode submenu
        let modeMenu = NSMenu()
        singleAppModeItem = NSMenuItem(title: "Single App", action: #selector(selectSingleAppMode), keyEquivalent: "")
        singleAppModeItem.target = self
        multiAppModeItem = NSMenuItem(title: "Multi-App Clustering", action: #selector(selectMultiAppMode), keyEquivalent: "")
        multiAppModeItem.target = self
        modeMenu.addItem(singleAppModeItem)
        modeMenu.addItem(multiAppModeItem)
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // Style submenu
        let styleMenu = NSMenu()
        accentBarItem = NSMenuItem(title: "Accent Bar", action: #selector(selectAccentBar), keyEquivalent: "")
        accentBarItem.target = self
        borderLoopItem = NSMenuItem(title: "Border Loop", action: #selector(selectBorderLoop), keyEquivalent: "")
        borderLoopItem.target = self
        styleMenu.addItem(accentBarItem)
        styleMenu.addItem(borderLoopItem)
        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        // Target App submenu (visible in single-app mode)
        let targetMenu = NSMenu()
        for app in TargetApp.allCases {
            let item = NSMenuItem(title: app.displayName, action: #selector(selectTargetApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.rawValue
            targetMenu.addItem(item)
            targetMenuItems.append(item)
        }
        targetMenu.addItem(.separator())
        customTargetItem = NSMenuItem(title: "Custom\u{2026}", action: #selector(selectCustomTarget), keyEquivalent: "")
        customTargetItem.target = self
        targetMenu.addItem(customTargetItem)
        targetMenuItem = NSMenuItem(title: "Target App", action: nil, keyEquivalent: "")
        targetMenuItem.submenu = targetMenu
        menu.addItem(targetMenuItem)

        // Browsers submenu (visible in multi-app mode)
        let browsersMenu = NSMenu()
        for browser in BrowserApp.allCases {
            let item = NSMenuItem(title: browser.displayName, action: #selector(toggleBrowser(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = browser.rawValue
            browsersMenu.addItem(item)
            browserMenuItems.append(item)
        }
        browsersMenuItem = NSMenuItem(title: "Browsers", action: nil, keyEquivalent: "")
        browsersMenuItem.submenu = browsersMenu
        menu.addItem(browsersMenuItem)

        updateStyleCheckmarks()
        updateTargetCheckmarks()
        updateModeCheckmarks()
        updateModeVisibility()
        updateBrowserCheckmarks()

        menu.addItem(.separator())
        let arrangeItem = NSMenuItem(title: "Arrange Bento", action: #selector(arrangeBentoAction), keyEquivalent: "b")
        arrangeItem.keyEquivalentModifierMask = [.command, .shift]
        arrangeItem.target = self
        menu.addItem(arrangeItem)
        bentoModeItem = NSMenuItem(title: "Bento Mode", action: #selector(toggleBentoMode), keyEquivalent: "")
        bentoModeItem.target = self
        bentoModeItem.state = .off
        menu.addItem(bentoModeItem)

        // Bento Grid Settings submenu
        let bentoSettingsMenu = NSMenu()
        let s = Settings.shared
        for (label, getter, setter): (String, () -> CGFloat, (CGFloat) -> Void) in [
            ("Min Width",  { s.bentoMinCellWidth },  { s.bentoMinCellWidth = $0 }),
            ("Max Width",  { s.bentoMaxCellWidth },  { s.bentoMaxCellWidth = $0 }),
            ("Min Height", { s.bentoMinCellHeight }, { s.bentoMinCellHeight = $0 }),
            ("Max Height", { s.bentoMaxCellHeight }, { s.bentoMaxCellHeight = $0 }),
        ] {
            let item = NSMenuItem(title: "\(label): \(Int(getter()))px", action: #selector(editBentoSetting(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = BentoSettingEdit(label: label, getter: getter, setter: setter, menuItem: item)
            bentoSettingsMenu.addItem(item)
        }
        let bentoSettingsItem = NSMenuItem(title: "Grid Size Limits", action: nil, keyEquivalent: "")
        bentoSettingsItem.submenu = bentoSettingsMenu
        menu.addItem(bentoSettingsItem)

        menu.addItem(withTitle: "Rescan Now", action: #selector(rescanAction), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quitAction), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    private func updateStyleCheckmarks() {
        let current = Settings.shared.style
        accentBarItem.state = current == .accentBar ? .on : .off
        borderLoopItem.state = current == .borderLoop ? .on : .off
    }

    private func updateTargetCheckmarks() {
        let currentId = Settings.shared.targetBundleId
        for item in targetMenuItems {
            item.state = (item.representedObject as? String) == currentId ? .on : .off
        }
        let isKnown = TargetApp.allCases.contains { $0.rawValue == currentId }
        customTargetItem.state = isKnown ? .off : .on
        if !isKnown {
            customTargetItem.title = "Custom: \(Settings.shared.targetAppName)"
        } else {
            customTargetItem.title = "Custom\u{2026}"
        }
    }

    private func updateModeCheckmarks() {
        let current = Settings.shared.mode
        singleAppModeItem.state = current == .singleApp ? .on : .off
        multiAppModeItem.state = current == .multiApp ? .on : .off
    }

    private func updateModeVisibility() {
        let multi = isMultiAppMode
        targetMenuItem.isHidden = multi
        browsersMenuItem.isHidden = !multi
    }

    private func updateBrowserCheckmarks() {
        for item in browserMenuItems {
            guard let bundleId = item.representedObject as? String,
                  let browser = BrowserApp(rawValue: bundleId) else { continue }
            item.state = Settings.shared.isBrowserEnabled(browser) ? .on : .off
        }
    }

    // MARK: - Permission UX

    private func updatePermissionUI() {
        let granted = hasAccessibility
        permissionItem.isHidden = granted
        permissionSeparator.isHidden = granted

        if let button = statusItem?.button {
            if granted {
                button.image = NSImage(systemSymbolName: "line.horizontal.star.fill.line.horizontal", accessibilityDescription: "Overline")
            } else {
                button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Overline — Accessibility Required")
            }
            button.image?.size = NSSize(width: 18, height: 18)
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func selectAccentBar() { applyStyle(.accentBar) }
    @objc private func selectBorderLoop() { applyStyle(.borderLoop) }

    private func applyStyle(_ style: AnimationStyle) {
        Settings.shared.style = style
        updateStyleCheckmarks()
        for (_, overlay) in overlays {
            overlay.setAnimationStyle(style)
        }
    }

    @objc private func selectSingleAppMode() { applyMode(.singleApp) }
    @objc private func selectMultiAppMode() { applyMode(.multiApp) }

    private func applyMode(_ mode: OverlineMode) {
        let old = Settings.shared.mode
        guard mode != old else { return }

        log("Switching mode: \(old.rawValue) -> \(mode.rawValue)")
        Settings.shared.mode = mode
        updateModeCheckmarks()
        updateModeVisibility()

        if mode == .singleApp {
            // Tear down multi-app state
            clusterScanTimer?.invalidate()
            clusterScanTimer = nil
            borderTrackingTimer?.invalidate()
            borderTrackingTimer = nil
            destroyAllBorderOverlays()
            currentColorAssignments.removeAll()
            windowToCluster.removeAll()
            clusterWindows.removeAll()
            // Reset terminal label colors to gold
            for (_, overlay) in overlays {
                overlay.setClusterColor(nil)
            }
        } else {
            // Start multi-app scanning
            startClusterScanning()
        }

        fullScan()
    }

    @objc private func toggleBrowser(_ sender: NSMenuItem) {
        guard let bundleId = sender.representedObject as? String,
              let browser = BrowserApp(rawValue: bundleId) else { return }
        let current = Settings.shared.isBrowserEnabled(browser)
        Settings.shared.setBrowserEnabled(browser, enabled: !current)
        updateBrowserCheckmarks()
        clusterEngine.invalidateBrowserCache()
        fullScan()
    }

    @objc private func selectTargetApp(_ sender: NSMenuItem) {
        guard let bundleId = sender.representedObject as? String else { return }
        switchTarget(to: bundleId)
    }

    @objc private func selectCustomTarget() {
        let alert = NSAlert()
        alert.messageText = "Custom Target App"
        alert.informativeText = "Enter the bundle identifier of the app to watch (e.g., com.example.myapp):"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = Settings.shared.targetBundleId
        input.placeholderString = "com.example.myapp"
        alert.accessoryView = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let bundleId = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bundleId.isEmpty {
                switchTarget(to: bundleId)
            }
        }
    }

    private func switchTarget(to bundleId: String) {
        let old = Settings.shared.targetBundleId
        guard bundleId != old else { return }

        log("Switching target: \(old) -> \(bundleId)")
        Settings.shared.targetBundleId = bundleId

        // Tear down current watcher and overlays
        watcher?.stop()
        watcher = nil
        scanTimer?.invalidate()
        scanTimer = nil
        occlusionTimer?.invalidate()
        occlusionTimer = nil
        destroyAllOverlays()
        destroyAllBorderOverlays()
        ttyCache = nil
        targetIsActive = false
        focusedWindowId = 0
        windowTitleIcons.removeAll()
        windowNotified.removeAll()

        updateTargetCheckmarks()
        startWatching()
    }

    @objc private func rescanAction() { fullScan() }

    // MARK: - Arrange Bento (one-shot)

    @objc private func arrangeBentoAction() {
        guard let tw = watcher, let targetApp = findTargetApp() else {
            log("Bento: no watcher or target app")
            return
        }

        let labeled = collectLabeledWindows(watcher: tw)
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        guard !labeled.isEmpty else {
            log("Bento: no visible windows")
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let vf = screen.visibleFrame
        let sh = screen.frame.height
        let sW = vf.width, sH = vf.height
        let sX = vf.origin.x, sY = sh - vf.origin.y - sH

        let s = Settings.shared
        let maxW = s.bentoMaxCellWidth, maxH = s.bentoMaxCellHeight

        let count = labeled.count
        let (cols, rows) = BentoManager.responsiveGridDimensions(for: count, screenWidth: sW, screenHeight: sH)

        let gap: CGFloat = 8
        let labelGap: CGFloat = 64
        let totalGapH = gap * CGFloat(cols + 1)
        let totalGapV = gap * CGFloat(rows + 1) + labelGap * CGFloat(rows)
        let cellW = round(min((sW - totalGapH) / CGFloat(cols), maxW))
        let cellH = round(min((sH - totalGapV) / CGFloat(rows), maxH))

        // Center grid if cells hit max
        let gridW = cellW * CGFloat(cols) + totalGapH
        let gridH = cellH * CGFloat(rows) + totalGapV
        let offsetX = (sW - gridW) / 2
        let offsetY = (sH - gridH) / 2

        log("Arrange Bento: \(count) windows in \(cols)x\(rows), cell \(Int(cellW))x\(Int(cellH))")

        let axApp = AXUIElementCreateApplication(targetApp.processIdentifier)
        for (i, item) in labeled.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = round(sX + offsetX + gap + CGFloat(col) * (cellW + gap))
            let y = round(sY + offsetY + gap + labelGap + CGFloat(row) * (cellH + gap + labelGap))

            guard let axWin = axWindowForId(axApp: axApp, windowId: item.windowId) else { continue }
            var size = CGSize(width: cellW, height: cellH)
            if let sv = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sv)
            }
            var point = CGPoint(x: x, y: y)
            if let pv = AXValueCreate(.cgPoint, &point) {
                AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, pv)
            }
            AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
        }

        targetApp.activate()
        targetIsActive = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshOverlayPositions()
            self?.updateBorderPositions()
            self?.updateOcclusion()
            self?.showAllOverlays()
        }
    }

    // MARK: - Bento Mode (persistent)

    @objc private func toggleBentoMode() {
        if bentoManager.isActive {
            deactivateBentoMode()
        } else {
            activateBentoMode()
        }
    }

    private func activateBentoMode() {
        guard let tw = watcher else {
            log("Bento: no watcher")
            return
        }

        let windows = collectLabeledWindows(watcher: tw)
        guard !windows.isEmpty else {
            log("Bento: no visible windows")
            return
        }

        // Wire up callbacks
        bentoManager.axWindowProvider = { [weak self] windowId in
            guard let self, let targetApp = self.findTargetApp() else { return nil }
            let axApp = AXUIElementCreateApplication(targetApp.processIdentifier)
            return self.axWindowForId(axApp: axApp, windowId: windowId)
        }
        bentoManager.onRepositioned = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.refreshOverlayPositions()
                self.updateOcclusion()
                self.showAllOverlays()
            }
        }
        bentoManager.activateTargetApp = { [weak self] in
            guard let self else { return }
            self.targetIsActive = true
            self.findTargetApp()?.activate()
        }

        bentoManager.activate(windows: windows)
        bentoModeItem.state = .on
        log("Bento Mode ON: \(windows.count) windows")
    }

    private func deactivateBentoMode() {
        bentoManager.deactivate()
        bentoModeItem.state = .off
        log("Bento Mode OFF")
    }

    /// Collect all visible terminal windows with their display labels.
    private func collectLabeledWindows(watcher tw: AppWatcher) -> [(windowId: CGWindowID, label: String)] {
        var result: [(windowId: CGWindowID, label: String)] = []
        for win in tw.enumerateWindows() where !win.isMinimized {
            let name: String
            if let custom = customNames[win.windowId] {
                name = custom
            } else if let session = windowSessions[win.windowId] {
                name = session.project
            } else if let title = win.title, !title.isEmpty {
                name = title
            } else {
                name = "Untitled"
            }
            result.append((windowId: win.windowId, label: name))
        }
        return result
    }
    @objc private func quitAction() { NSApp.terminate(nil) }

    // MARK: - Bento Settings

    @objc private func editBentoSetting(_ sender: NSMenuItem) {
        guard let edit = sender.representedObject as? BentoSettingEdit else { return }

        let alert = NSAlert()
        alert.messageText = "Set \(edit.label)"
        alert.informativeText = "Enter value in pixels (min 200):"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        input.integerValue = Int(edit.getter())
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let newVal = max(200, CGFloat(input.integerValue))
        edit.setter(newVal)
        edit.menuItem.title = "\(edit.label): \(Int(newVal))px"
        log("Bento setting: \(edit.label) = \(Int(newVal))px")

        if bentoManager.isActive, let tw = watcher {
            bentoManager.activate(windows: collectLabeledWindows(watcher: tw))
        }
    }

    // MARK: - Z-Index: App Activation

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let isSelf = app.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if isSelf { return }

        if isMultiAppMode {
            // In multi-app mode, show overlays when any relevant app is active
            let isRelevant = app.bundleIdentifier == targetBundleId
                || Settings.shared.enabledBrowserBundleIds.contains(app.bundleIdentifier ?? "")
                || DesktopAppDetector.knownApps.keys.contains(app.bundleIdentifier ?? "")

            if isRelevant && !targetIsActive {
                targetIsActive = true
                showAllOverlays()
                showAllBorderOverlays()
            } else if !isRelevant && targetIsActive {
                targetIsActive = false
                hideAllOverlays()
                hideAllBorderOverlays()
            }
        } else {
            let isTarget = app.bundleIdentifier == targetBundleId
            if isTarget && !targetIsActive {
                targetIsActive = true
                showAllOverlays()
            } else if !isTarget && targetIsActive {
                targetIsActive = false
                hideAllOverlays()
            }
        }
    }

    private func showAllOverlays() {
        for (_, overlay) in overlays {
            overlay.showLabel()
        }
        updateOcclusion()
    }

    private func hideAllOverlays() {
        for (_, overlay) in overlays {
            overlay.hideLabel()
        }
    }

    private func showAllBorderOverlays() {
        for (_, overlay) in borderOverlays {
            overlay.showBorder()
        }
    }

    private func hideAllBorderOverlays() {
        for (_, overlay) in borderOverlays {
            overlay.hideBorder()
        }
    }

    private func updateOcclusion() {
        guard targetIsActive, !overlays.isEmpty else { return }

        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 900

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        struct WinEntry {
            let id: CGWindowID
            let bounds: CGRect
            let isSelf: Bool
        }
        var zOrderedWindows: [WinEntry] = []
        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  let wid = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 || layer == 3,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            if bounds.width > 50 && bounds.height > 50 {
                zOrderedWindows.append(WinEntry(
                    id: CGWindowID(wid),
                    bounds: bounds,
                    isSelf: ownerPID == myPID
                ))
            }
        }

        for (windowId, overlay) in overlays {
            let nsFrame = overlay.frame
            let labelMidY = screenHeight - nsFrame.midY

            let testPoints: [(CGFloat, CGFloat)] = [
                (nsFrame.minX + 20, labelMidY),
                (nsFrame.midX, labelMidY),
                (nsFrame.maxX - 20, labelMidY),
            ]

            var frontBounds: [CGRect] = []
            var foundTargetWindow = false
            for w in zOrderedWindows {
                if w.id == windowId {
                    foundTargetWindow = true
                    break
                }
                if !w.isSelf {
                    frontBounds.append(w.bounds)
                }
            }

            guard foundTargetWindow else { continue }

            var occluded = false
            for (px, py) in testPoints {
                for b in frontBounds {
                    if px >= b.minX && px <= b.maxX && py >= b.minY && py <= b.maxY {
                        occluded = true
                        break
                    }
                }
                if occluded { break }
            }

            if occluded {
                overlay.hideLabel()
            } else {
                overlay.showLabel()
            }
        }
    }

    // MARK: - Drag Tracking

    private func setupDragMonitors() {
        dragDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.handleMouseDown()
        }

        dragMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            guard let self else { return }
            if self.dragState != nil {
                self.handleMouseDrag()
            }
            self.updateOcclusion()
        }

        dragUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self else { return }

            if self.bentoManager.isDragging {
                // Pass the window's actual drop position so it animates
                // from where the user released it, not from the old grid cell.
                var dropPos: CGPoint?
                if let ds = self.dragState, let tw = self.watcher,
                   let frame = tw.frameForWindow(ds.windowId) {
                    dropPos = frame.origin
                }
                self.bentoManager.endDrag(dropPosition: dropPos)
            }

            if self.dragState != nil {
                self.dragState = nil
                if !self.bentoManager.isActive {
                    self.refreshOverlayPositions()
                }
            }
            self.updateOcclusion()
        }
    }

    private func teardownDragMonitors() {
        if let m = dragDownMonitor { NSEvent.removeMonitor(m) }
        if let m = dragMoveMonitor { NSEvent.removeMonitor(m) }
        if let m = dragUpMonitor { NSEvent.removeMonitor(m) }
        dragDownMonitor = nil
        dragMoveMonitor = nil
        dragUpMonitor = nil
    }

    // MARK: - Overlay Click Monitor

    /// Since overlays ignore mouse events (click pass-through), we detect
    /// clicks via a global monitor: single-click for bring-to-front,
    /// double-click for inline rename.
    private func setupOverlayClickMonitor() {
        overlayClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return }
            let screenPoint = NSEvent.mouseLocation

            // Find which overlay (if any) contains the click point
            var hitOverlay: OverlayWindow?
            for (_, overlay) in self.overlays {
                guard overlay.alphaValue > 0 else { continue }
                if overlay.frame.contains(screenPoint) {
                    hitOverlay = overlay
                    break
                }
            }
            guard let overlay = hitOverlay else {
                self.pendingSingleClick?.cancel()
                self.pendingSingleClick = nil
                return
            }

            if event.clickCount >= 2 {
                // Double-click: cancel pending single-click, enter rename
                self.pendingSingleClick?.cancel()
                self.pendingSingleClick = nil
                overlay.enterEditMode()
            } else {
                // Single-click: delay to distinguish from double-click
                self.pendingSingleClick?.cancel()
                let work = DispatchWorkItem { [weak overlay] in
                    overlay?.onSingleClick?()
                }
                self.pendingSingleClick = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
        }
    }

    private func nsToAX(_ point: NSPoint) -> (x: CGFloat, y: CGFloat) {
        let screenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 900
        return (point.x, screenHeight - point.y)
    }

    private func handleMouseDown() {
        guard targetIsActive, !overlays.isEmpty, let tw = watcher else { return }

        let mouse = NSEvent.mouseLocation
        let (mx, my) = nsToAX(mouse)

        let windows = tw.enumerateWindows()
        for win in windows where !win.isMinimized {
            guard overlays[win.windowId] != nil else { continue }
            let f = win.frame
            if mx >= f.origin.x && mx <= f.origin.x + f.width
                && my >= f.origin.y && my <= f.origin.y + 40 {
                dragState = (
                    windowId: win.windowId,
                    offsetX: mx - f.origin.x,
                    offsetY: my - f.origin.y,
                    winW: f.width,
                    winH: f.height
                )
                // Start bento drag if in bento mode
                if bentoManager.isActive {
                    bentoManager.beginDrag(windowId: win.windowId)
                }
                return
            }
        }
    }

    private func handleMouseDrag() {
        guard let ds = dragState, let overlay = overlays[ds.windowId] else { return }

        let mouse = NSEvent.mouseLocation
        let (mx, my) = nsToAX(mouse)

        let frame = CGRect(x: mx - ds.offsetX, y: my - ds.offsetY, width: ds.winW, height: ds.winH)
        overlay.positionRelativeTo(termFrame: frame)

        // Feed bento drag with window center for Launchpad-style shuffling
        if bentoManager.isDragging {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            bentoManager.updateDrag(windowCenter: center)
        }
    }

    private func refreshOverlayPositions() {
        guard let tw = watcher else { return }
        // In bento mode, let the bento manager handle window positions.
        // We only update overlay positions (labels above windows).
        for (windowId, overlay) in overlays {
            if let frame = tw.frameForWindow(windowId) {
                overlay.positionRelativeTo(termFrame: frame)
            }
        }
    }

    // MARK: - Notification Badges

    private func iconFromTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        let parts = title.components(separatedBy: " \u{2014} ")
        guard parts.count >= 2 else { return nil }
        let desc = parts[1]
        if let spaceIdx = desc.firstIndex(of: " ") {
            let prefix = String(desc[desc.startIndex..<spaceIdx])
            if prefix.unicodeScalars.contains(where: { !$0.isASCII }) {
                return prefix
            }
        }
        return nil
    }

    private func handleTitleChange(_ windowId: CGWindowID) {
        guard let tw = watcher else { return }
        let title = tw.titleForWindow(windowId)
        let newIcon = iconFromTitle(title)

        let oldIcon = windowTitleIcons[windowId]
        windowTitleIcons[windowId] = newIcon

        if newIcon == "\u{2733}" && oldIcon != "\u{2733}" && windowId != focusedWindowId {
            windowNotified.insert(windowId)
            overlays[windowId]?.setNotification(true)
            log("badge ON: window \(windowId)")
        }

        if newIcon != "\u{2733}" && windowNotified.contains(windowId) {
            windowNotified.remove(windowId)
            overlays[windowId]?.setNotification(false)
        }
    }

    private func updateFocusedWindow() {
        guard let targetApp = findTargetApp() else { return }

        var focusedRef: CFTypeRef?
        let app = AXUIElementCreateApplication(targetApp.processIdentifier)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedEl = focusedRef else { return }

        var wid: CGWindowID = 0
        _ = _AXUIElementGetWindow(focusedEl as! AXUIElement, &wid)

        if wid != 0 && wid != focusedWindowId {
            focusedWindowId = wid

            if windowNotified.contains(wid) {
                windowNotified.remove(wid)
                overlays[wid]?.setNotification(false)
                log("badge OFF: window \(wid) (focused)")
            }

            let title = watcher?.titleForWindow(wid)
            windowTitleIcons[wid] = iconFromTitle(title)
        }
    }

    // MARK: - Target App Watching

    private func startWatching() {
        guard let targetApp = findTargetApp() else {
            log("\(Settings.shared.targetAppName) not running \u{2014} waiting for launch")
            return
        }

        targetIsActive = targetApp.isActive

        log("Attaching to \(Settings.shared.targetAppName) (PID \(targetApp.processIdentifier))")
        let tw = AppWatcher(targetPID: targetApp.processIdentifier)

        tw.onWindowMoved = { [weak self] windowId, frame in
            guard let self else { return }
            guard self.dragState == nil else { return }

            if self.bentoManager.isActive {
                // Magnetic borders: detect user resize and flex neighbors
                self.bentoManager.handleWindowResize(windowId: windowId, newFrame: frame)
                self.overlays[windowId]?.positionRelativeTo(termFrame: frame)
            } else {
                self.overlays[windowId]?.positionRelativeTo(termFrame: frame)
            }
        }
        tw.onWindowMinimized = { [weak self] windowId in
            self?.overlays[windowId]?.hideLabel()
        }
        tw.onWindowDeminiaturized = { [weak self] windowId in
            self?.debouncedScan()
        }
        tw.onFocusChanged = { [weak self] in
            guard let self else { return }
            self.updateFocusedWindow()
            self.refreshOverlayPositions()
            self.updateOcclusion()
            self.debouncedScan()
        }
        tw.onTitleChanged = { [weak self] windowId in
            guard let self else { return }
            self.handleTitleChange(windowId)
            self.debouncedScan()
        }
        tw.onWindowCreated = { [weak self] _ in
            self?.debouncedScan()
        }
        tw.onWindowDestroyed = { [weak self] in
            self?.debouncedScan()
        }

        tw.start()
        watcher = tw

        updateFocusedWindow()
        for win in tw.enumerateWindows() {
            windowTitleIcons[win.windowId] = iconFromTitle(win.title)
        }

        fullScan()

        scanTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.fullScan()
        }

        occlusionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateOcclusion()
        }

        // Start cluster scanning if in multi-app mode
        if isMultiAppMode {
            startClusterScanning()
        }
    }

    private func startClusterScanning() {
        clusterScanTimer?.invalidate()
        borderTrackingTimer?.invalidate()

        // Browser scan at 5s interval (AppleScript is ~100-200ms)
        clusterScanTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.fullScan()
        }

        // Fast border position tracking via CGWindowList (~2ms, no AppleScript)
        borderTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.updateBorderPositions()
        }
    }

    /// Fast poll: update border overlay positions and visibility from CGWindowList.
    /// Hides borders when their target window is occluded by other windows.
    private func updateBorderPositions() {
        guard !borderOverlays.isEmpty else { return }

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        let trackedIds = Set(borderOverlays.keys)

        // Build z-ordered list of all normal windows
        struct WinInfo {
            let id: CGWindowID
            let bounds: CGRect
            let isSelf: Bool
        }
        var zOrdered: [WinInfo] = []
        var trackedFrames: [CGWindowID: CGRect] = [:]

        for info in windowList {
            guard let wid = info[kCGWindowNumber as String] as? Int,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            let cgId = CGWindowID(wid)

            if trackedIds.contains(cgId) {
                trackedFrames[cgId] = bounds
            }

            if bounds.width > 50 && bounds.height > 50 {
                zOrdered.append(WinInfo(id: cgId, bounds: bounds, isSelf: ownerPID == myPID))
            }
        }

        // For each tracked border, update position and check occlusion
        for (windowId, border) in borderOverlays {
            guard let frame = trackedFrames[windowId] else {
                // Window not on screen — hide border
                border.hideBorder()
                continue
            }

            border.positionOverTarget(frame: frame)

            if !targetIsActive {
                border.hideBorder()
                continue
            }

            // Check if the target window is mostly occluded
            // Test a few points on the window's top edge (where the badge is)
            let testPoints: [(CGFloat, CGFloat)] = [
                (frame.minX + 30, frame.minY + 15),
                (frame.midX, frame.minY + 15),
                (frame.maxX - 30, frame.minY + 15),
            ]

            var frontBounds: [CGRect] = []
            var found = false
            for w in zOrdered {
                if w.id == windowId {
                    found = true
                    break
                }
                if !w.isSelf {
                    frontBounds.append(w.bounds)
                }
            }

            guard found else {
                border.hideBorder()
                continue
            }

            var occluded = false
            for (px, py) in testPoints {
                for b in frontBounds {
                    if px >= b.minX && px <= b.maxX && py >= b.minY && py <= b.maxY {
                        occluded = true
                        break
                    }
                }
                if occluded { break }
            }

            if occluded {
                border.hideBorder()
            } else {
                border.showBorder()
            }
        }
    }

    private var debounceWorkItem: DispatchWorkItem?

    private func debouncedScan() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.fullScan()
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - Core Logic

    private let scanQueue = DispatchQueue(label: "com.overline.app.scan")
    private var scanInProgress = false

    func fullScan() {
        guard watcher != nil, !scanInProgress else { return }
        scanInProgress = true

        let tw = watcher!
        let currentTargetBundleId = targetBundleId
        let isTerminal = currentTargetBundleId == TargetApp.terminal.rawValue
        let multiApp = isMultiAppMode

        scanQueue.async { [weak self] in
            guard let self else { return }

            let claudeByTty = self.detector.findClaudeProcesses()
            self.enricher.reload()

            var targetWindows: [(windowId: CGWindowID, frame: CGRect, title: String?, isMinimized: Bool)] = []
            DispatchQueue.main.sync {
                targetWindows = tw.enumerateWindows()
            }

            let ttyForWindow: [CGWindowID: String]
            if isTerminal {
                ttyForWindow = self.resolveTtysForTerminal(targetWindows.map { $0.windowId })
            } else {
                ttyForWindow = self.resolveTtysViaLsof(targetWindows, claudeByTty: claudeByTty)
            }

            if multiApp {
                // Multi-app clustering mode: delegate to ClusterEngine
                let customNamesCopy: [CGWindowID: String] = DispatchQueue.main.sync { self.customNames }

                self.clusterEngine.scan(
                    terminalWindows: targetWindows,
                    ttyForWindow: ttyForWindow,
                    claudeByTty: claudeByTty,
                    customNames: customNamesCopy
                ) { [weak self] result in
                    guard let self else { return }
                    self.scanInProgress = false
                    self.applyClusterResults(result, targetWindows: targetWindows)
                }
            } else {
                // Single-app mode: original behavior
                struct ScanResult {
                    let windowId: CGWindowID
                    let frame: CGRect
                    let project: String
                    let workingOn: String?
                }

                var results: [ScanResult] = []

                for win in targetWindows {
                    guard !win.isMinimized else { continue }

                    guard let tty = ttyForWindow[win.windowId],
                          let pids = claudeByTty[tty],
                          !pids.isEmpty else { continue }

                    let pid = pids[0]
                    guard let cwd = self.detector.resolveCwd(pid: pid) else { continue }

                    let project = ProjectNamer.projectFromCwd(cwd)
                    let enriched = self.enricher.enrich(cwd: cwd, pid: pid)
                    let workingOn = enriched?.workingOn ?? self.detector.descriptionFromTitle(win.title)
                    let displayProject: String = DispatchQueue.main.sync {
                        self.customNames[win.windowId] ?? enriched?.project ?? project
                    }

                    results.append(ScanResult(
                        windowId: win.windowId,
                        frame: win.frame,
                        project: displayProject,
                        workingOn: workingOn
                    ))
                }

                let mapped = results.map { r in
                    (windowId: r.windowId, frame: r.frame, project: r.project, workingOn: r.workingOn)
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.scanInProgress = false
                    self.applySingleAppResults(mapped, targetWindows: targetWindows)
                }
            }
        }
    }

    // MARK: - Apply Single-App Results

    private func applySingleAppResults(
        _ results: [(windowId: CGWindowID, frame: CGRect, project: String, workingOn: String?)],
        targetWindows: [(windowId: CGWindowID, frame: CGRect, title: String?, isMinimized: Bool)]
    ) {
        // Clean up any border overlays from a previous multi-app session
        destroyAllBorderOverlays()

        var activeWindowIds = Set<CGWindowID>()
        let currentStyle = Settings.shared.style

        for r in results {
            activeWindowIds.insert(r.windowId)

            let notified = windowNotified.contains(r.windowId)

            if let overlay = overlays[r.windowId] {
                overlay.update(project: r.project, status: r.workingOn)
                overlay.setAnimationStyle(currentStyle)
                overlay.setClusterColor(nil)  // Gold
                overlay.setNotification(notified)
                overlay.setWorking(!notified)
                overlay.positionRelativeTo(termFrame: r.frame)
                overlay.onSingleClick = { [weak self] in
                    self?.bringWindowToFront(r.windowId)
                }
                if targetIsActive { overlay.showLabel() }
            } else {
                let overlay = OverlayWindow()
                let wid = r.windowId
                overlay.onCustomName = { [weak self] name in
                    self?.customNames[wid] = name
                    self?.log("custom name set: window \(wid) \u{2192} \"\(name)\"")
                    self?.fullScan()
                }
                overlay.onSingleClick = { [weak self] in
                    self?.bringWindowToFront(wid)
                }
                overlay.setAnimationStyle(currentStyle)
                overlay.setClusterColor(nil)
                overlay.update(project: r.project, status: r.workingOn)
                overlay.setNotification(notified)
                overlay.setWorking(!notified)
                overlay.positionRelativeTo(termFrame: r.frame)
                if targetIsActive { overlay.showLabel() }
                overlays[r.windowId] = overlay
            }

            windowSessions[r.windowId] = (project: r.project, workingOn: r.workingOn)
        }

        let minimizedWindowIds = Set(targetWindows.filter { $0.isMinimized }.map { $0.windowId })

        for (windowId, overlay) in overlays where !activeWindowIds.contains(windowId) {
            overlay.removeLabel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { overlay.close() }
            overlays.removeValue(forKey: windowId)
            windowSessions.removeValue(forKey: windowId)
            if !minimizedWindowIds.contains(windowId) {
                customNames.removeValue(forKey: windowId)
            }
        }

        for win in targetWindows where win.isMinimized {
            overlays[win.windowId]?.hideLabel()
        }

        updateOcclusion()

        let count = activeWindowIds.count
        if count > 0 {
            let labels = activeWindowIds.compactMap { windowSessions[$0]?.project }
            log("\(count) session\(count == 1 ? "" : "s"): \(labels.joined(separator: ", "))")
        }

        // Update bento grid if active
        if bentoManager.isActive, let tw = watcher {
            bentoManager.updateWindows(collectLabeledWindows(watcher: tw))
        }
    }

    // MARK: - Apply Multi-App Cluster Results

    private func applyClusterResults(
        _ result: ClusterEngine.ScanResult,
        targetWindows: [(windowId: CGWindowID, frame: CGRect, title: String?, isMinimized: Bool)]
    ) {
        currentColorAssignments = result.colorAssignments
        let currentStyle = Settings.shared.style

        // Rebuild cluster membership maps
        windowToCluster.removeAll()
        clusterWindows.removeAll()
        clusterPorts.removeAll()

        var activeTerminalIds = Set<CGWindowID>()
        var activeBorderIds = Set<CGWindowID>()

        for cluster in result.clusters {
            let color = cluster.color
            let clusterName = cluster.projectName

            // Store all active ports for this cluster (from ports.json + server probe)
            clusterPorts[clusterName] = result.activePorts[clusterName] ?? []

            // Populate cluster membership for all windows in this cluster
            var allClusterWindowIds = Set<CGWindowID>()
            for win in cluster.windows {
                allClusterWindowIds.insert(win.cgWindowId)
                windowToCluster[win.cgWindowId] = clusterName
            }
            clusterWindows[clusterName] = allClusterWindowIds

            // Terminal windows — full label overlays
            for win in cluster.terminalWindows {
                activeTerminalIds.insert(win.cgWindowId)

                let notified = windowNotified.contains(win.cgWindowId)
                let project = win.project ?? clusterName
                let workingOn = win.workingOn

                if let overlay = overlays[win.cgWindowId] {
                    overlay.update(project: project, status: workingOn)
                    overlay.setAnimationStyle(currentStyle)
                    overlay.setClusterColor(color.color)
                    overlay.setNotification(notified)
                    overlay.setWorking(!notified)
                    overlay.positionRelativeTo(termFrame: win.frame)
                    overlay.onSingleClick = { [weak self] in
                        self?.bringClusterToFront(projectName: clusterName)
                    }
                    if targetIsActive { overlay.showLabel() }
                } else {
                    let overlay = OverlayWindow()
                    let wid = win.cgWindowId
                    overlay.onCustomName = { [weak self] name in
                        self?.customNames[wid] = name
                        self?.log("custom name set: window \(wid) \u{2192} \"\(name)\"")
                        self?.fullScan()
                    }
                    overlay.onSingleClick = { [weak self] in
                        self?.bringClusterToFront(projectName: clusterName)
                    }
                    overlay.setAnimationStyle(currentStyle)
                    overlay.setClusterColor(color.color)
                    overlay.update(project: project, status: workingOn)
                    overlay.setNotification(notified)
                    overlay.setWorking(!notified)
                    overlay.positionRelativeTo(termFrame: win.frame)
                    if targetIsActive { overlay.showLabel() }
                    overlays[wid] = overlay
                }

                windowSessions[win.cgWindowId] = (project: project, workingOn: workingOn)
            }

            // Browser + Desktop App windows — border overlays
            let nonTerminalWindows = cluster.browserWindows + cluster.desktopAppWindows
            for win in nonTerminalWindows {
                activeBorderIds.insert(win.cgWindowId)

                if let border = borderOverlays[win.cgWindowId] {
                    border.update(projectName: clusterName, colorName: color.name)
                    border.setBorderColor(color.color)
                    border.positionOverTarget(frame: win.frame)
                    border.trackedWindowId = win.cgWindowId
                    border.trackedBundleId = win.bundleId
                    border.onClicked = { [weak self] in
                        self?.bringClusterToFront(projectName: clusterName)
                    }
                    if targetIsActive { border.showBorder() }
                } else {
                    let border = BorderOverlayWindow()
                    border.update(projectName: clusterName, colorName: color.name)
                    border.setBorderColor(color.color)
                    border.positionOverTarget(frame: win.frame)
                    border.trackedWindowId = win.cgWindowId
                    border.trackedBundleId = win.bundleId
                    border.onClicked = { [weak self] in
                        self?.bringClusterToFront(projectName: clusterName)
                    }
                    if targetIsActive { border.showBorder() }
                    borderOverlays[win.cgWindowId] = border
                }
            }
        }

        // Clean up stale terminal overlays
        let minimizedWindowIds = Set(targetWindows.filter { $0.isMinimized }.map { $0.windowId })

        for (windowId, overlay) in overlays where !activeTerminalIds.contains(windowId) {
            overlay.removeLabel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { overlay.close() }
            overlays.removeValue(forKey: windowId)
            windowSessions.removeValue(forKey: windowId)
            if !minimizedWindowIds.contains(windowId) {
                customNames.removeValue(forKey: windowId)
            }
        }

        // Clean up stale border overlays
        for (windowId, border) in borderOverlays where !activeBorderIds.contains(windowId) {
            border.removeBorder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { border.close() }
            borderOverlays.removeValue(forKey: windowId)
        }

        for win in targetWindows where win.isMinimized {
            overlays[win.windowId]?.hideLabel()
        }

        updateOcclusion()

        let totalTerminals = activeTerminalIds.count
        let totalBorders = activeBorderIds.count
        if totalTerminals > 0 || totalBorders > 0 {
            let clusterNames = result.clusters.map { "\($0.projectName) (\($0.color.name))" }
            log("\(result.clusters.count) cluster\(result.clusters.count == 1 ? "" : "s"): \(clusterNames.joined(separator: ", ")) | \(totalTerminals) labels, \(totalBorders) borders")
        }

        // Update bento grid if active
        if bentoManager.isActive, let tw = watcher {
            bentoManager.updateWindows(collectLabeledWindows(watcher: tw))
        }
    }

    // MARK: - Bring to Front

    /// Bring a single terminal window to the front (single-app mode).
    private func bringWindowToFront(_ windowId: CGWindowID) {
        guard let targetApp = findTargetApp() else { return }
        let axApp = AXUIElementCreateApplication(targetApp.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }

        for axWin in axWindows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(axWin, &wid) == .success, wid == windowId {
                AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
                break
            }
        }
        targetApp.activate()
    }

    /// Bring all windows in a cluster to the front and snap companion windows next to the terminal.
    private func bringClusterToFront(projectName: String) {
        guard let windowIds = clusterWindows[projectName], !windowIds.isEmpty else { return }
        log("Bringing cluster to front: \(projectName) (\(windowIds.count) windows)")

        // Find the terminal window's frame (anchor)
        var terminalFrame: CGRect?
        var terminalWid: CGWindowID = 0
        for wid in windowIds where overlays[wid] != nil {
            if let tw = watcher, let frame = tw.frameForWindow(wid) {
                terminalFrame = frame
                terminalWid = wid
                break
            }
        }

        // Collect companion windows (browser/desktop app) with their bundle IDs
        struct CompanionWindow {
            let wid: CGWindowID
            let bundleId: String
        }
        var companions: [CompanionWindow] = []
        for wid in windowIds {
            if let border = borderOverlays[wid], !border.trackedBundleId.isEmpty {
                companions.append(CompanionWindow(wid: wid, bundleId: border.trackedBundleId))
            }
        }

        // Raise terminal window
        if let targetApp = findTargetApp(), terminalWid != 0 {
            let axApp = AXUIElementCreateApplication(targetApp.processIdentifier)
            if let axWin = axWindowForId(axApp: axApp, windowId: terminalWid) {
                AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
            }
        }

        // Position and raise companion windows next to the terminal
        if let anchor = terminalFrame {
            let screenWidth = NSScreen.main?.frame.width ?? 1920
            let gap: CGFloat = 8

            // Place companions to the right of the terminal, stacking vertically if multiple
            var nextX = anchor.origin.x + anchor.width + gap
            var nextY = anchor.origin.y

            for (i, companion) in companions.enumerated() {
                guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == companion.bundleId }) else { continue }

                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                guard let axWin = axWindowForId(axApp: axApp, windowId: companion.wid) else { continue }

                // Get current size of the companion window
                var sizeRef: CFTypeRef?
                var size = CGSize(width: 800, height: 600)
                if AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeRef) == .success, let sizeRef {
                    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                }

                // If it would go off-screen right, place to the left of terminal instead
                var x = nextX
                if x + size.width > screenWidth {
                    x = anchor.origin.x - size.width - gap
                }

                // Set position
                var point = CGPoint(x: x, y: nextY)
                if let posValue = AXValueCreate(.cgPoint, &point) {
                    AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posValue)
                }

                AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
                app.activate()

                // Stack next companion below this one
                nextY += size.height + gap
                if i == 0 { nextX = x } // Keep same column
            }
        } else {
            // No terminal anchor — just raise everything
            for companion in companions {
                guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == companion.bundleId }) else { continue }
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                if let axWin = axWindowForId(axApp: axApp, windowId: companion.wid) {
                    AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
                }
                app.activate()
            }
        }

        // Focus matching localhost tabs in browsers (even if no border exists yet)
        let ports = clusterPorts[projectName] ?? []
        if !ports.isEmpty {
            log("Isolating browser tabs for ports: \(ports.sorted())")
            focusBrowserTabsForPorts(ports, nextToFrame: terminalFrame)
        } else {
            log("No active ports for cluster \(projectName)")
        }

        // Finally, activate the terminal app so it's frontmost
        if let termApp = findTargetApp() {
            termApp.activate()
        }

        // Refresh overlays after repositioning
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.refreshOverlayPositions()
            self?.updateBorderPositions()
            self?.updateOcclusion()
        }
    }

    /// Isolate matching localhost tabs into their own windows and position next to terminal.
    /// If a tab is already alone in its window, just repositions it.
    private func focusBrowserTabsForPorts(_ ports: Set<Int>, nextToFrame anchor: CGRect?) {
        for bundleId in Settings.shared.enabledBrowserBundleIds {
            guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleId }) else { continue }

            let appName: String
            switch bundleId {
            case BrowserApp.chrome.rawValue: appName = "Google Chrome"
            case BrowserApp.arc.rawValue:    appName = "Arc"
            case BrowserApp.safari.rawValue: appName = "Safari"
            default: continue
            }

            let portListAS = ports.map { "\"\($0)\"" }.joined(separator: ", ")

            if bundleId == BrowserApp.safari.rawValue {
                isolateSafariTab(ports: ports, anchor: anchor)
            } else {
                isolateChromeTab(appName: appName, portListAS: portListAS, anchor: anchor)
            }
        }
    }

    /// Chrome/Arc: find matching localhost tab, pull it into its own window, position it.
    private func isolateChromeTab(appName: String, portListAS: String, anchor: CGRect?) {
        let boundsClause: String
        if let anchor = anchor {
            let x = Int(anchor.origin.x + anchor.width + 8)
            let y = Int(anchor.origin.y)
            let w = min(900, Int(NSScreen.main?.frame.width ?? 1920) - x - 20)
            let h = Int(anchor.height)
            boundsClause = "set bounds of newWin to {\(x), \(y), \(x + w), \(y + h)}"
        } else {
            boundsClause = ""
        }

        let script = """
        tell application "\(appName)"
            set portTargets to {\(portListAS)}
            repeat with w in windows
                set tabCount to count of tabs of w
                repeat with i from 1 to tabCount
                    set t to tab i of w
                    set tabURL to URL of t
                    set locIdx to offset of "localhost:" in tabURL
                    if locIdx > 0 then
                        set afterHost to text (locIdx + 10) thru -1 of tabURL
                        set portStr to ""
                        repeat with j from 1 to length of afterHost
                            set c to character j of afterHost
                            if c is in "0123456789" then
                                set portStr to portStr & c
                            else
                                exit repeat
                            end if
                        end repeat
                        if portStr is in portTargets then
                            if tabCount is 1 then
                                set index of w to 1
                                \(boundsClause.replacingOccurrences(of: "newWin", with: "w"))
                                activate
                                return "repositioned"
                            else
                                set targetURL to URL of t
                                delete t
                                set newWin to make new window
                                set URL of active tab of newWin to targetURL
                                \(boundsClause)
                                activate
                                return "isolated"
                            end if
                        end if
                    end if
                end repeat
            end repeat
            return "none"
        end tell
        """

        _ = detector.runCommand("/usr/bin/osascript", args: ["-e", script])
    }

    /// Safari: find matching localhost tab, pull it into its own window, position it.
    private func isolateSafariTab(ports: Set<Int>, anchor: CGRect?) {
        let portListAS = ports.map { "\"\($0)\"" }.joined(separator: ", ")
        let boundsClause: String
        if let anchor = anchor {
            let x = Int(anchor.origin.x + anchor.width + 8)
            let y = Int(anchor.origin.y)
            let w = min(900, Int(NSScreen.main?.frame.width ?? 1920) - x - 20)
            let h = Int(anchor.height)
            boundsClause = "set bounds of newWin to {\(x), \(y), \(x + w), \(y + h)}"
        } else {
            boundsClause = ""
        }

        let script = """
        tell application "Safari"
            set portTargets to {\(portListAS)}
            repeat with w in windows
                set tabCount to count of tabs of w
                repeat with t in tabs of w
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
                        if portStr is in portTargets then
                            if tabCount is 1 then
                                set index of w to 1
                                \(boundsClause.replacingOccurrences(of: "newWin", with: "w"))
                                return "repositioned"
                            else
                                set targetURL to URL of t
                                close t
                                make new document with properties {URL:targetURL}
                                \(boundsClause.replacingOccurrences(of: "newWin", with: "window 1"))
                                return "isolated"
                            end if
                        end if
                    end if
                end repeat
            end repeat
            return "none"
        end tell
        """
        _ = detector.runCommand("/usr/bin/osascript", args: ["-e", script])
    }

    /// Find an AXUIElement window by CGWindowID within an app.
    private func axWindowForId(axApp: AXUIElement, windowId: CGWindowID) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }

        for axWin in axWindows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(axWin, &wid) == .success, wid == windowId {
                return axWin
            }
        }
        return nil
    }

    // MARK: - TTY Resolution

    private var ttyCache: (mapping: [CGWindowID: String], timestamp: Date)?
    private let ttyCacheTTL: TimeInterval = 5

    private func resolveTtysForTerminal(_ windowIds: [CGWindowID]) -> [CGWindowID: String] {
        if let cached = ttyCache, Date().timeIntervalSince(cached.timestamp) < ttyCacheTTL {
            return cached.mapping
        }

        let script = """
        tell application "Terminal"
            set output to ""
            repeat with w in windows
                set wid to id of w
                repeat with t in tabs of w
                    try
                        if selected of t then
                            set ttyDev to tty of t
                            set output to output & wid & ":" & ttyDev & linefeed
                        end if
                    end try
                end repeat
            end repeat
            return output
        end tell
        """

        guard let output = runShellCommand("/usr/bin/osascript", args: ["-e", script]) else {
            return ttyCache?.mapping ?? [:]
        }

        var result: [CGWindowID: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let windowId = CGWindowID(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let tty = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tty.isEmpty {
                result[windowId] = tty
            }
        }

        ttyCache = (mapping: result, timestamp: Date())
        return result
    }

    private func resolveTtysViaLsof(
        _ windows: [(windowId: CGWindowID, frame: CGRect, title: String?, isMinimized: Bool)],
        claudeByTty: [String: [pid_t]]
    ) -> [CGWindowID: String] {
        if let cached = ttyCache, Date().timeIntervalSince(cached.timestamp) < ttyCacheTTL {
            return cached.mapping
        }

        var result: [CGWindowID: String] = [:]
        let allTtys = Array(claudeByTty.keys)

        if windows.count == 1 && allTtys.count == 1 {
            result[windows[0].windowId] = allTtys[0]
        } else {
            for win in windows {
                guard let title = win.title, !title.isEmpty else { continue }
                for (tty, pids) in claudeByTty {
                    guard result.values.contains(tty) == false else { continue }
                    if let pid = pids.first,
                       let cwd = detector.resolveCwd(pid: pid) {
                        let project = ProjectNamer.projectFromCwd(cwd)
                        if title.localizedCaseInsensitiveContains(project) ||
                           title.localizedCaseInsensitiveContains(cwd.split(separator: "/").last.map(String.init) ?? "") {
                            result[win.windowId] = tty
                            break
                        }
                    }
                }
            }

            let assignedTtys = Set(result.values)
            var remainingTtys = allTtys.filter { !assignedTtys.contains($0) }
            for win in windows where result[win.windowId] == nil && !remainingTtys.isEmpty {
                result[win.windowId] = remainingTtys.removeFirst()
            }
        }

        ttyCache = (mapping: result, timestamp: Date())
        return result
    }

    // MARK: - Helpers

    private func findTargetApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == self.targetBundleId
        }
    }

    private func destroyAllOverlays() {
        for (_, overlay) in overlays {
            overlay.removeLabel()
            overlay.close()
        }
        overlays.removeAll()
        windowSessions.removeAll()
    }

    private func destroyAllBorderOverlays() {
        for (_, border) in borderOverlays {
            border.removeBorder()
            border.close()
        }
        borderOverlays.removeAll()
    }

    private func runShellCommand(_ path: String, args: [String]) -> String? {
        detector.runCommand(path, args: args)
    }

    // MARK: - App Launch/Quit Observers

    @objc private func appLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == targetBundleId else { return }

        log("\(Settings.shared.targetAppName) launched")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startWatching()
        }
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == targetBundleId else { return }

        log("\(Settings.shared.targetAppName) quit")
        if bentoManager.isActive { deactivateBentoMode() }
        watcher?.stop()
        watcher = nil
        scanTimer?.invalidate()
        scanTimer = nil
        occlusionTimer?.invalidate()
        occlusionTimer = nil
        clusterScanTimer?.invalidate()
        clusterScanTimer = nil
        borderTrackingTimer?.invalidate()
        borderTrackingTimer = nil
        destroyAllOverlays()
        destroyAllBorderOverlays()
    }
}

// MARK: - Bento Setting Edit Helper

private class BentoSettingEdit: NSObject {
    let label: String
    let getter: () -> CGFloat
    let setter: (CGFloat) -> Void
    let menuItem: NSMenuItem

    init(label: String, getter: @escaping () -> CGFloat, setter: @escaping (CGFloat) -> Void, menuItem: NSMenuItem) {
        self.label = label
        self.getter = getter
        self.setter = setter
        self.menuItem = menuItem
    }
}
