// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PadDisplay",
    platforms: [.macOS(.v14)],
    targets: [
        // Declares Apple's (private) CGVirtualDisplay classes so Swift can use them.
        .target(
            name: "VirtualDisplayBridge",
            path: "Sources/VirtualDisplayBridge"
        ),
        .executableTarget(
            name: "PadDisplay",
            dependencies: ["VirtualDisplayBridge"],
            path: "Sources/PadDisplay",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
            ]
        ),
    ]
)
