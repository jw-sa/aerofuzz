// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AeroFuzz",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AeroFuzz",
            path: "Sources/AeroFuzz",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        )
    ]
)
