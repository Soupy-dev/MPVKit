#!/usr/bin/env python3

import argparse
import os
import pathlib
import plistlib
import platform
import subprocess
import tempfile


root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--source-root", type=pathlib.Path, default=root)
source_root = parser.parse_args().source_root.resolve()
if platform.system() != "Darwin":
    raise SystemExit("Native decoder recovery fence validation requires macOS")

renderer = (source_root / "Sources/MPVKitSampleBuffer/MPVGPUPlayerRenderer.swift").read_text()
gpl = (source_root / "Sources/MPVKitSampleBufferGPL/MPVGPUPlayerRenderer.swift").read_text()
if renderer != gpl:
    raise SystemExit("GPL and non-GPL GPU renderer sources differ")
core = (source_root / "Sources/MPVKitSampleBufferCore/MPVSampleBufferCore.swift").read_text()
native_harness = (source_root / "Tests/NativeApplePiPRuntimeHarness/main.swift").read_text()


def section(source, start, end):
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError("Production source extraction is ambiguous: " + start)
    return source.split(start, 1)[1].split(end, 1)[0]


events = "private enum MPVGPUPlayerEvent: Sendable {" + section(
    renderer,
    "private enum MPVGPUPlayerEvent: Sendable {",
    "private enum MPVGPUPlayerDeferredLoadAction {",
)
events += "private final class MPVGPUPlayerEventPump: @unchecked Sendable {" + section(
    renderer,
    "private final class MPVGPUPlayerEventPump: @unchecked Sendable {",
    "struct MPVSingleSessionPictureInPictureDiagnostics {",
)
reply = "@MainActor\npackage final class MPVAsyncCommandReply {" + section(
    core,
    "@MainActor\npackage final class MPVAsyncCommandReply {",
    "@MainActor\npackage final class MPVExternalSubtitleQueue {",
)
submissions = "    private func commandPrimaryAsync(_ args: [String]) async -> Int32 {" + section(
    renderer,
    "    private func commandPrimaryAsync(_ args: [String]) async -> Int32 {",
    "    private func isSafeCompatibilityVisualCommand(_ args: [String]) -> Bool {",
)
fixture_generation = "private func makeTestVideo() throws -> URL {" + section(
    native_harness,
    "private func makeTestVideo() throws -> URL {",
    "private func makeSurface(width: Int, height: Int) throws -> IOSurface {",
)
reply_handling = "        case .asyncReply(let requestID, let error):" + section(
    renderer,
    "        case .asyncReply(let requestID, let error):",
    "        case .shutdown:",
)

artifacts = pathlib.Path(os.environ.get("MPVKIT_LOCAL_ARTIFACTS_DIR", root / "dist/release"))
if not artifacts.is_absolute():
    artifacts = root / artifacts
artifacts = artifacts.resolve()
if artifacts != root and root not in artifacts.parents:
    raise SystemExit("MPVKIT_LOCAL_ARTIFACTS_DIR must be inside the MPVKit checkout")

coupled = ["Libmpv", "Libavcodec", "Libavdevice", "Libavfilter", "Libavformat",
           "Libavutil", "Libswresample", "Libswscale", "Libplacebo", "MoltenVK"]
libraries = []
framework_paths = []
for name in coupled:
    candidates = [artifacts / (name + ".xcframework"),
                  artifacts / "xcframework" / (name + ".xcframework")]
    candidates = [path for path in candidates if path.is_dir()]
    if len(candidates) != 1:
        raise RuntimeError("Missing unique native artifact: " + name)
    artifact = candidates[0]
    info = plistlib.loads((artifact / "Info.plist").read_bytes())
    slices = [item for item in info["AvailableLibraries"]
              if item["SupportedPlatform"] == "macos"
              and "SupportedPlatformVariant" not in item
              and platform.machine() in item["SupportedArchitectures"]]
    if len(slices) != 1:
        raise RuntimeError("Missing unique native macOS slice: " + name)
    item = slices[0]
    library = artifact / item["LibraryIdentifier"] / item["LibraryPath"]
    libraries.append(library / name if library.suffix == ".framework" else library)
    framework_paths.append(library.parent)

