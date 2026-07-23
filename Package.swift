// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Polyhelm",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Polyhelm",
            path: "Sources/Polyhelm",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Conductor keeps its live state in a SQLite database; the watcher
            // opens it read-only through the system libsqlite3.
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
