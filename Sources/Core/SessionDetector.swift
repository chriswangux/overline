import AppKit

/// Detected session info for a single window.
struct SessionInfo {
    let windowId: CGWindowID
    var bounds: CGRect
    let project: String
    let workingOn: String?
    let tty: String
    let pid: pid_t
    let cwd: String
}

/// Core detection pipeline: ps -> lsof -> cwd -> project matching.
final class SessionDetector {
    /// CWD cache: pid -> (cwd, timestamp)
    private var cwdCache: [pid_t: (cwd: String, timestamp: Date)] = [:]
    private let cacheTTL: TimeInterval = 30

    // MARK: - Process Scanning

    /// Find all Claude processes grouped by tty.
    /// Single batched `ps` call, parsed into [tty: [pid]].
    func findClaudeProcesses() -> [String: [pid_t]] {
        guard let output = runCommand("/bin/ps", args: ["-eo", "pid,tty,comm"]) else {
            return [:]
        }

        var ttyMap: [String: [pid_t]] = [:]

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix("/claude") || trimmed.hasSuffix(" claude") else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = pid_t(parts[0]),
                  parts[1] != "??" else { continue }

            let tty = "/dev/" + parts[1]
            ttyMap[tty, default: []].append(pid)
        }

        return ttyMap
    }

    /// Resolve working directory for a PID via lsof, with caching.
    func resolveCwd(pid: pid_t) -> String? {
        pruneCache()

        if let cached = cwdCache[pid] {
            return cached.cwd
        }

        guard let output = runCommand("/usr/sbin/lsof", args: ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else {
            return nil
        }

        for line in output.split(separator: "\n") {
            if line.hasPrefix("n") {
                let cwd = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cwd.isEmpty {
                    cwdCache[pid] = (cwd: cwd, timestamp: Date())
                    return cwd
                }
            }
        }

        return nil
    }

    /// Extract a session description from a window title.
    /// Terminal titles look like: "project -- X Description -- sourcekit-lsp < claude ..."
    func descriptionFromTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }

        let parts = title.components(separatedBy: " \u{2014} ")
        guard parts.count >= 2 else { return nil }

        var desc = parts[1]
        if let spaceIdx = desc.firstIndex(of: " "),
           desc[desc.startIndex] != " " {
            let prefix = desc[desc.startIndex..<spaceIdx]
            if prefix.unicodeScalars.contains(where: { !$0.isASCII }) {
                desc = String(desc[desc.index(after: spaceIdx)...])
            }
        }

        desc = desc.trimmingCharacters(in: .whitespaces)
        if desc.isEmpty || desc == "Claude Code" { return nil }
        return desc
    }

    // MARK: - Private

    private func pruneCache() {
        let now = Date()
        cwdCache = cwdCache.filter { now.timeIntervalSince($0.value.timestamp) < cacheTTL }
    }

    /// Run a command synchronously, returning stdout as String.
    /// Uses posix_spawn + pipe to avoid Foundation Process/Pipe run loop issues in NSApp context.
    func runCommand(_ path: String, args: [String]) -> String? {
        var pipeFds: [Int32] = [0, 0]
        guard pipe(&pipeFds) == 0 else { return nil }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, pipeFds[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipeFds[0])
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        defer { for p in argv { if let p { free(p) } } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &fileActions, nil, argv, environ)
        posix_spawn_file_actions_destroy(&fileActions)

        close(pipeFds[1])

        guard status == 0 else {
            close(pipeFds[0])
            return nil
        }

        var output = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let n = read(pipeFds[0], buf, bufSize)
            if n <= 0 { break }
            output.append(buf, count: n)
        }
        close(pipeFds[0])

        var exitStatus: Int32 = 0
        waitpid(pid, &exitStatus, 0)

        return output.isEmpty ? nil : String(data: output, encoding: .utf8)
    }
}
