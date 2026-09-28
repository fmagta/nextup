// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NextUp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NextUp",
            path: "Sources/NextUp",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
