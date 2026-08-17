// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ComputerRuntime",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ComputerRuntime",
            path: "Sources/ComputerRuntime",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)