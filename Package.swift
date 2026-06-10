// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Saphire",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Saphire",
            path: "Sources/Saphire",
linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
