#!/usr/bin/env python3

import argparse
import os
import pathlib
import plistlib
import platform
import subprocess
import tempfile
import wave


root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--source-root", type=pathlib.Path, default=root)
parser.add_argument("--legacy-timeline", action="store_true")
arguments = parser.parse_args()
source_root = arguments.source_root.resolve()
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

def function(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end] + "\n"


synchronization = "    private func hardwareDecoderRecoveryTimelineAnchor() -> Double? {" + section(
    renderer,
    "    private func hardwareDecoderRecoveryTimelineAnchor() -> Double? {",
    "    @discardableResult\n    private func setHardwareDecoderRecoveryVideoSelection(_ selection: String) -> Int32 {",
)
seek_handling = "        case .seek(let playlistEntryID):" + section(
    renderer,
    "        case .seek(let playlistEntryID):",
    "        case .endFile(let playlistEntryID, let reachedEOF, let error):",
)
identity = "public struct MPVLoadIdentityTracker {\n" + function(core, "    public struct Identity: Equatable, Sendable {") + "}\n"
native_access = "\n".join(function(renderer, signature) for signature in [
    "    private func commandPrimary(_ args: [String]) -> Int32 {",
    "    private func command(handle: OpaquePointer, args: [String]) -> Int32 {",
    "    private func getInt64Property(_ name: String) -> Int64? {",
    "    private func getFlagProperty(_ name: String) -> Bool? {",
    "    private func getDoubleProperty(_ name: String) -> Double? {",
    "    private func setFlagProperty(_ name: String, _ value: Bool) {",
    "    public func play(preservingHardwareDecoderRecovery: Bool = false) {",
    "    public func pause(preservingHardwareDecoderRecovery: Bool = false) {",
])
fixture_generation = fixture_generation.replace("0..<180", "0..<900")

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
    private var isRunning = true
    private var isPaused = true
    private var currentURL: URL?
    private var currentPrimaryLoadIdentity: MPVLoadIdentityTracker.Identity?
    private var playlistEntryID: Int64?
    private var activeHardwareDecoderRecoveryEpoch: UInt64?
    private var activeHardwareDecoderRecoveryGeneration: UInt64?
    private var activeHardwareDecoderRecoveryTransitionID: UInt64?
    private var hardwareDecoderRecoveryInvalidationGeneration: UInt64 = 0
    private var hardwareDecoderRecoveryTimeline: (epoch: UInt64, anchor: Double, invalidationGeneration: UInt64)?
    private var hardwareDecoderRecoverySynchronization: (
        epoch: UInt64, loadIdentity: MPVLoadIdentityTracker.Identity,
        invalidationGeneration: UInt64, selectedVideoTrackID: Int, sawSeek: Bool,
        continuation: CheckedContinuation<Bool, Never>
    )?
    private var hardwareDecoderRecoverySynchronizationTimeoutTask: Task<Void, Never>?
    private var isAwaitingPrimaryFileLoaded = false
    private var isPrimaryLoadSubmissionPending = false
    private var isPictureInPicturePrepared = false
    private var isPictureInPictureActive = false
    private var isPictureInPictureTrackOwnershipIdle = true
    private var pendingSingleSessionShutdown: Task<Void, Never>?
    private var activePictureInPictureRestore: Bool?
    private var cachedSeeking = false
    private var engineGeneration: UInt64 = 1
    private var nextAsyncRequestID: UInt64 = 0
    private var pendingAsyncReplies: [UInt64: MPVAsyncCommandReply] = [:]
    private var pump: MPVGPUPlayerEventPump?
    private var nativeErrors: [String] = []
    private var loaded = false
    private var videoReconfigurations = 0
    private var holdReplies = false
    private var heldReplies: [(MPVGPUPlayerEvent, UInt64)] = []
    private var holdTimelineEvents = false
    private var heldTimelineEvents: [(MPVGPUPlayerEvent, UInt64)] = []
    private var isBuffering = false
    private enum State { case loading, pictureInPicture, playing, paused }
    private enum PictureInPictureBackend { case compatibilityDualSession }
    private var selectedPictureInPictureBackend: PictureInPictureBackend?

    init(audioFixture: String? = nil) throws {
        guard let handle = mpv_create() else { throw HarnessError.failed("mpv_create failed") }
        mpv = handle
        for (name, value) in [("vo", "null"), ("ao", "null"), ("idle", "yes"),
                              ("pause", "yes"), ("hwdec", "no"), ("keep-open", "yes")] {
            let status = name.withCString { name in
                value.withCString { mpv_set_option_string(handle, name, $0) }
            }
            try require(status >= 0, "native setup option failed: " + name)
        }
        if let audioFixture {
            for (name, value) in [("audio-files", audioFixture), ("ao-null-buffer", "4"), ("speed", "2")] {
                let status = name.withCString { name in
                    value.withCString { mpv_set_option_string(handle, name, $0) }
                }
                try require(status >= 0, "native audio setup failed: " + name)
            }
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
        if holdTimelineEvents {
            switch event {
            case .seek, .playbackRestart:
                heldTimelineEvents.append((event, generation))
                return
            default: break
            }
        }
        switch event {
__REPLY_HANDLING__
__SEEK_HANDLING__
        case .startFile(let identifier):
            playlistEntryID = identifier
            currentPrimaryLoadIdentity = .init(sequence: 1, clientGeneration: 1)
        case .logError(let message, _): nativeErrors.append(message)
        case .endFile(_, _, let error): nativeErrors.append(error ?? "unexpected native file end")
        case .fileLoaded: loaded = true
        case .videoReconfigure: videoReconfigurations += 1
        default: break
        }
    }

__SUBMISSIONS__
__SYNCHRONIZATION__
__NATIVE_ACCESS__

    private func currentAudioTrackID() -> Int { Int(getInt64Property("aid") ?? -1) }
    private func currentVideoTrackID() -> Int { Int(getInt64Property("vid") ?? -1) }
    private func performOnMain(_ operation: () -> Void) { operation() }
    private func updateState(_ state: State) {}
    private func synchronizeCompatibilityPlaybackState(shouldRealign: Bool) {}
    private func updateSingleSessionTimeline(discontinuity: Bool) {}
    private func markPictureInPictureTimelineUpdate(requiresFrame: Bool) {}

    private func releaseTimelineEvents() {
        holdTimelineEvents = false
        let delayed = heldTimelineEvents
        heldTimelineEvents.removeAll()
        for (event, generation) in delayed { handle(event, generation: generation) }
    }

    private func currentLoadIdentity(for identifier: Int64?) -> MPVLoadIdentityTracker.Identity? {
        identifier == playlistEntryID ? currentPrimaryLoadIdentity : nil
    }

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
        try require(predicate(), "native callback did not complete within four seconds: \(label), loaded=\(loaded), videoReconfigurations=\(videoReconfigurations), pending=\(pendingAsyncReplies.count), held=\(heldReplies.count), heldTimeline=\(heldTimelineEvents.count), synchronization=\(hardwareDecoderRecoverySynchronization != nil), paused=\(getFlagProperty("pause") ?? false), seeking=\(getFlagProperty("seeking") ?? false), seekable=\(getFlagProperty("seekable") ?? false), nativeErrors=\(nativeErrors)")
    }

    func run(fixture: String) async throws {
        currentURL = URL(fileURLWithPath: fixture)
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

    func runSynchronizationFences(fixture: String) async throws {
        currentURL = URL(fileURLWithPath: fixture)
        try require(await commandPrimaryAsync(["loadfile", fixture, "replace"]) >= 0,
                    "could not submit synchronization cancellation fixture")
        try await waitUntil("synchronization cancellation fixture load") {
            loaded && videoReconfigurations > 0 && getFlagProperty("seeking") == false
        }
        guard let anchor = hardwareDecoderRecoveryTimelineAnchor() else {
            throw HarnessError.failed("synchronization cancellation anchor unavailable")
        }
        activeHardwareDecoderRecoveryEpoch = 1
        activeHardwareDecoderRecoveryGeneration = 1
        hardwareDecoderRecoveryTimeline = (1, anchor, hardwareDecoderRecoveryInvalidationGeneration)
        holdTimelineEvents = true
        let invalidated = Task { await self.synchronizeHardwareDecoderRecoveryAfterSystemResume(epoch: 1) }
        try await waitUntil("held synchronization restart") {
            hardwareDecoderRecoverySynchronization != nil && heldTimelineEvents.count >= 2
        }
        invalidateHardwareDecoderRecoveryPlaybackIntent()
        try require(await invalidated.value == false && hardwareDecoderRecoverySynchronization == nil,
                    "timeline invalidation did not retire synchronization continuation")
        releaseTimelineEvents()
        try require(hardwareDecoderRecoverySynchronization == nil,
                    "delayed seek/restart revived invalidated synchronization")

        hardwareDecoderRecoveryTimeline = (1, anchor, hardwareDecoderRecoveryInvalidationGeneration)
        holdTimelineEvents = true
        let cancelled = Task { await self.synchronizeHardwareDecoderRecoveryAfterSystemResume(epoch: 1) }
        try await waitUntil("held cancelled synchronization restart") {
            hardwareDecoderRecoverySynchronization != nil && heldTimelineEvents.count >= 2
        }
        cancelled.cancel()
        try require(await cancelled.value == false && hardwareDecoderRecoverySynchronization == nil,
                    "task cancellation did not retire synchronization continuation")
        releaseTimelineEvents()
        try require(hardwareDecoderRecoverySynchronization == nil,
                    "delayed seek/restart revived cancelled synchronization")

        hardwareDecoderRecoveryTimeline = (1, anchor, hardwareDecoderRecoveryInvalidationGeneration)
        holdTimelineEvents = true
        let timedOut = Task {
            await self.synchronizeHardwareDecoderRecoveryAfterSystemResume(epoch: 1, timeout: 0.1)
        }
        try await waitUntil("held timed-out synchronization restart") {
            hardwareDecoderRecoverySynchronization != nil && heldTimelineEvents.count >= 2
        }
        try require(await timedOut.value == false && hardwareDecoderRecoverySynchronization == nil,
                    "timeout did not retire synchronization continuation")
        releaseTimelineEvents()
        try require(hardwareDecoderRecoverySynchronization == nil,
                    "delayed seek/restart revived timed-out synchronization")

        hardwareDecoderRecoveryTimeline = (1, anchor, hardwareDecoderRecoveryInvalidationGeneration)
        holdTimelineEvents = true
        let audioOnly = Task { await self.synchronizeHardwareDecoderRecoveryAfterSystemResume(epoch: 1) }
        try await waitUntil("held audio-only synchronization restart") {
            hardwareDecoderRecoverySynchronization != nil && heldTimelineEvents.count >= 2
        }
        try require(commandPrimary(["set", "vid", "no"]) >= 0 && currentVideoTrackID() < 0,
                    "could not reproduce native video-track failure with surviving audio")
        try require(currentAudioTrackID() >= 0, "native video failure removed surviving audio")
        releaseTimelineEvents()
        try require(await audioOnly.value == false && hardwareDecoderRecoverySynchronization == nil,
                    "audio-only PLAYBACK_RESTART incorrectly proved recovered video")
        await stop()
    }

    func runTimeline(fixture: String, legacy: Bool) async throws {
        currentURL = URL(fileURLWithPath: fixture)
        try require(await commandPrimaryAsync(["loadfile", fixture, "replace"]) >= 0,
                    "could not submit timing fixture")
        try await waitUntil("timing fixture load") { loaded && videoReconfigurations > 0 }
        isPaused = false
        try require(commandPrimary(["set", "pause", "no"]) >= 0, "initial playback failed")
        try await waitUntil("audio FIFO priming") {
            (getDoubleProperty("time-pos") ?? 0) > 1 && abs(getDoubleProperty("avsync") ?? 999) < 0.2
        }
        isPaused = true
        try require(commandPrimary(["set", "pause", "yes"]) >= 0, "recovery pause failed")
        guard let anchor = hardwareDecoderRecoveryTimelineAnchor() else {
            throw HarnessError.failed("real audio recovery anchor unavailable")
        }
        try require(currentAudioTrackID() >= 0, "timing fixture did not load real selected audio")
        let priorReconfigurations = videoReconfigurations
        try require(await commandPrimaryAsync(["set", "vid", "no"]) >= 0, "timing deselect failed")
        try require(await fencePrimaryVideoSelectionAsync() >= 0, "timing drain failed")
        try require(commandPrimary(["set", "vid", "1"]) >= 0, "timing reselect failed")
        try await waitUntil("timing video reconstruction") { videoReconfigurations > priorReconfigurations }
        try await Task.sleep(nanoseconds: 100_000_000)
        activeHardwareDecoderRecoveryEpoch = 1
        activeHardwareDecoderRecoveryGeneration = 1
        hardwareDecoderRecoveryTimeline = (1, anchor, hardwareDecoderRecoveryInvalidationGeneration)
        let expectedGeneration = hardwareDecoderRecoveryInvalidationGeneration
        play(preservingHardwareDecoderRecovery: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        pause(preservingHardwareDecoderRecovery: true)
        try require(hardwareDecoderRecoveryInvalidationGeneration == expectedGeneration,
                    "recovery-owned pause/play invalidated the late synchronization owner")
        guard let freshAnchor = getDoubleProperty("audio-pts") else {
            throw HarnessError.failed("late synchronization audio clock unavailable")
        }
        try require(freshAnchor > anchor + 0.2, "late recovery fixture did not advance actual audio")
        if !legacy {
            try require(await synchronizeHardwareDecoderRecoveryAfterSystemResume(epoch: 1),
                        "production common timeline synchronization failed")
            try require(abs((getDoubleProperty("time-pos") ?? -999) - freshAnchor) < 0.1,
                        "late synchronization rewound audio consumed after the captured recovery anchor")
        }
        isPaused = false
        try require(commandPrimary(["set", "pause", "no"]) >= 0, "restored playback failed")
        try await Task.sleep(nanoseconds: 750_000_000)
        guard let audio = getDoubleProperty("audio-pts"), let video = getDoubleProperty("time-pos") else {
            throw HarnessError.failed("timing fixture clocks disappeared")
        }
        let lag = audio - video
        print("Native restored clocks: audio=\(audio) video=\(video) lag=\(lag) legacy=\(legacy)")
        try require(abs(lag) < 0.35,
                    "restored video held old audio queue debt after first frame: lag=\(lag)")
        try require(video > freshAnchor + 0.75, "restored video did not keep progressing after first frame")
        await stop()
    }

    func stop() async {
        guard !isStopping else { return }
        isStopping = true
        engineGeneration &+= 1
        invalidateHardwareDecoderRecoveryPlaybackIntent()
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
            guard let audioFixture = CommandLine.arguments.dropFirst().first else {
                throw HarnessError.failed("timing audio fixture is missing")
            }
            let cancellation = try RecoveryHarness(audioFixture: audioFixture)
            do {
                let fixture = try makeTestVideo()
                defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
                try await cancellation.runSynchronizationFences(fixture: fixture.path)
            } catch {
                await cancellation.stop()
                throw error
            }
            let timing = try RecoveryHarness(audioFixture: audioFixture)
            do {
                let fixture = try makeTestVideo()
                defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
                try await timing.runTimeline(fixture: fixture.path, legacy: CommandLine.arguments.contains("legacy"))
            } catch {
                await timing.stop()
                throw error
            }
            print("Native recovery fence and timeline: legacy rejection, ordered reply drain, 16 video reconstructions, reply cancellation/retirement, synchronization invalidation/cancellation/timeout, audio-only restart rejection, late recovery-owned pause/play and synchronized real audio/video progression passed.")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
'''
harness = (harness.replace("__REPLY_HANDLING__", reply_handling)
           .replace("__SUBMISSIONS__", submissions).replace("__SEEK_HANDLING__", seek_handling)
           .replace("__SYNCHRONIZATION__", synchronization).replace("__NATIVE_ACCESS__", native_access))

with tempfile.TemporaryDirectory(prefix="mpvkit-decoder-fence-") as temporary:
    temporary = pathlib.Path(temporary)
    source = temporary / "recovery.swift"
    source.write_text("import Foundation\nimport AVFoundation\nimport CoreVideo\nimport Libmpv\n"
                      + events + reply + identity + fixture_generation + harness)
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
    audio_fixture = temporary / "audio.wav"
    with wave.open(str(audio_fixture), "wb") as audio:
        audio.setnchannels(2)
        audio.setsampwidth(2)
        audio.setframerate(48000)
        audio.writeframes(bytes(48000 * 4 * 30))
    runtime_arguments = [str(executable), str(audio_fixture)]
    if arguments.legacy_timeline:
        runtime_arguments.append("legacy")
    subprocess.run(runtime_arguments, check=True, timeout=45)
