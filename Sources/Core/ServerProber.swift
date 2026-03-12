import Foundation

/// Batch-checks which ports have active listening servers using a single lsof call.
final class ServerProber {
    private let detector = SessionDetector()

    /// Check which of the given ports have a process listening on them.
    /// Returns the set of ports that are active.
    func activePorts(from candidates: [Int]) -> Set<Int> {
        guard !candidates.isEmpty else { return [] }

        // Build a single lsof call that checks all ports at once
        // lsof -i TCP:PORT1,PORT2,... -sTCP:LISTEN -Fn
        let portList = candidates.map(String.init).joined(separator: ",")
        guard let output = detector.runCommand(
            "/usr/sbin/lsof",
            args: ["-i", "TCP:\(portList)", "-sTCP:LISTEN", "-Fn", "-n", "-P"]
        ) else {
            return []
        }

        // Parse lsof output — look for lines like "n*:PORT" or "n[::]:PORT" or "n127.0.0.1:PORT"
        var active = Set<Int>()
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("n") else { continue }
            // Extract port from the name field: last component after ':'
            if let colonIdx = line.lastIndex(of: ":") {
                let portStr = String(line[line.index(after: colonIdx)...])
                if let port = Int(portStr), candidates.contains(port) {
                    active.insert(port)
                }
            }
        }

        return active
    }
}
