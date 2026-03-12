import Foundation

/// A single entry from .active-sessions.json
struct ActiveSession: Decodable {
    let sessionId: String?
    let pid: Int?
    let project: String?
    let branch: String?
    let workingOn: String?
    let recentActions: [String]?
    let touchingFiles: [String]?
    let startedAt: String?
    let updatedAt: String?
}

/// Enrichment result from matching against active sessions.
struct EnrichmentResult {
    let workingOn: String?
    let branch: String?
    let project: String?
}

/// Reads .active-sessions.json and watches for changes.
/// Matches sessions by PID, project name, or path containment.
///
/// If no .active-sessions.json exists at the workspace root, this is a no-op —
/// Overline still works, just without rich session context (working on, branch, etc.).
final class SessionEnricher {
    private let sessionsPath: String
    private var sessions: [ActiveSession] = []
    private var fileWatcherSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    init(sessionsPath: String = WorkspaceRoot.path + "/.active-sessions.json") {
        self.sessionsPath = sessionsPath
        reload()
        startWatching()
    }

    deinit {
        stopWatching()
    }

    /// Reload sessions from disk.
    func reload() {
        guard let data = FileManager.default.contents(atPath: sessionsPath) else {
            sessions = []
            return
        }

        struct SessionsFile: Decodable {
            let sessions: [ActiveSession]
        }

        do {
            let file = try JSONDecoder().decode(SessionsFile.self, from: data)
            sessions = file.sessions
        } catch {
            sessions = []
        }
    }

    /// Match a cwd/pid against active sessions for enrichment.
    func enrich(cwd: String, pid: pid_t) -> EnrichmentResult? {
        let project = ProjectNamer.projectFromCwd(cwd)

        // Pass 1: exact PID match
        for s in sessions {
            if let sPid = s.pid, sPid == Int(pid) {
                return EnrichmentResult(
                    workingOn: s.workingOn,
                    branch: s.branch,
                    project: s.project
                )
            }
        }

        // Pass 2: project name or path containment
        for s in sessions {
            guard let sProject = s.project else { continue }

            if sProject == project
                || cwd.contains(sProject)
                || (s.touchingFiles?.first?.contains(project) == true)
            {
                return EnrichmentResult(
                    workingOn: s.workingOn,
                    branch: s.branch,
                    project: s.project
                )
            }
        }

        return nil
    }

    // MARK: - File Watching

    private func startWatching() {
        fileDescriptor = open(sessionsPath, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.reload()
            }
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }

        source.resume()
        fileWatcherSource = source
    }

    private func stopWatching() {
        fileWatcherSource?.cancel()
        fileWatcherSource = nil
    }
}
