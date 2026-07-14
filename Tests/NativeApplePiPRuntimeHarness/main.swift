import Foundation

#if os(macOS) && arch(arm64)
import AppKit
import AVFoundation
import CoreVideo
import IOSurface
import Libmpv
import Metal
import QuartzCore

private enum RuntimeHarnessError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private struct FrameSnapshot {
    let status: UInt32
    let width: UInt32
    let height: UInt32
    let pixelFormat: UInt32
    let backend: UInt32
    let token: UInt64
    let generation: UInt64
    let pts: Double
    let duration: Double
}

private final class CallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [FrameSnapshot] = []

    func append(_ frame: FrameSnapshot) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    func first(token: UInt64, generation: UInt64) -> FrameSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return frames.first { $0.token == token && $0.generation == generation }
    }

    func count(token: UInt64, generation: UInt64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.filter { $0.token == token && $0.generation == generation }.count
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }
}

private let nativeFrameCallback: mpv_apple_pip_frame_callback = { context, frame in
    guard let context, let frame else { return }
    let value = frame.pointee
    Unmanaged<CallbackRecorder>.fromOpaque(context).takeUnretainedValue().append(
        FrameSnapshot(
            status: value.status,
            width: value.width,
            height: value.height,
            pixelFormat: value.pixel_format,
            backend: value.backend,
            token: value.token,
            generation: value.generation,
            pts: value.pts,
            duration: value.duration
        )
    )
}

private let apiVersion: UInt32 = 1
private let pixelFormatBGRA: UInt32 = 0x4247_5241
private let resultOK: Int32 = 0
private let resultUnavailable: Int32 = -1
private let resultStaleGeneration: Int32 = -6
private let modeInlineOnly: UInt32 = 0
private let modeDualOutputWarmup: UInt32 = 1
private let modeOffscreenOnly: UInt32 = 2
private let modeDualOutputRestore: UInt32 = 3
private let capabilityDirectIOSurface: UInt64 = 1 << 0
private let capabilitySDRBGRA8: UInt64 = 1 << 1
private let capabilityOffscreenWithoutDrawable: UInt64 = 1 << 2
private let capabilityAsyncCompletion: UInt64 = 1 << 3
private let capabilityAsyncMetalBlit: UInt64 = 1 << 4
private let capabilityInlineRestore: UInt64 = 1 << 5
private let backendDirectIOSurface: UInt32 = 1
private let backendAsyncMetalBlit: UInt32 = 2
private let frameReady: UInt32 = 0

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw RuntimeHarnessError.failed(message) }
}

private func checkMPV(_ status: Int32, _ operation: String) throws {
    guard status >= 0 else {
        let detail = mpv_error_string(status).map(String.init(cString:)) ?? "unknown error"
        throw RuntimeHarnessError.failed("\(operation) failed with \(status): \(detail)")
    }
}

private func trace(_ message: String) {
    FileHandle.standardError.write(Data("HARNESS: \(message)\n".utf8))
}

private func makeTestVideo() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mpvkit-native-pip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("moving-gradient.mov")
    let width = 96
    let height = 64
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 180_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ]
    )
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    )
    try require(writer.canAdd(input), "AVAssetWriter rejected its deterministic video input")
    writer.add(input)
    try require(writer.startWriting(), "AVAssetWriter failed to start: \(writer.error?.localizedDescription ?? "unknown")")
    writer.startSession(atSourceTime: .zero)
    for frameIndex in 0..<180 {
        let readyDeadline = Date().addingTimeInterval(2)
        while !input.isReadyForMoreMediaData && Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        try require(input.isReadyForMoreMediaData, "AVAssetWriter backpressured the fixture encoder")
        var pixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer else {
            throw RuntimeHarnessError.failed("fixture pixel-buffer allocation failed: \(createStatus)")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            throw RuntimeHarnessError.failed("fixture pixel buffer has no base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                row[offset] = UInt8((x * 2 + frameIndex * 3) & 0xff)
                row[offset + 1] = UInt8((y * 4 + frameIndex * 2) & 0xff)
                row[offset + 2] = UInt8((x + y + frameIndex * 5) & 0xff)
                row[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        try require(
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frameIndex), timescale: 30)),
            "AVAssetWriter failed appending fixture frame \(frameIndex): \(writer.error?.localizedDescription ?? "unknown")"
        )
    }
    input.markAsFinished()
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    try require(
        finished.wait(timeout: .now() + 5) == .success,
        "AVAssetWriter timed out finishing the fixture"
    )
    try require(
        writer.status == .completed,
        "AVAssetWriter failed finishing the fixture: \(writer.error?.localizedDescription ?? "unknown")"
    )
    return url
}