cached = root / ".build" / (platform.machine() + "-apple-macosx") / "debug"
dependencies = ["Libssl", "Libcrypto", "Libass", "Libfreetype", "Libfribidi",
                "Libharfbuzz", "Libshaderc_combined", "lcms2", "Libdovi",
                "Libunibreak", "Libsmbclient", "gmp", "nettle", "hogweed", "gnutls",
                "Libdav1d", "Libuavs3d", "Libuchardet", "Libbluray", "Libluajit"]
libraries.extend(cached / (name + ".framework") / name for name in dependencies)
for library in libraries:
    if not library.is_file():
        raise RuntimeError("Missing cached native dependency: " + str(library))

harness = r'''
private enum HarnessError: Error { case failed(String) }
private typealias RuntimeHarnessError = HarnessError

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw HarnessError.failed(message) }
}

@MainActor
private final class RecoveryHarness {
    private var mpv: OpaquePointer?
    private var isStopping = false
    private var engineGeneration: UInt64 = 1
    private var nextAsyncRequestID: UInt64 = 0
    private var pendingAsyncReplies: [UInt64: MPVAsyncCommandReply] = [:]
    private var pump: MPVGPUPlayerEventPump?
    private var nativeErrors: [String] = []
    private var loaded = false
    private var videoReconfigurations = 0
    private var holdReplies = false
    private var heldReplies: [(MPVGPUPlayerEvent, UInt64)] = []

    init() throws {
        guard let handle = mpv_create() else { throw HarnessError.failed("mpv_create failed") }
        mpv = handle
        for (name, value) in [("vo", "null"), ("ao", "null"), ("idle", "yes"),
                              ("pause", "yes"), ("hwdec", "no"), ("keep-open", "yes")] {
            let status = name.withCString { name in
                value.withCString { mpv_set_option_string(handle, name, $0) }
            }
            try require(status >= 0, "native setup option failed: " + name)
        }
        try require(mpv_initialize(handle) >= 0, "mpv_initialize failed")
        _ = mpv_request_log_messages(handle, "warn")
        let generation = engineGeneration
        let eventPump = MPVGPUPlayerEventPump(handle: handle) { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event, generation: generation)
            }
        }
        pump = eventPump
        eventPump.install()
    }

    private func handle(_ event: MPVGPUPlayerEvent, generation: UInt64) {
        guard !isStopping, engineGeneration == generation else { return }
        if holdReplies, case .asyncReply = event {
            heldReplies.append((event, generation))
            return
        }
        switch event {
__REPLY_HANDLING__
        case .logError(let message, _): nativeErrors.append(message)
        case .endFile(_, _, let error): nativeErrors.append(error ?? "unexpected native file end")
        case .fileLoaded: loaded = true
        case .videoReconfigure: videoReconfigurations += 1
        default: break
        }
    }

__SUBMISSIONS__

    private func videoSelection() -> String? {
        guard let handle = mpv,
              let value = "vid".withCString({ mpv_get_property_string(handle, $0) }) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    private func waitUntil(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try require(predicate(), "native callback did not complete within four seconds: \(label), loaded=\(loaded), videoReconfigurations=\(videoReconfigurations), pending=\(pendingAsyncReplies.count), held=\(heldReplies.count), nativeErrors=\(nativeErrors)")
    }

    func run(fixture: String) async throws {
        let invalid = await commandPrimaryAsync(["get_property", "vid"])
        try require(invalid < 0 && pendingAsyncReplies.isEmpty,
                    "legacy get_property command unexpectedly succeeded or leaked its waiter")
        try require(await fencePrimaryVideoSelectionAsync() >= 0,
                    "native GET_PROPERTY_REPLY was not forwarded to its production waiter")
        try require(await commandPrimaryAsync(["loadfile", fixture, "replace"]) >= 0,
                    "could not submit real video fixture")
        try await waitUntil("fixture load") { loaded && videoReconfigurations > 0 }
        try require(videoSelection() == "1", "real fixture did not select its video track")
        for _ in 0..<16 {
            try require(await commandPrimaryAsync(["set", "vid", "no"]) >= 0,
                        "native video deselection failed")
            try require(await fencePrimaryVideoSelectionAsync() >= 0 && videoSelection() == "no",
                        "property fence did not complete while video was deselected")
            let drained = videoReconfigurations
            try await Task.sleep(nanoseconds: 10_000_000)
            try require(videoReconfigurations == drained,
                        "old video reconfiguration crossed the deselection property fence")
            try require(await commandPrimaryAsync(["set", "vid", "1"]) >= 0,
                        "native video reselection failed")
            try await waitUntil("video reselection") { videoReconfigurations > drained }
            try require(await fencePrimaryVideoSelectionAsync() >= 0 && videoSelection() == "1",
                        "fresh video selection did not survive reconstruction")
        }
        holdReplies = true
        let cancelled = Task { await self.fencePrimaryVideoSelectionAsync() }
        try await waitUntil("held property reply") { !pendingAsyncReplies.isEmpty && !heldReplies.isEmpty }
        cancelled.cancel()
        holdReplies = false
        let delayed = heldReplies
        heldReplies.removeAll()
        for (event, generation) in delayed { handle(event, generation: generation) }
        try require(await cancelled.value >= 0 && pendingAsyncReplies.isEmpty,
                    "cancelled property fence leaked its native reply")
        holdReplies = true
        let retired = Task { await self.fencePrimaryVideoSelectionAsync() }
        try await waitUntil("held property reply") { !pendingAsyncReplies.isEmpty && !heldReplies.isEmpty }
        await stop()
        try require(await retired.value < 0 && pendingAsyncReplies.isEmpty,
                    "retirement did not release the in-flight property waiter")
        for (event, generation) in heldReplies { handle(event, generation: generation) }
        try require(pendingAsyncReplies.isEmpty, "stale native reply revived retired request state")
    }

    func stop() async {
        guard !isStopping else { return }
        isStopping = true
        engineGeneration &+= 1
        resumePendingAsyncReplies(with: -1)
        mpv = nil
        guard let pump else { return }
        self.pump = nil
        await withCheckedContinuation { continuation in
            pump.stop { continuation.resume() }
        }
    }
}

@main
private struct Main {
    @MainActor
    static func main() async {
        do {
            let harness = try RecoveryHarness()
            do {
                let fixture = try makeTestVideo()
                defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
                try await harness.run(fixture: fixture.path)
            } catch {
                await harness.stop()
                throw error
            }
            print("Native recovery fence: legacy rejection, production property reply routing, 16 video reconstructions, ordered event drain, cancellation and retirement passed.")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
'''
harness = harness.replace("__REPLY_HANDLING__", reply_handling).replace("__SUBMISSIONS__", submissions)

