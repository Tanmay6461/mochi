// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchPet",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "NotchPet",
            path: "Sources/NotchPet",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
