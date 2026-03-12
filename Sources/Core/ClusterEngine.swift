import AppKit

/// Orchestrates all detectors to assemble ProjectClusters.
/// Runs detection on a background queue and delivers results on the main thread.
final class ClusterEngine {
    private let detector = SessionDetector()
    private let enricher = SessionEnricher()
    private let portResolver = PortResolver()
    private let serverProber = ServerProber()
    private let browserDetector = BrowserDetector()
    private let desktopAppDetector = DesktopAppDetector()

    private let scanQueue = DispatchQueue(label: "com.overline.app.cluster-scan")
    private var scanInProgress = false

    /// Result of a cluster scan.
    struct ScanResult {
        let clusters: [ProjectCluster]
        let colorAssignments: [String: ClusterColorPalette.ClusterColor]
        /// All active ports per project name (from ports.json, only those with running servers).
        let activePorts: [String: Set<Int>]
    }

    /// Perform a full multi-app cluster scan.
    /// Calls completion on the main thread with assembled clusters.
    func scan(
        terminalWindows: [(windowId: CGWindowID, frame: CGRect, title: String?, isMinimized: Bool)],
        ttyForWindow: [CGWindowID: String],
        claudeByTty: [String: [pid_t]],
        customNames: [CGWindowID: String],
        completion: @escaping (ScanResult) -> Void
    ) {
        guard !scanInProgress else { return }
        scanInProgress = true

        scanQueue.async { [weak self] in
            guard let self else { return }

            self.portResolver.reload()
            self.enricher.reload()

            // Step 1: Build terminal-anchored project groups
            struct TerminalSession {
                let windowId: CGWindowID
                let frame: CGRect
                let project: String
                let cwd: String
                let workingOn: String?
                let isMinimized: Bool
            }

            var sessionsByCwd: [String: [TerminalSession]] = [:]

            for win in terminalWindows {
                guard let tty = ttyForWindow[win.windowId],
                      let pids = claudeByTty[tty],
                      let pid = pids.first,
                      let cwd = self.detector.resolveCwd(pid: pid) else { continue }

                let project = ProjectNamer.projectFromCwd(cwd)
                let enriched = self.enricher.enrich(cwd: cwd, pid: pid)
                let workingOn = enriched?.workingOn ?? self.detector.descriptionFromTitle(win.title)
                let displayProject = customNames[win.windowId] ?? enriched?.project ?? project

                let session = TerminalSession(
                    windowId: win.windowId,
                    frame: win.frame,
                    project: displayProject,
                    cwd: cwd,
                    workingOn: workingOn,
                    isMinimized: win.isMinimized
                )
                sessionsByCwd[cwd, default: []].append(session)
            }

            // Step 2: Find active ports for each project's cwd
            var portsByCwd: [String: [Int]] = [:]
            var allCandidatePorts: [Int] = []
            for cwd in sessionsByCwd.keys {
                let ports = self.portResolver.portsForCwd(cwd)
                portsByCwd[cwd] = ports
                allCandidatePorts.append(contentsOf: ports)
            }

            // Step 3: Probe which ports are actually running servers
            let activePorts = self.serverProber.activePorts(from: allCandidatePorts)

            // Step 4: Find browser windows for active ports
            let browserBundleIds = Settings.shared.enabledBrowserBundleIds
            let browserWindows = activePorts.isEmpty ? [] :
                self.browserDetector.detectBrowserWindows(forPorts: activePorts, browserBundleIds: browserBundleIds)

            // Step 5: Find desktop app windows
            let desktopWindows = self.desktopAppDetector.detectDesktopAppWindows()

            // Step 6: Assemble clusters
            var clusters: [ProjectCluster] = []
            let projectNames = Array(Set(sessionsByCwd.values.flatMap { $0 }.map(\.project))).sorted()

            // Assign colors
            let colorAssignments = ClusterColorPalette.assignColors(for: projectNames)

            for (cwd, sessions) in sessionsByCwd {
                guard let firstSession = sessions.first else { continue }
                let projectName = firstSession.project
                let color = colorAssignments[projectName] ?? ClusterColorPalette.gold

                var windows: [ClusteredWindow] = []

                // Terminal windows
                for session in sessions {
                    var w = ClusteredWindow(
                        cgWindowId: session.windowId,
                        role: .terminal,
                        frame: session.frame,
                        title: session.workingOn,
                        bundleId: Settings.shared.targetBundleId
                    )
                    w.project = session.project
                    w.workingOn = session.workingOn
                    windows.append(w)
                }

                // Browser windows matching this project's ports
                let projectPorts = Set(portsByCwd[cwd] ?? []).intersection(activePorts)
                for bw in browserWindows where projectPorts.contains(bw.port) {
                    var w = ClusteredWindow(
                        cgWindowId: bw.cgWindowId,
                        role: .browser,
                        frame: bw.frame,
                        title: bw.title,
                        bundleId: bw.browserBundleId
                    )
                    w.port = bw.port
                    windows.append(w)
                }

                // Desktop app windows matching this project's dir
                let relDir: String
                let workspace = WorkspaceRoot.path
                if cwd.hasPrefix(workspace + "/") {
                    relDir = String(cwd.dropFirst(workspace.count + 1))
                } else {
                    relDir = cwd
                }
                for dw in desktopWindows {
                    if let appDir = DesktopAppDetector.projectDirForBundleId(dw.bundleId),
                       (relDir == appDir || relDir.hasPrefix(appDir + "/") || appDir.hasPrefix(relDir + "/")) {
                        let w = ClusteredWindow(
                            cgWindowId: dw.cgWindowId,
                            role: .desktopApp,
                            frame: dw.frame,
                            title: dw.title,
                            bundleId: dw.bundleId
                        )
                        windows.append(w)
                    }
                }

                clusters.append(ProjectCluster(
                    projectName: projectName,
                    cwd: cwd,
                    color: color,
                    windows: windows
                ))
            }

            // Build active ports per project name
            var activePortsByProject: [String: Set<Int>] = [:]
            for (cwd, sessions) in sessionsByCwd {
                guard let firstSession = sessions.first else { continue }
                let projectPorts = Set(portsByCwd[cwd] ?? []).intersection(activePorts)
                if !projectPorts.isEmpty {
                    activePortsByProject[firstSession.project] = projectPorts
                }
            }

            let result = ScanResult(clusters: clusters, colorAssignments: colorAssignments, activePorts: activePortsByProject)

            DispatchQueue.main.async { [weak self] in
                self?.scanInProgress = false
                completion(result)
            }
        }
    }

    /// Invalidate browser detection cache.
    func invalidateBrowserCache() {
        browserDetector.invalidateCache()
    }
}
