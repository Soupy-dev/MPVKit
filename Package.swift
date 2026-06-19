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
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libmpv-GPL.xcframework.zip",
            checksum: "0d5faa2ea65d27478d1b1558a62cd4b20e755e20c6c31952c6d22590ec81f7ff"
        ),
        .binaryTarget(
            name: "Libavcodec-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libavcodec-GPL.xcframework.zip",
            checksum: "3d680e443458b9a50fc8810b53c7d59ddd61bc202f2e61237d81da066af8747c"
        ),
        .binaryTarget(
            name: "Libavdevice-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libavdevice-GPL.xcframework.zip",
            checksum: "663a9020adb08c3c7c22dc6261aa31d57a8b47e3177a36939212f3922331eb0d"
        ),
        .binaryTarget(
            name: "Libavformat-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libavformat-GPL.xcframework.zip",
            checksum: "b4956da8595d338482acff6146a66f46763095f627bfd56537556951382361c7"
        ),
        .binaryTarget(
            name: "Libavfilter-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libavfilter-GPL.xcframework.zip",
            checksum: "9210f4e73e57cd29054192c5e77ad8aa5a9d9917efc6a94c459c00e58b5e5a6c"
        ),
        .binaryTarget(
            name: "Libavutil-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libavutil-GPL.xcframework.zip",
            checksum: "1fa9fabd02925409ad8b476c139d4cd82acadcc39ba2660cf6d36ac0397925bf"
        ),
        .binaryTarget(
            name: "Libswresample-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libswresample-GPL.xcframework.zip",
            checksum: "51a8676241a467e5f0933dd73c843415e01fe4d66d401e03a7404d34f73824ec"
        ),
        .binaryTarget(
            name: "Libswscale-GPL",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libswscale-GPL.xcframework.zip",
            checksum: "17b2313f303bcd29bf52e28becce41966e92084aa9150260290ec68d0ac9254a"
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
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libavcodec.xcframework.zip",
            checksum: "a6ac6e56ccb04dfa2e8dbea9a8230c1a47de0dcefd90343ed74889c54b546bf7"
        ),
        .binaryTarget(
            name: "Libavdevice",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libavdevice.xcframework.zip",
            checksum: "8504aa3766290f32e70d0b93a8122d48cda56aca679299d2a616535a6ef18387"
        ),
        .binaryTarget(
            name: "Libavformat",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libavformat.xcframework.zip",
            checksum: "7fedca7c42608ef6ca256c87c35ab3e5ee04c0e6976a75a77f33381048f5f06c"
        ),
        .binaryTarget(
            name: "Libavfilter",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libavfilter.xcframework.zip",
            checksum: "779fbfddf163d8950efac04ac99597ec57176e77615fa6e94a5da469472cc5a6"
        ),
        .binaryTarget(
            name: "Libavutil",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libavutil.xcframework.zip",
            checksum: "56d9446f533f6662e08f9471513ada2507ffbc9b07ed178ea94aa1d30f43b2c7"
        ),
        .binaryTarget(
            name: "Libswresample",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libswresample.xcframework.zip",
            checksum: "b69e1232d0e50e42ce5f52136f0e16369548ad54856ff33b1112b99f3af2bc03"
        ),
        .binaryTarget(
            name: "Libswscale",
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libswscale.xcframework.zip",
            checksum: "865b602f022ea40e7c5d540b215df80155c1e59902635a7d8e66860d023051f0"
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
            url: "https://github.com/Soupy-dev/MPVKit/releases/download/0.41.0-eclipse-metal.3/Libmpv.xcframework.zip",
            checksum: "62db0019fd1040173c4b58ebf58b9957675147ac78152577be3abb9fc2f7fa17"
        ),
        //AUTO_GENERATE_TARGETS_END//
    ]
)
