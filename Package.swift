// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pitchshift",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "pitchshift",
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