private func makeSurface(width: Int, height: Int) throws -> IOSurface {
    let bytesPerRow = width * 4
    let properties: [IOSurfacePropertyKey: Any] = [
        .width: width,
        .height: height,
        .bytesPerElement: 4,
        .bytesPerRow: bytesPerRow,
        .allocSize: bytesPerRow * height,
        .pixelFormat: kCVPixelFormatType_32BGRA,
    ]
    guard let surface = IOSurface(properties: properties) else {
        throw RuntimeHarnessError.failed("IOSurface allocation failed")
    }
    return surface
}

private func makeTarget(
    surface: IOSurface,
    width: UInt32,
    height: UInt32,
    token: UInt64,
    generation: UInt64
) -> mpv_apple_pip_target {
    var target = mpv_apple_pip_target()
    target.struct_size = UInt32(MemoryLayout<mpv_apple_pip_target>.size)
    target.width = width
    target.height = height
    target.pixel_format = pixelFormatBGRA
    target.io_surface = Unmanaged.passUnretained(surface).toOpaque()
    target.token = token
    target.generation = generation
    return target
}

private func capabilityDiagnostic(_ capabilities: inout mpv_apple_pip_capabilities) -> String {
    withUnsafeBytes(of: &capabilities.diagnostic) { bytes in
        guard let baseAddress = bytes.baseAddress else { return "" }
        return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
    }
}

private func pumpEvent(_ handle: OpaquePointer, timeout: Double) -> String? {
    while let event = NSApplication.shared.nextEvent(
        matching: .any,
        until: Date(),
        inMode: .default,
        dequeue: true
    ) {
        NSApplication.shared.sendEvent(event)
    }
    NSApplication.shared.updateWindows()
    guard let event = mpv_wait_event(handle, timeout), event.pointee.event_id != MPV_EVENT_NONE else {
        return nil
    }
    if event.pointee.event_id == MPV_EVENT_LOG_MESSAGE,
       let log = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
        let prefix = log.pointee.prefix.map(String.init(cString:)) ?? "mpv"
        let text = log.pointee.text.map(String.init(cString:)) ?? ""
        return "log[\(prefix)]: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
    if event.pointee.event_id == MPV_EVENT_END_FILE,
       let endFile = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self) {
        let detail = endFile.pointee.error < 0
            ? String(cString: mpv_error_string(endFile.pointee.error))
            : "reason=\(endFile.pointee.reason.rawValue)"
        return "end-file[\(detail)]"
    }
    guard let name = mpv_event_name(event.pointee.event_id) else { return "unknown" }
    return String(cString: name)
}

private func waitUntil(
    _ handle: OpaquePointer,
    timeout: TimeInterval,
    description: String,
    condition: () -> Bool
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    var recentEvents: [String] = []
    while Date() < deadline {
        if condition() { return }
        if let event = pumpEvent(handle, timeout: 0.02) {
            recentEvents.append(event)
            if recentEvents.count > 12 { recentEvents.removeFirst() }
        }
    }
    throw RuntimeHarnessError.failed(
        "timed out waiting for \(description); recent mpv events: \(recentEvents.joined(separator: ", "))"
    )
}

