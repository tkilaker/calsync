// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "calsync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "calsync", path: "Sources/calsync")
    ]
)
