// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TokenPanel",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "TokenPanel",
            path: "Sources/TokenPanel"
        )
    ]
)