private func validateSurfaceFrame(
    _ frame: FrameSnapshot,
    token: UInt64,
    generation: UInt64,
    width: UInt32,
    height: UInt32
) throws {
    try require(frame.status == frameReady, "token \(token) returned frame status \(frame.status)")
    try require(frame.token == token, "callback token mismatch")
    try require(frame.generation == generation, "callback generation mismatch")
    try require(frame.width == width && frame.height == height, "callback dimensions mismatch")
    try require(frame.pixelFormat == pixelFormatBGRA, "callback pixel format mismatch")
    try require(
        frame.backend == backendDirectIOSurface || frame.backend == backendAsyncMetalBlit,
        "callback returned unknown backend \(frame.backend)"
    )
    try require(frame.pts.isFinite, "callback returned non-finite PTS")
    try require(frame.duration.isFinite, "callback returned non-finite duration")
}

private func runHarness() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw RuntimeHarnessError.failed("no Metal device is available on this Apple Silicon Mac")
    }
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.drawableSize = CGSize(width: 320, height: 180)
    layer.maximumDrawableCount = 3
    layer.allowsNextDrawableTimeout = true
    layer.frame = CGRect(x: 0, y: 0, width: 320, height: 180)

    // MoltenVK needs a layer that can produce real inline drawables for warmup/restoration. A
    // borderless, non-activating AppKit window provides that in local runs and macOS CI sessions.
    let hostView = NSView(frame: layer.frame)
    hostView.wantsLayer = true
    hostView.layer = layer
    let window = NSWindow(
        contentRect: layer.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostView
    window.orderFrontRegardless()
    defer {
        window.orderOut(nil)
        window.close()
    }
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

    guard let handle = mpv_create() else {
        throw RuntimeHarnessError.failed("mpv_create returned nil")
    }
    defer { mpv_terminate_destroy(handle) }

    try checkMPV(mpv_set_option_string(handle, "terminal", "no"), "set terminal")
    try checkMPV(mpv_set_option_string(handle, "audio", "no"), "disable audio")
    try checkMPV(mpv_set_option_string(handle, "hwdec", "no"), "disable hardware decode")
    try checkMPV(mpv_set_option_string(handle, "vo", "gpu-next"), "select gpu-next")
    try checkMPV(mpv_set_option_string(handle, "gpu-api", "vulkan"), "select Vulkan")
    try checkMPV(mpv_set_option_string(handle, "gpu-context", "moltenvk"), "select MoltenVK")
    try checkMPV(mpv_set_option_string(handle, "loop-file", "inf"), "loop fixture")
    try checkMPV(mpv_set_option_string(handle, "keep-open", "yes"), "keep fixture open")
    try checkMPV(mpv_set_option_string(handle, "idle", "yes"), "keep mpv alive")
    try checkMPV(mpv_set_option_string(handle, "pause", "no"), "start unpaused")
    try checkMPV(mpv_request_log_messages(handle, "warn"), "request warning logs")
    var windowID = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())))
    try checkMPV(
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &windowID),
        "install CAMetalLayer"
    )
    try checkMPV(mpv_initialize(handle), "mpv_initialize")

    let videoURL = try makeTestVideo()
    defer { try? FileManager.default.removeItem(at: videoURL.deletingLastPathComponent()) }
    try checkMPV(
        mpv_command_string(handle, "loadfile \(videoURL.path) replace"),
        "load deterministic Y4M fixture"
    )

    var capabilities = mpv_apple_pip_capabilities()
    capabilities.struct_size = UInt32(MemoryLayout<mpv_apple_pip_capabilities>.size)
    var capabilityStatus = resultUnavailable
    try waitUntil(handle, timeout: 12, description: "gpu-next/MoltenVK capability probe") {
        capabilities = mpv_apple_pip_capabilities()
        capabilities.struct_size = UInt32(MemoryLayout<mpv_apple_pip_capabilities>.size)
        capabilityStatus = mpv_apple_pip_get_capabilities(handle, &capabilities)
        return capabilityStatus != resultUnavailable
    }
    try require(capabilityStatus == resultOK, "capability probe failed with status \(capabilityStatus)")
    try require(mpv_apple_pip_api_version() == apiVersion, "Apple PiP API version mismatch")
    try require(capabilities.api_version == apiVersion, "capability API version mismatch")
    let requiredCapabilities = capabilitySDRBGRA8
        | capabilityOffscreenWithoutDrawable
        | capabilityAsyncCompletion
        | capabilityInlineRestore
    try require(
        capabilities.flags & requiredCapabilities == requiredCapabilities,
        "missing required capabilities: flags=0x\(String(capabilities.flags, radix: 16))"
    )
    try require(
        capabilities.flags & (capabilityDirectIOSurface | capabilityAsyncMetalBlit) != 0,
        "neither direct IOSurface nor asynchronous Metal-blit backend is available"
    )
    try require(capabilities.pixel_format == pixelFormatBGRA, "capability pixel format mismatch")
    try require(capabilities.max_queued_targets >= 3, "native sink does not expose three target slots")
    trace("capability probe ready: \(capabilityDiagnostic(&capabilities))")

    let recorder = CallbackRecorder()
    let callbackContext = Unmanaged.passRetained(recorder)
    defer { callbackContext.release() }
    try require(
        mpv_apple_pip_set_callback(handle, nativeFrameCallback, callbackContext.toOpaque()) == resultOK,
        "installing the native callback failed"
    )
    trace("callback installed")

    let generation: UInt64 = 0x4d50_564b_4954
    try require(
        mpv_apple_pip_set_mode(handle, modeInlineOnly, generation) == resultOK,
        "inline-only mode failed"
    )
    try waitUntil(handle, timeout: 4, description: "initial inline presentation callback") {
        recorder.count(token: 0, generation: generation) >= 1
    }
    trace("inline-only presentation completed")

    let width: UInt32 = 320
    let height: UInt32 = 180
    let surfaces = try (0..<4).map { _ in
        try makeSurface(width: Int(width), height: Int(height))
    }
    trace("allocated four IOSurface targets")

    try require(
        mpv_apple_pip_set_mode(handle, modeDualOutputWarmup, generation) == resultOK,
        "dual-output warmup mode failed"
    )
    trace("dual-output warmup selected")
    var warmupTarget = makeTarget(
        surface: surfaces[0], width: width, height: height, token: 101, generation: generation
    )
    try require(
        mpv_apple_pip_submit_target(handle, &warmupTarget) == resultOK,
        "warmup target submission failed"
    )
    trace("warmup IOSurface submitted")
    try waitUntil(handle, timeout: 5, description: "warmup GPU completion") {
        recorder.first(token: 101, generation: generation) != nil
    }
    let warmupFrame = recorder.first(token: 101, generation: generation)!
    try validateSurfaceFrame(
        warmupFrame,
        token: 101,
        generation: generation,
        width: width,
        height: height
    )
    trace("warmup GPU completion validated")

    var staleTarget = makeTarget(
        surface: surfaces[1], width: width, height: height, token: 102, generation: generation - 1
    )
    try require(
        mpv_apple_pip_submit_target(handle, &staleTarget) == resultStaleGeneration,
        "stale generation target was not rejected"
    )

    try require(
        mpv_apple_pip_set_mode(handle, modeOffscreenOnly, generation) == resultOK,
        "offscreen-only mode failed"
    )
    trace("offscreen-only selected")
    // A detached/background layer has no useful drawable size. The sink must still complete its
    // IOSurface frame because OFFSCREEN_ONLY bypasses CAMetalLayer acquisition entirely.
    layer.drawableSize = .zero
    // CAMetalLayer may clamp zero to a one-pixel extent, so remove its device as the decisive
    // no-drawable condition. The same Metal device is restored before dual-output restoration.
    layer.device = nil
    try require(layer.device == nil, "CAMetalLayer refused the drawable-unavailable probe")
    var offscreenTarget = makeTarget(
        surface: surfaces[1], width: width, height: height, token: 103, generation: generation
    )
    try require(
        mpv_apple_pip_submit_target(handle, &offscreenTarget) == resultOK,
        "offscreen target submission failed"
    )
    trace("drawable-independent IOSurface submitted")
    try waitUntil(handle, timeout: 5, description: "drawable-independent offscreen GPU completion") {
        recorder.first(token: 103, generation: generation) != nil
    }
    try validateSurfaceFrame(
        recorder.first(token: 103, generation: generation)!,
        token: 103,
        generation: generation,
        width: width,
        height: height
    )
    try require(
        layer.device == nil,
        "offscreen completion unexpectedly depended on restoring the CAMetalLayer device"
    )
    trace("drawable-independent GPU completion validated")

    layer.device = device
    layer.drawableSize = CGSize(width: 320, height: 180)
    let inlineCallbacksBeforeRestore = recorder.count(token: 0, generation: generation)
    try require(
        mpv_apple_pip_set_mode(handle, modeDualOutputRestore, generation) == resultOK,
        "dual-output restore mode failed"
    )
    trace("dual-output restore selected")
    var restoreTarget = makeTarget(
        surface: surfaces[2], width: width, height: height, token: 104, generation: generation
    )
    try require(
        mpv_apple_pip_submit_target(handle, &restoreTarget) == resultOK,
        "restore target submission failed"
    )
    try waitUntil(handle, timeout: 5, description: "restore surface completion") {
        recorder.first(token: 104, generation: generation) != nil
    }
    try validateSurfaceFrame(
        recorder.first(token: 104, generation: generation)!,
        token: 104,
        generation: generation,
        width: width,
        height: height
    )
    try waitUntil(handle, timeout: 5, description: "restored inline presentation") {
        recorder.count(token: 0, generation: generation) > inlineCallbacksBeforeRestore
    }
    trace("inline restoration validated")

    try require(
        mpv_apple_pip_set_mode(handle, modeOffscreenOnly, generation) == resultOK,
        "final offscreen mode failed"
    )
    trace("final offscreen mode selected for drain race")
    var drainingTarget = makeTarget(
        surface: surfaces[3], width: width, height: height, token: 105, generation: generation
    )
    try withExtendedLifetime(surfaces) {
        // `mpv_apple_pip_target` stores an unretained IOSurface pointer by ABI contract. Keep the
        // Swift owners alive explicitly: in an optimized build the array's final ordinary use is
        // otherwise the `surfaces[3]` subscript above, before the C function can retain its target.
        try require(
            drainingTarget.io_surface
                == Unmanaged.passUnretained(surfaces[3]).toOpaque(),
            "drain-race IOSurface pointer changed before submission"
        )
        try require(
            surfaces[3].width == Int(width) && surfaces[3].height == Int(height),
            "drain-race IOSurface became invalid before submission"
        )
        try require(
            mpv_apple_pip_submit_target(handle, &drainingTarget) == resultOK,
            "drain-race target submission failed"
        )
        trace("drain-race IOSurface submitted")
        trace("calling disable_and_drain")
        try require(
            mpv_apple_pip_disable_and_drain(handle) == resultOK,
            "disable_and_drain failed"
        )
    }
    trace("disable_and_drain returned")
    let callbackCountAfterDrain = recorder.count
    let drainDeadline = Date().addingTimeInterval(0.35)
    while Date() < drainDeadline { _ = pumpEvent(handle, timeout: 0.02) }
    try require(
        recorder.count == callbackCountAfterDrain,
        "a native callback arrived after disable_and_drain returned"
    )

    let diagnostic = capabilityDiagnostic(&capabilities)
    let backend = warmupFrame.backend == backendDirectIOSurface
        ? "direct IOSurface"
        : "asynchronous Metal blit"
    print(
        "PASS: native gpu-next PiP lifecycle completed; backend=\(backend); "
            + "callbacks=\(callbackCountAfterDrain); diagnostic=\(diagnostic)"
    )
}

@main
private struct NativeApplePiPRuntimeHarness {
    static func main() {
        do {
            try autoreleasepool { try runHarness() }
        } catch {
            FileHandle.standardError.write(Data("FAIL(runtime): \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
#else
@main
private struct NativeApplePiPRuntimeHarness {
    static func main() {
        print("SKIP(platform): native Apple GPU-PiP runtime validation requires arm64 macOS")
    }
}
#endif