with tempfile.TemporaryDirectory(prefix="mpvkit-decoder-fence-") as temporary:
    temporary = pathlib.Path(temporary)
    source = temporary / "recovery.swift"
    source.write_text("import Foundation\nimport AVFoundation\nimport CoreVideo\nimport Libmpv\n"
                      + events + reply + fixture_generation + harness)
    executable = temporary / "recovery"
    command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
               "-target", platform.machine() + "-apple-macosx14.0",
               "-package-name", "mpvkit", str(source), *map(str, libraries)]
    for path in dict.fromkeys(framework_paths):
        command.extend(["-F", str(path)])
    for name in ["AppKit", "AVFoundation", "AudioToolbox", "CoreAudio", "CoreVideo",
                 "CoreFoundation", "CoreMedia", "Metal", "VideoToolbox", "QuartzCore",
                 "IOSurface", "CoreText", "Security", "CoreGraphics"]:
        command.extend(["-framework", name])
    for name in ["bz2", "iconv", "expat", "resolv", "xml2", "z", "c++"]:
        command.append("-l" + name)
    command.extend(["-o", str(executable)])
    print("Native artifact: " + str(libraries[0]), flush=True)
    subprocess.run(command, check=True, timeout=60)
    subprocess.run([str(executable)], check=True, timeout=45)
