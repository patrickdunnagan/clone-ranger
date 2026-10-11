// swift-tools-version:5.10
import Foundation
import PackageDescription

// RED's SDK ships as a static library, so the R3D bridge only links it when it has been vendored.
let r3dLib = Context.packageDirectory + "/Vendor/RED/Lib/libR3DSDK-libcpp.a"
let haveR3D = FileManager.default.fileExists(atPath: r3dLib)

let package = Package(
    name: "CloneRanger",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CRCore", path: "Sources/CRCore"),
        // Blackmagic RAW frame grabs. SDK headers come from Vendor/ (scripts/vendor-sdks.sh).
        .target(name: "BRAWBridge", path: "Sources/BRAWBridge",
                cxxSettings: [.unsafeFlags(["-I", Context.packageDirectory + "/Vendor/BlackmagicRAW/Include", "-std=c++17"])],
                linkerSettings: [.linkedFramework("CoreFoundation")]),
        .target(name: "R3DBridge", path: "Sources/R3DBridge",
                cxxSettings: haveR3D ? [.define("HAVE_R3D_SDK"),
                                        .unsafeFlags(["-I", Context.packageDirectory + "/Vendor/RED/Include", "-std=c++17"])] : [],
                linkerSettings: haveR3D ? [.unsafeFlags([r3dLib])] : []),
        .executableTarget(name: "CloneRanger", dependencies: ["CRCore", "BRAWBridge", "R3DBridge"], path: "Sources/CloneRanger"),
        .executableTarget(name: "cr-cli", dependencies: ["CRCore"], path: "Sources/cr-cli"),
    ]
)
