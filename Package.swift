// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CloneRanger",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CRCore", path: "Sources/CRCore"),
        // Blackmagic RAW frame grabs. SDK headers come from Vendor/ (scripts/vendor-sdks.sh).
        .target(name: "BRAWBridge", path: "Sources/BRAWBridge",
                cxxSettings: [.unsafeFlags(["-I", Context.packageDirectory + "/Vendor/BlackmagicRAW/Include", "-std=c++17"])],
                linkerSettings: [.linkedFramework("CoreFoundation")]),
        .executableTarget(name: "CloneRanger", dependencies: ["CRCore", "BRAWBridge"], path: "Sources/CloneRanger"),
        .executableTarget(name: "cr-cli", dependencies: ["CRCore"], path: "Sources/cr-cli"),
    ]
)
