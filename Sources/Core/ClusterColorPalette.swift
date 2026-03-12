import AppKit

/// 8 Zenith-compatible accent colors for project clustering.
/// Index 0 (Gold) is used when only one cluster is active, matching the original behavior.
/// Multiple clusters get distinct colors via stable hash assignment.
enum ClusterColorPalette {
    struct ClusterColor {
        let name: String
        let hex: Int
        let color: NSColor
    }

    static let colors: [ClusterColor] = [
        ClusterColor(name: "Gold",     hex: 0xC8A064, color: NSColor(srgbRed: 0xC8/255, green: 0xA0/255, blue: 0x64/255, alpha: 1)),
        ClusterColor(name: "Sage",     hex: 0x7EC896, color: NSColor(srgbRed: 0x7E/255, green: 0xC8/255, blue: 0x96/255, alpha: 1)),
        ClusterColor(name: "Teal",     hex: 0x6BA3BE, color: NSColor(srgbRed: 0x6B/255, green: 0xA3/255, blue: 0xBE/255, alpha: 1)),
        ClusterColor(name: "Coral",    hex: 0xD4756A, color: NSColor(srgbRed: 0xD4/255, green: 0x75/255, blue: 0x6A/255, alpha: 1)),
        ClusterColor(name: "Lavender", hex: 0x9B7DB8, color: NSColor(srgbRed: 0x9B/255, green: 0x7D/255, blue: 0xB8/255, alpha: 1)),
        ClusterColor(name: "Amber",    hex: 0xD4A054, color: NSColor(srgbRed: 0xD4/255, green: 0xA0/255, blue: 0x54/255, alpha: 1)),
        ClusterColor(name: "Rose",     hex: 0xC87A8A, color: NSColor(srgbRed: 0xC8/255, green: 0x7A/255, blue: 0x8A/255, alpha: 1)),
        ClusterColor(name: "Mint",     hex: 0x64C8A0, color: NSColor(srgbRed: 0x64/255, green: 0xC8/255, blue: 0xA0/255, alpha: 1)),
    ]

    /// Default gold color (single-cluster mode).
    static let gold = colors[0]

    /// Stable color assignment: same project name always gets the same color.
    /// Uses djb2 hash to distribute evenly across the palette (skipping index 0 = gold).
    static func colorForProject(_ projectName: String) -> ClusterColor {
        let multiColors = Array(colors.dropFirst()) // indices 1..7
        var hash: UInt64 = 5381
        for c in projectName.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(c)
        }
        let idx = Int(hash % UInt64(multiColors.count))
        return multiColors[idx]
    }

    /// Assign colors to a set of project names.
    /// If only one project, returns gold. Multiple projects get distinct hash-based colors.
    /// Handles collisions by bumping to the next available color.
    static func assignColors(for projectNames: [String]) -> [String: ClusterColor] {
        if projectNames.count <= 1 {
            var result: [String: ClusterColor] = [:]
            if let name = projectNames.first {
                result[name] = gold
            }
            return result
        }

        let multiColors = Array(colors.dropFirst())
        var assignments: [String: ClusterColor] = [:]
        var usedIndices = Set<Int>()

        for name in projectNames {
            var hash: UInt64 = 5381
            for c in name.utf8 {
                hash = ((hash &<< 5) &+ hash) &+ UInt64(c)
            }
            var idx = Int(hash % UInt64(multiColors.count))

            // Resolve collisions
            var attempts = 0
            while usedIndices.contains(idx) && attempts < multiColors.count {
                idx = (idx + 1) % multiColors.count
                attempts += 1
            }

            usedIndices.insert(idx)
            assignments[name] = multiColors[idx]
        }

        return assignments
    }
}
