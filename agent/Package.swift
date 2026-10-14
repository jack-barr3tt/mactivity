// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mactivity",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Mactivity",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "MactivityTests",
            dependencies: ["Mactivity"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
