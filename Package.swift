// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Overline",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Overline",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
