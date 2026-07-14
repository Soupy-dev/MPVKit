// swift-tools-version:5.9

import Foundation
import PackageDescription

private let mpvkitPackageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .standardizedFileURL

private let mpvkitLocalArtifactsRoot: URL? = {
    guard let value = ProcessInfo.processInfo.environment["MPVKIT_LOCAL_ARTIFACTS_DIR"],
          !value.isEmpty else {
        return nil
    }

    let requested = URL(fileURLWithPath: value, relativeTo: mpvkitPackageRoot)
        .standardizedFileURL
    let packagePath = mpvkitPackageRoot.path + "/"
    guard requested.path == mpvkitPackageRoot.path
            || requested.path.hasPrefix(packagePath) else {
        fatalError("MPVKIT_LOCAL_ARTIFACTS_DIR must resolve inside the MPVKit checkout")
    }
    return requested
}()

private func mpvkitBinaryTarget(
    name: String,
    url: String,
    checksum: String
) -> Target {
    if let root = mpvkitLocalArtifactsRoot {
        var artifactNames = [name]
        if name.hasSuffix("-GPL") {
            artifactNames.append(String(name.dropLast("-GPL".count)))
        }
        let searchRoots = [
            root,
            root.appendingPathComponent("xcframework", isDirectory: true),
        ]
        for artifactSuffix in ["xcframework", "xcframework.zip"] {
            for artifactName in artifactNames {
                for searchRoot in searchRoots {
                    let fileName = "\(artifactName).\(artifactSuffix)"
                    let artifact = searchRoot.appendingPathComponent(fileName).standardizedFileURL
                    guard FileManager.default.fileExists(atPath: artifact.path) else { continue }
                    let relativePath = String(artifact.path.dropFirst(mpvkitPackageRoot.path.count + 1))
                    return .binaryTarget(name: name, path: relativePath)
                }
            }
        }
    }
    return .binaryTarget(name: name, url: url, checksum: checksum)
}

private let mpvkitNativeRuntimeHarnessTargets: [Target] = {
    guard mpvkitLocalArtifactsRoot != nil else { return [] }
    return [
        .executableTarget(
            name: "NativeApplePiPRuntimeHarness",
            dependencies: ["Libmpv", "_MPVKit"],
            path: "Tests/NativeApplePiPRuntimeHarness",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ]
}()

let package = Package(
    name: "MPVKit",
    platforms: [.macOS(.v11), .iOS(.v14), .tvOS(.v14), .visionOS(.v1)],
    products: [
        .library(
            name: "MPVKit",
            targets: ["_MPVKit", "MPVKitSampleBuffer"]
        ),
        .library(
            name: "MPVKitSampleBuffer",
            targets: ["MPVKitSampleBuffer"]
        ),
    ],
    targets: [
        .target(
            name: "MPVKitSampleBuffer",
            dependencies: ["MPVKitSampleBufferCore", "_MPVKit", "Libmpv", "_FFmpeg", "Libuchardet", "Libbluray"],
            path: "Sources/MPVKitSampleBuffer",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UIKit", .when(platforms: [.iOS, .tvOS])),
            ]
        ),
        .target(
            name: "MPVKitSampleBufferCore",
            path: "Sources/MPVKitSampleBufferCore"
        ),
    ] + mpvkitNativeRuntimeHarnessTargets + [
        .target(
            name: "_MPVKit",
            dependencies: [
                "Libmpv", "_FFmpeg", "Libuchardet", "Libbluray",
                .target(name: "Libluajit", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/_MPVKit",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .target(
            name: "_FFmpeg",
            dependencies: [
                "Libavcodec", "Libavdevice", "Libavfilter", "Libavformat", "Libavutil", "Libswresample", "Libswscale",
                "Libssl", "Libcrypto", "Libass", "Libfreetype", "Libfribidi", "Libharfbuzz",
                "MoltenVK", "Libshaderc_combined", "lcms2", "Libplacebo", "Libdovi", "Libunibreak",
                "gmp", "nettle", "hogweed", "gnutls", "Libdav1d", "Libuavs3d"
            ],
            path: "Sources/_FFmpeg",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Metal"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("expat"),
                .linkedLibrary("resolv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
        //AUTO_GENERATE_TARGETS_BEGIN//
        //AUTO_GENERATE_TARGETS_END//
    ]
)
