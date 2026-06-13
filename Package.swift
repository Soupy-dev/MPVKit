// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "MPVKit",
    platforms: [.macOS(.v11), .iOS(.v14), .tvOS(.v14), .visionOS(.v1)],
    products: [
        .library(
            name: "MPVKit",
            targets: ["_MPVKit", "MPVKitSampleBuffer"]
        ),
        .library(
            name: "MPVKit-GPL",
            targets: ["_MPVKit-GPL", "MPVKitSampleBufferGPL"]
        ),
        .library(
            name: "MPVKitSampleBuffer",
            targets: ["MPVKitSampleBuffer"]
        ),
        .library(
            name: "MPVKitSampleBuffer-GPL",
            targets: ["MPVKitSampleBufferGPL"]
        ),
    ],
    targets: [
        .target(
            name: "MPVKitSampleBuffer",
            dependencies: ["Libmpv", "_FFmpeg", "Libuchardet", "Libbluray"],
            path: "Sources/MPVKitSampleBuffer",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
            ]
        ),
        .target(
            name: "MPVKitSampleBufferGPL",
            dependencies: ["Libmpv-GPL", "_FFmpeg-GPL", "Libuchardet", "Libbluray"],
            path: "Sources/MPVKitSampleBufferGPL",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
            ]
        ),
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

        .binaryTarget(
            name: "Libmpv-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libmpv-GPL.xcframework.zip",
            checksum: "6fae3e1447e7ebf5154359128d4ab53f31bc1d95c853d70f02791a15a12b01c7"
        ),
        .binaryTarget(
            name: "Libavcodec-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libavcodec-GPL.xcframework.zip",
            checksum: "a2187dc2921a9ebc44e2b4537d7be4eda84a124026dbefddc248699d4cfbb54b"
        ),
        .binaryTarget(
            name: "Libavdevice-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libavdevice-GPL.xcframework.zip",
            checksum: "6327be0e2e173c6c57862f9b7ac4296ca8ed99c1535c3731174b4eb3fea014de"
        ),
        .binaryTarget(
            name: "Libavformat-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libavformat-GPL.xcframework.zip",
            checksum: "92e0148091c4d5829c0b943a76a7b91e23ee086f8e7b97f4cbcd7bbc67517763"
        ),
        .binaryTarget(
            name: "Libavfilter-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libavfilter-GPL.xcframework.zip",
            checksum: "82001a918cc1bc3850c201900ec8bbaed8143c13ca9f5653236d0482d5827404"
        ),
        .binaryTarget(
            name: "Libavutil-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libavutil-GPL.xcframework.zip",
            checksum: "c4465991d53b93cc4b316c17601c72013fd6b714bfed3f5023528bb219faaf3c"
        ),
        .binaryTarget(
            name: "Libswresample-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libswresample-GPL.xcframework.zip",
            checksum: "0e780331d62d9a3b1179fb33f2a9a08b3ff10f4706d3f1d29c0329da5bf2a6f9"
        ),
        .binaryTarget(
            name: "Libswscale-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libswscale-GPL.xcframework.zip",
            checksum: "81929c31ad373d46966449846d328b9d14057ebc9972cae6faa1670a5725d843"
        ),
        //AUTO_GENERATE_TARGETS_BEGIN//

        .binaryTarget(
            name: "Libcrypto",
            url: "https://github.com/mpvkit/openssl-build/releases/download/3.3.5/Libcrypto.xcframework.zip",
            checksum: "593283be2a90f7fd66f6e6ed331b2f099cf403e0926fe3b4ac09a7062b793965"
        ),
        .binaryTarget(
            name: "Libssl",
            url: "https://github.com/mpvkit/openssl-build/releases/download/3.3.5/Libssl.xcframework.zip",
            checksum: "ff5ffd43d015d7285fd37e4a3145b25cbd8d2842740bd629a711c299a20e226a"
        ),

        .binaryTarget(
            name: "gmp",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gmp.xcframework.zip",
            checksum: "ad33c7a08f4cdcb9924c8f0e6d9a054dad33d7794b97667bf8b6fb2b236ae585"
        ),

        .binaryTarget(
            name: "nettle",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/nettle.xcframework.zip",
            checksum: "0fdf3ebf8bd7b8bc8eee837cf27261cb4c52ae520b6576a2f468656aa1691e02"
        ),
        .binaryTarget(
            name: "hogweed",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/hogweed.xcframework.zip",
            checksum: "25727c9fa67287fa0a4f4722f88bb8be669b23cd7e837e2d00870eb8a25d3f27"
        ),

        .binaryTarget(
            name: "gnutls",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gnutls.xcframework.zip",
            checksum: "3dbec5809339189bf9679e218c6cff387ebf8fb72745927835afc2678f5c9f4d"
        ),

        .binaryTarget(
            name: "Libunibreak",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.4/Libunibreak.xcframework.zip",
            checksum: "001087c0e927ae00f604422b539898b81eb77230ea7700597b70393cd51e946c"
        ),

        .binaryTarget(
            name: "Libfreetype",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.4/Libfreetype.xcframework.zip",
            checksum: "f2840aba1ce35e51c0595557eee82c908dac8e32108ecc0661301c06061e051c"
        ),

        .binaryTarget(
            name: "Libfribidi",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.4/Libfribidi.xcframework.zip",
            checksum: "4a55513792ef7a17893875f74cc84c56f3657e8768c07a7a96f563a11dc4b743"
        ),

        .binaryTarget(
            name: "Libharfbuzz",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.4/Libharfbuzz.xcframework.zip",
            checksum: "91558d8497d9d97bc11eeef8b744d104315893bfee8f17483d8002e14565f84b"
        ),

        .binaryTarget(
            name: "Libass",
            url: "https://github.com/mpvkit/libass-build/releases/download/0.17.4/Libass.xcframework.zip",
            checksum: "1e41f5a69c74f6c6407aab84a65ccd0b34e73fa44465f488f99bf22bd61b070d"
        ),

        .binaryTarget(
            name: "Libsmbclient",
            url: "https://github.com/mpvkit/libsmbclient-build/releases/download/4.15.13-2512/Libsmbclient.xcframework.zip",
            checksum: "3a53375fab11bc888cc553664ea5dd902208d04f0cc21ec746302bf356246b6f"
        ),

        .binaryTarget(
            name: "Libbluray",
            url: "https://github.com/mpvkit/libbluray-build/releases/download/1.4.0/Libbluray.xcframework.zip",
            checksum: "bc037d34e2b0b5ab7f202fb371f5fb298136cc66fdf406c2172185d06f53f18d"
        ),

        .binaryTarget(
            name: "Libuavs3d",
            url: "https://github.com/mpvkit/libuavs3d-build/releases/download/1.2.1-xcode/Libuavs3d.xcframework.zip",
            checksum: "1e69250279be9334cd2f6849abdc884c8e4bb29212467b6f071fdc1ac2010b6b"
        ),

        .binaryTarget(
            name: "Libdovi",
            url: "https://github.com/mpvkit/libdovi-build/releases/download/3.3.2/Libdovi.xcframework.zip",
            checksum: "e693e239808350868e79c5448ef9f02e2716bc822dd8632a41a368a1eae5ca7d"
        ),

        .binaryTarget(
            name: "MoltenVK",
            url: "https://github.com/mpvkit/moltenvk-build/releases/download/1.4.1/MoltenVK.xcframework.zip",
            checksum: "9bd1ca1e4563bacd25d6e55d37b10341d50b2601bc2684bc332188e79daa2b79"
        ),

        .binaryTarget(
            name: "Libshaderc_combined",
            url: "https://github.com/mpvkit/libshaderc-build/releases/download/2025.5.0/Libshaderc_combined.xcframework.zip",
            checksum: "758047b615708575b580eb960a2d083f760a29dc462d6eaa360416c946ce433b"
        ),

        .binaryTarget(
            name: "lcms2",
            url: "https://github.com/mpvkit/lcms2-build/releases/download/2.17.0/lcms2.xcframework.zip",
            checksum: "dc0dce0606f6ab6841a8ec5a6bd4448e2f3ef00661a050460f806c9393dc6982"
        ),

        .binaryTarget(
            name: "Libplacebo",
            url: "https://github.com/mpvkit/libplacebo-build/releases/download/7.360.1/Libplacebo.xcframework.zip",
            checksum: "2fa3d54cb81f302d6f11c7b2f509af30944381c3b11ee9d35096eb4637a6e2dd"
        ),

        .binaryTarget(
            name: "Libdav1d",
            url: "https://github.com/mpvkit/libdav1d-build/releases/download/1.5.2-xcode/Libdav1d.xcframework.zip",
            checksum: "8a8b78e23e28ecc213232805f3c1936141fc9befe113e87234f4f897f430a532"
        ),

        .binaryTarget(
            name: "Libavcodec",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libavcodec.xcframework.zip",
            checksum: "f18473c565d5b035d4c6e6c918c13612ec603a1d084910ec46d42776b4fb4490"
        ),
        .binaryTarget(
            name: "Libavdevice",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libavdevice.xcframework.zip",
            checksum: "01aa8a5d324c76eff80a395c65f037091de771bb557ed3072dd1117637fce7cc"
        ),
        .binaryTarget(
            name: "Libavformat",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libavformat.xcframework.zip",
            checksum: "01b54b91da8d7ed90ce68646a774fa8dc59dde7d6a7623f482f43d7945aec749"
        ),
        .binaryTarget(
            name: "Libavfilter",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libavfilter.xcframework.zip",
            checksum: "59fce41e31093810e4d37933b6f8f9171236528e9aee3cead1ec4a39a4e4b195"
        ),
        .binaryTarget(
            name: "Libavutil",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libavutil.xcframework.zip",
            checksum: "9fb119a691259ac9fc506d6a2a0c336268293843686a9bf772a33c0bbef5a7de"
        ),
        .binaryTarget(
            name: "Libswresample",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libswresample.xcframework.zip",
            checksum: "c2416c6e8a49752a1534a6456e5037fe9ea35c52e654543f0c57e21ea8182f03"
        ),
        .binaryTarget(
            name: "Libswscale",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libswscale.xcframework.zip",
            checksum: "c91137c4e38c10cb11a1d3af4a7d4ab4e168c3f96c72cb0f71ebac386ff7e8ff"
        ),

        .binaryTarget(
            name: "Libuchardet",
            url: "https://github.com/mpvkit/libuchardet-build/releases/download/0.0.8-xcode/Libuchardet.xcframework.zip",
            checksum: "503202caa0dafb6996b2443f53408a713b49f6c2d4a26d7856fd6143513a50d7"
        ),

        .binaryTarget(
            name: "Libluajit",
            url: "https://github.com/mpvkit/libluajit-build/releases/download/2.1.0-xcode/Libluajit.xcframework.zip",
            checksum: "8e76f267ee100ff5f3bbde7641b2240566df722241cdf8e135be7ef3d29e237a"
        ),

        .binaryTarget(
            name: "Libmpv",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0/Libmpv.xcframework.zip",
            checksum: "b5f7ad0c26acd270cd067d7dd600188d4def40fcd433c7e266c4464f46b28759"
        ),
        //AUTO_GENERATE_TARGETS_END//
    ]
)
