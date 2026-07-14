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
            dependencies: ["Libmpv-GPL", "_MPVKit-GPL"],
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
            name: "MPVKit-GPL",
            targets: ["_MPVKit-GPL", "MPVKitSampleBufferGPL"]
        ),
        .library(
            name: "MPVKitSampleBuffer-GPL",
            targets: ["MPVKitSampleBufferGPL"]
        ),
    ],
    targets: [
        .target(
            name: "MPVKitSampleBufferGPL",
            dependencies: ["MPVKitSampleBufferCore", "_MPVKit-GPL", "Libmpv-GPL", "_FFmpeg-GPL", "Libuchardet", "Libbluray"],
            path: "Sources/MPVKitSampleBufferGPL",
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
            name: "_MPVKit-GPL",
            dependencies: [
                "Libmpv-GPL", "_FFmpeg-GPL", "Libuchardet", "Libbluray",
                .target(name: "Libluajit", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/_MPVKit-GPL",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .target(
            name: "_FFmpeg-GPL",
            dependencies: [
                "Libavcodec-GPL", "Libavdevice-GPL", "Libavfilter-GPL", "Libavformat-GPL", "Libavutil-GPL", "Libswresample-GPL", "Libswscale-GPL",
                "Libssl", "Libcrypto", "Libass", "Libfreetype", "Libfribidi", "Libharfbuzz",
                "MoltenVK", "Libshaderc_combined", "lcms2", "Libplacebo", "Libdovi", "Libunibreak",
                "Libsmbclient", "gmp", "nettle", "hogweed", "gnutls", "Libdav1d", "Libuavs3d"
            ],
            path: "Sources/_FFmpeg-GPL",
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

        mpvkitBinaryTarget(
            name: "Libcrypto",
            url: "https://github.com/mpvkit/openssl-build/releases/download/3.3.5/Libcrypto.xcframework.zip",
            checksum: "593283be2a90f7fd66f6e6ed331b2f099cf403e0926fe3b4ac09a7062b793965"
        ),
        mpvkitBinaryTarget(
            name: "Libssl",
            url: "https://github.com/mpvkit/openssl-build/releases/download/3.3.5/Libssl.xcframework.zip",
            checksum: "ff5ffd43d015d7285fd37e4a3145b25cbd8d2842740bd629a711c299a20e226a"
        ),

        mpvkitBinaryTarget(
            name: "gmp",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gmp.xcframework.zip",
            checksum: "ad33c7a08f4cdcb9924c8f0e6d9a054dad33d7794b97667bf8b6fb2b236ae585"
        ),

        mpvkitBinaryTarget(
            name: "nettle",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/nettle.xcframework.zip",
            checksum: "0fdf3ebf8bd7b8bc8eee837cf27261cb4c52ae520b6576a2f468656aa1691e02"
        ),
        mpvkitBinaryTarget(
            name: "hogweed",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/hogweed.xcframework.zip",
            checksum: "25727c9fa67287fa0a4f4722f88bb8be669b23cd7e837e2d00870eb8a25d3f27"
        ),

        mpvkitBinaryTarget(
            name: "gnutls",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gnutls.xcframework.zip",
            checksum: "3dbec5809339189bf9679e218c6cff387ebf8fb72745927835afc2678f5c9f4d"
        ),

        mpvkitBinaryTarget(
            name: "Libunibreak",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libunibreak.xcframework.zip",
            checksum: "940d9833cf4477d0a260d9f2b4066125bc0ff7bbc111ac3c90e774765b77a559"
        ),

        mpvkitBinaryTarget(
            name: "Libfreetype",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libfreetype.xcframework.zip",
            checksum: "496ca62488530e14b1e4624d20ee2b237c0bd675cd70c19da578a5768302d02d"
        ),

        mpvkitBinaryTarget(
            name: "Libfribidi",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libfribidi.xcframework.zip",
            checksum: "bc15e097b892f2f90424e4a27ba287070cc2f98a74a4da10e6d2481d15cf5ff9"
        ),

        mpvkitBinaryTarget(
            name: "Libharfbuzz",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libharfbuzz.xcframework.zip",
            checksum: "aa8e0b9ca0387dac74e3e93c86e34d11982bb013b28022d0e6966a8427a35b2e"
        ),

        mpvkitBinaryTarget(
            name: "Libass",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libass.xcframework.zip",
            checksum: "3f4c576d2818ceb4544aa2a20e1f55846511c5e706fd19adc3ea9fd842270498"
        ),

        mpvkitBinaryTarget(
            name: "Libsmbclient",
            url: "https://github.com/mpvkit/libsmbclient-build/releases/download/4.15.13-2512/Libsmbclient.xcframework.zip",
            checksum: "3a53375fab11bc888cc553664ea5dd902208d04f0cc21ec746302bf356246b6f"
        ),

        mpvkitBinaryTarget(
            name: "Libbluray",
            url: "https://github.com/mpvkit/libbluray-build/releases/download/1.4.0/Libbluray.xcframework.zip",
            checksum: "bc037d34e2b0b5ab7f202fb371f5fb298136cc66fdf406c2172185d06f53f18d"
        ),

        mpvkitBinaryTarget(
            name: "Libuavs3d",
            url: "https://github.com/mpvkit/libuavs3d-build/releases/download/1.2.1/Libuavs3d.xcframework.zip",
            checksum: "bd046296eb1772b596a8bb0cfc8c1b588165db85d77d214bc961ac658dab0d5a"
        ),

        mpvkitBinaryTarget(
            name: "Libdovi",
            url: "https://github.com/mpvkit/libdovi-build/releases/download/3.3.2/Libdovi.xcframework.zip",
            checksum: "e693e239808350868e79c5448ef9f02e2716bc822dd8632a41a368a1eae5ca7d"
        ),

        mpvkitBinaryTarget(
            name: "MoltenVK",
            url: "https://github.com/mpvkit/moltenvk-build/releases/download/1.4.1/MoltenVK.xcframework.zip",
            checksum: "9bd1ca1e4563bacd25d6e55d37b10341d50b2601bc2684bc332188e79daa2b79"
        ),

        mpvkitBinaryTarget(
            name: "Libshaderc_combined",
            url: "https://github.com/mpvkit/libshaderc-build/releases/download/2025.5.0/Libshaderc_combined.xcframework.zip",
            checksum: "758047b615708575b580eb960a2d083f760a29dc462d6eaa360416c946ce433b"
        ),

        mpvkitBinaryTarget(
            name: "lcms2",
            url: "https://github.com/mpvkit/lcms2-build/releases/download/2.17.0/lcms2.xcframework.zip",
            checksum: "dc0dce0606f6ab6841a8ec5a6bd4448e2f3ef00661a050460f806c9393dc6982"
        ),

        mpvkitBinaryTarget(
            name: "Libplacebo",
            url: "https://github.com/mpvkit/libplacebo-build/releases/download/7.360.1/Libplacebo.xcframework.zip",
            checksum: "2fa3d54cb81f302d6f11c7b2f509af30944381c3b11ee9d35096eb4637a6e2dd"
        ),

        mpvkitBinaryTarget(
            name: "Libdav1d",
            url: "https://github.com/mpvkit/libdav1d-build/releases/download/1.5.2-xcode/Libdav1d.xcframework.zip",
            checksum: "8a8b78e23e28ecc213232805f3c1936141fc9befe113e87234f4f897f430a532"
        ),

        mpvkitBinaryTarget(
            name: "Libavcodec-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.1/Libavcodec-GPL.xcframework.zip",
            checksum: "575cf30be0e0310263ad0dda81706a72c204b79f37d250d26c741b7278cfada3"
        ),
        mpvkitBinaryTarget(
            name: "Libavdevice-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.1/Libavdevice-GPL.xcframework.zip",
            checksum: "b69e5d460566bdbd81ae02c87f618417c9d488439e4b8ba1b2f529c23272d6e4"
        ),
        mpvkitBinaryTarget(
            name: "Libavformat-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.1/Libavformat-GPL.xcframework.zip",
            checksum: "fcd5137903856939f53aee5d12ab674c604faf647dc85531d999aa83bbb205ee"
        ),
        mpvkitBinaryTarget(
            name: "Libavfilter-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.1/Libavfilter-GPL.xcframework.zip",
            checksum: "0d92788240fc9d0d22e7e21ca9a96c52b911bd3bacd8a9cf1b03f9673aa4ec37"
        ),
        mpvkitBinaryTarget(
            name: "Libavutil-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.1/Libavutil-GPL.xcframework.zip",
            checksum: "eb6760c39fda2a985258dabc3ee7497dafc5d79b0949b91de79aee794536554d"
        ),
        mpvkitBinaryTarget(
            name: "Libswresample-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.1/Libswresample-GPL.xcframework.zip",
            checksum: "81236939793646109a321750c4f450e64d74dd81c3ba8b1a027ba8cd6d0ac0f3"
        ),
        mpvkitBinaryTarget(
            name: "Libswscale-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.1/Libswscale-GPL.xcframework.zip",
            checksum: "e644446776c64b682220bf1fca90fc0fb875cf1b139a5db78d2882c8ff10fb7b"
        ),

        mpvkitBinaryTarget(
            name: "Libuchardet",
            url: "https://github.com/mpvkit/libuchardet-build/releases/download/0.0.8-xcode/Libuchardet.xcframework.zip",
            checksum: "503202caa0dafb6996b2443f53408a713b49f6c2d4a26d7856fd6143513a50d7"
        ),

        mpvkitBinaryTarget(
            name: "Libluajit",
            url: "https://github.com/mpvkit/libluajit-build/releases/download/2.1.0-xcode/Libluajit.xcframework.zip",
            checksum: "8e76f267ee100ff5f3bbde7641b2240566df722241cdf8e135be7ef3d29e237a"
        ),

        mpvkitBinaryTarget(
            name: "Libmpv-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.1/Libmpv-GPL.xcframework.zip",
            checksum: "1f3bf91e3b16ca637e14b465aea91187c5ffbf98c24bf1a4f9736e66677f231b"
        ),
        //AUTO_GENERATE_TARGETS_END//
        .testTarget(
            name: "MPVKitSampleBufferCoreTests",
            dependencies: ["MPVKitSampleBufferCore"],
            path: "Tests/MPVKitSampleBufferCoreTests"
        ),
    ]
)
