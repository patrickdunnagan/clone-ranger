// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CloneRanger",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CRCore", path: "Sources/CRCore"),
        .executableTarget(name: "CloneRanger", dependencies: ["CRCore"], path: "Sources/CloneRanger"),
        .executableTarget(name: "cr-cli", dependencies: ["CRCore"], path: "Sources/cr-cli"),
    ]
)
