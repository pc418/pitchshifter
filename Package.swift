// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "retune",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "retune",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        )
    ]
)
