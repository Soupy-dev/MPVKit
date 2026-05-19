import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

public enum MPVMetalSampleBufferRendererState: Equatable {
    case idle
    case starting
    case loading
    case ready
    case playing
    case paused
    case stopped
    case failed(String)
}

public struct MPVMetalSampleBufferRendererOptions: Equatable {
    public var maximumFrameSize: CGSize
    public var preferredFramesPerSecond: Int
    public var preferredPiPFramesPerSecond: Int
    public var createsMetalCompatibilityProbe: Bool

    public init(
        maximumFrameSize: CGSize = CGSize(width: 1280, height: 720),
        preferredFramesPerSecond: Int = 30,
        preferredPiPFramesPerSecond: Int = 24,
        createsMetalCompatibilityProbe: Bool = true
    ) {
        self.maximumFrameSize = maximumFrameSize
        self.preferredFramesPerSecond = preferredFramesPerSecond
        self.preferredPiPFramesPerSecond = preferredPiPFramesPerSecond
        self.createsMetalCompatibilityProbe = createsMetalCompatibilityProbe
    }
}

public struct MPVMetalSampleBufferFrame {
    public let sampleBuffer: CMSampleBuffer
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public let dimensions: CMVideoDimensions
    public let frameIndex: Int
}

public struct MPVMetalSampleBufferRendererDiagnostics: Equatable {
    public let state: MPVMetalSampleBufferRendererState
    public let frameCount: Int
    public let renderAttemptCount: Int
    public let renderFailureCount: Int
    public let allocationFailureCount: Int
    public let enqueueFailureCount: Int
    public let lastRenderStatus: Int32
    public let lastFrameSize: CGSize
    public let lastPresentationTime: Double
    public let displayLayerStatus: String
    public let displayLayerReadyForMoreMediaData: Bool
    public let metalCompatibilityProbeSucceeded: Bool
    public let backendDescription: String
}

public struct MPVMetalSampleBufferTrack: Equatable {
    public let id: Int
    public let type: String
    public let title: String
    public let language: String
    public let codec: String
    public let selected: Bool
}

public struct MPVMetalSampleBufferSubtitleStyle {
    public var foregroundColor: CGColor
    public var strokeColor: CGColor
    public var strokeWidth: CGFloat
    public var fontSize: CGFloat
    public var isVisible: Bool

    public init(
        foregroundColor: CGColor,
        strokeColor: CGColor,
        strokeWidth: CGFloat,
        fontSize: CGFloat,
        isVisible: Bool
    ) {
        self.foregroundColor = foregroundColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.fontSize = fontSize
        self.isVisible = isVisible
    }
}

public enum MPVMetalSampleBufferRendererError: Error, LocalizedError, Equatable {
    case unsupportedPlatform
    case metalUnavailable
    case mpvCreationFailed
    case mpvInitializationFailed(Int32)
    case renderContextCreationFailed(Int32)
    case commandFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "MPVMetalSampleBufferRenderer is only available on iOS."
        case .metalUnavailable:
            return "Metal is unavailable on this device."
        case .mpvCreationFailed:
            return "mpv_create failed."
        case .mpvInitializationFailed(let status):
            return "mpv_initialize failed with status \(status)."
        case .renderContextCreationFailed(let status):
            return "mpv render context creation failed with status \(status)."
        case .commandFailed(let command, let status):
            return "mpv command \(command) failed with status \(status)."
        }
    }
}

#if os(iOS)
import Libmpv
import Metal
import QuartzCore
import UIKit

public final class MPVMetalSampleBufferRenderer {
    public static var isSupported: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    public let displayLayer: AVSampleBufferDisplayLayer
    public var currentTime: Double { cachedPosition }
    public var duration: Double { cachedDuration }
    public var onFrame: ((MPVMetalSampleBufferFrame) -> Void)?
    public var onStateChange: ((MPVMetalSampleBufferRendererState) -> Void)?
    public var onError: ((String) -> Void)?
    public var onDiagnostics: ((MPVMetalSampleBufferRendererDiagnostics) -> Void)?

    private var options: MPVMetalSampleBufferRendererOptions
    private let eventQueue = DispatchQueue(label: "mpvkit.sample-buffer.events", qos: .utility)
    private var mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var displayLink: CADisplayLink?
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferPoolAuxAttributes: CFDictionary?
    private var formatDescription: CMVideoFormatDescription?
    private var poolWidth = 0
    private var poolHeight = 0
    private var videoSize: CGSize = .zero
    private var cachedPosition: Double = 0
    private var cachedDuration: Double = 0
    private var isPaused = true
    private var isRunning = false
    private var isRenderScheduled = false
    private var forcedFrameCount = 0
    private var frameCount = 0
    private var renderAttemptCount = 0
    private var renderFailureCount = 0
    private var allocationFailureCount = 0
    private var enqueueFailureCount = 0
    private var lastRenderStatus: Int32 = 0
    private var lastFrameSize: CGSize = .zero
    private var lastPresentationTime: Double = 0
    private var state: MPVMetalSampleBufferRendererState = .idle
    private var metalDevice: MTLDevice?
    private var metalTextureCache: CVMetalTextureCache?
    private var metalCompatibilityProbeSucceeded = false
    private var swFormat = Array("bgr0".utf8CString)

    public init(
        displayLayer: AVSampleBufferDisplayLayer,
        options: MPVMetalSampleBufferRendererOptions = MPVMetalSampleBufferRendererOptions()
    ) {
        self.displayLayer = displayLayer
        self.options = options
        self.metalDevice = MTLCreateSystemDefaultDevice()
        configureDisplayLayer()
        if let metalDevice {
            var cache: CVMetalTextureCache?
            if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &cache) == kCVReturnSuccess {
                metalTextureCache = cache
            }
        }
    }

    deinit {
        stop()
    }

    public func start() throws {
        if !Thread.isMainThread {
            var result: Result<Void, Error>!
            DispatchQueue.main.sync {
                result = Result { try self.start() }
            }
            try result.get()
            return
        }

        guard !isRunning else { return }
        guard metalDevice != nil else {
            throw MPVMetalSampleBufferRendererError.metalUnavailable
        }
        updateState(.starting)

        guard let handle = mpv_create() else {
            updateState(.failed("mpv_create failed"))
            throw MPVMetalSampleBufferRendererError.mpvCreationFailed
        }
        mpv = handle

        setOption("terminal", "no")
        setOption("msg-level", "all=warn,cplayer=v,ffmpeg=v")
        setOption("idle", "yes")
        setOption("keep-open", "yes")
        setOption("vo", "libmpv")
        setOption("profile", "fast")
        setOption("hwdec", "videotoolbox-copy")
        setOption("vd-lavc-dr", "no")
        setOption("video-sync", "audio")
        setOption("framedrop", "vo")
        setOption("sub-auto", "fuzzy")
        setOption("subs-fallback", "yes")
        setOption("sub-ass-override", "yes")
        setOption("sub-use-margins", "yes")

        let initStatus = mpv_initialize(handle)
        guard initStatus >= 0 else {
            mpv_destroy(handle)
            mpv = nil
            let message = "mpv_initialize failed status=\(initStatus)"
            updateState(.failed(message))
            throw MPVMetalSampleBufferRendererError.mpvInitializationFailed(initStatus)
        }

        let renderStatus = createRenderContext(handle: handle)
        guard renderStatus >= 0, renderContext != nil else {
            mpv_terminate_destroy(handle)
            mpv = nil
            let message = "sample-buffer render context failed status=\(renderStatus)"
            updateState(.failed(message))
            throw MPVMetalSampleBufferRendererError.renderContextCreationFailed(renderStatus)
        }

        observeProperties(handle: handle)
        installWakeupHandler(handle: handle)
        startDisplayLink()
        isRunning = true
        updateState(.ready)
    }

    public func stop() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync {
                self.stop()
            }
            return
        }

        stopDisplayLink()
        if let context = renderContext {
            mpv_render_context_set_update_callback(context, nil, nil)
            mpv_render_context_free(context)
            renderContext = nil
        }
        if let handle = mpv {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
            mpv = nil
        }
        resetDisplayLayer(removingDisplayedImage: true)
        pixelBufferPool = nil
        formatDescription = nil
        isRunning = false
        isRenderScheduled = false
        forcedFrameCount = 0
        updateState(.stopped)
    }

    public func load(_ url: URL, headers: [String: String]? = nil) {
        performOnMain {
            guard self.mpv != nil else { return }
            self.updateState(.loading)
            self.updateHTTPHeaders(headers)
            let target = url.isFileURL ? url.path : url.absoluteString
            let status = self.command(["loadfile", target, "replace"])
            if status < 0 {
                self.reportError("loadfile failed status=\(status)")
            } else {
                self.forceRenderBurst(count: 8)
            }
        }
    }

    public func play() {
        setFlagProperty("pause", false)
        updateState(.playing)
        forceRenderBurst(count: 3)
    }

    public func pause() {
        setFlagProperty("pause", true)
        updateState(.paused)
        forceRenderBurst(count: 1)
    }

    public func seek(to seconds: Double) {
        let clamped = max(0, seconds)
        _ = command(["seek", "\(clamped)", "absolute+exact"])
        cachedPosition = clamped
        forceRenderBurst(count: 6)
    }

    public func seek(by seconds: Double) {
        seek(to: cachedPosition + seconds)
    }

    public func primeFrames(reason: String = "manual", count: Int = 6) {
        _ = reason
        performOnMain {
            self.forceRenderBurst(count: count)
        }
    }

    public func updateOptions(_ newOptions: MPVMetalSampleBufferRendererOptions) {
        performOnMain {
            guard self.options != newOptions else { return }
            let previousMaximumFrameSize = self.options.maximumFrameSize
            let previousPreferredFramesPerSecond = self.options.preferredFramesPerSecond
            let previousPreferredPiPFramesPerSecond = self.options.preferredPiPFramesPerSecond
            self.options = newOptions

            if previousPreferredFramesPerSecond != newOptions.preferredFramesPerSecond
                || previousPreferredPiPFramesPerSecond != newOptions.preferredPiPFramesPerSecond {
                self.applyDisplayLinkFrameRate()
            }

            if previousMaximumFrameSize != newOptions.maximumFrameSize {
                self.pixelBufferPool = nil
                self.pixelBufferPoolAuxAttributes = nil
                self.formatDescription = nil
                self.poolWidth = 0
                self.poolHeight = 0
            }

            self.forceRenderBurst(count: 6)
            self.onDiagnostics?(self.diagnosticsSnapshot())
        }
    }

    public func setSpeed(_ speed: Double) {
        setStringProperty("speed", "\(max(0.1, speed))")
    }

    public func getSpeed() -> Double {
        getDoubleProperty("speed") ?? 1.0
    }

    public func audioTracks() -> [MPVMetalSampleBufferTrack] {
        fetchTrackList().filter { $0.type == "audio" }
    }

    public func subtitleTracks() -> [MPVMetalSampleBufferTrack] {
        fetchTrackList().filter { $0.type == "sub" }
    }

    public func currentAudioTrackID() -> Int {
        fetchTrackList().first { $0.type == "audio" && $0.selected }?.id ?? -1
    }

    public func currentSubtitleTrackID() -> Int {
        fetchTrackList().first { $0.type == "sub" && $0.selected }?.id ?? -1
    }

    public func setAudioTrack(id: Int) {
        setStringProperty("aid", id < 0 ? "no" : "\(id)")
    }

    public func setSubtitleTrack(id: Int) {
        setStringProperty("sid", id < 0 ? "no" : "\(id)")
        forceRenderBurst(count: 3)
    }

    public func disableSubtitles() {
        setStringProperty("sid", "no")
        forceRenderBurst(count: 2)
    }

    public func loadExternalSubtitles(urls: [String], names: [String]? = nil, selectFirst: Bool = true) {
        for (index, url) in urls.enumerated() {
            var args = ["sub-add", url, index == 0 && selectFirst ? "select" : "auto"]
            if let names, names.indices.contains(index) {
                args.append(names[index])
            }
            _ = command(args)
        }
        forceRenderBurst(count: 6)
    }

    public func applySubtitleStyle(_ style: MPVMetalSampleBufferSubtitleStyle) {
        setStringProperty("sub-visibility", style.isVisible ? "yes" : "no")
        setStringProperty("sub-font-size", "\(max(1, Int(style.fontSize)))")
        setStringProperty("sub-border-size", "\(max(0, style.strokeWidth))")
        setStringProperty("sub-color", mpvColorString(style.foregroundColor))
        setStringProperty("sub-border-color", mpvColorString(style.strokeColor))
        forceRenderBurst(count: 3)
    }

    @discardableResult
    public func command(_ args: [String]) -> Int32 {
        guard let handle = mpv, !args.isEmpty else { return -1 }
        var cargs = args.map { UnsafePointer<CChar>(strdup($0)) }
        cargs.append(nil)
        defer {
            for pointer in cargs where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }
        return mpv_command(handle, &cargs)
    }

    public func diagnosticsSnapshot() -> MPVMetalSampleBufferRendererDiagnostics {
        let statusName: String
        switch displayLayer.status {
        case .unknown: statusName = "unknown"
        case .rendering: statusName = "rendering"
        case .failed: statusName = "failed"
        @unknown default: statusName = "unknown"
        }
        return MPVMetalSampleBufferRendererDiagnostics(
            state: state,
            frameCount: frameCount,
            renderAttemptCount: renderAttemptCount,
            renderFailureCount: renderFailureCount,
            allocationFailureCount: allocationFailureCount,
            enqueueFailureCount: enqueueFailureCount,
            lastRenderStatus: lastRenderStatus,
            lastFrameSize: lastFrameSize,
            lastPresentationTime: lastPresentationTime,
            displayLayerStatus: statusName,
            displayLayerReadyForMoreMediaData: displayLayer.isReadyForMoreMediaData,
            metalCompatibilityProbeSucceeded: metalCompatibilityProbeSucceeded,
            backendDescription: "libmpv software renderer into Metal-compatible IOSurface sample buffers"
        )
    }

    private func configureDisplayLayer() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        if #available(iOS 17.0, *) {
            displayLayer.wantsExtendedDynamicRangeContent = true
        }
    }

    private func createRenderContext(handle: OpaquePointer) -> Int32 {
        let apiString = MPV_RENDER_API_TYPE_SW as NSString
        let api = UnsafeMutableRawPointer(mutating: apiString.utf8String)
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
            mpv_render_param()
        ]
        let status = params.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return mpv_render_context_create(&renderContext, handle, baseAddress)
        }
        if status >= 0, let context = renderContext {
            mpv_render_context_set_update_callback(context, { userdata in
                guard let userdata else { return }
                let renderer = Unmanaged<MPVMetalSampleBufferRenderer>.fromOpaque(userdata).takeUnretainedValue()
                renderer.scheduleRender(force: false)
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        return status
    }

    private func observeProperties(handle: OpaquePointer) {
        let properties: [(String, mpv_format)] = [
            ("dwidth", MPV_FORMAT_INT64),
            ("dheight", MPV_FORMAT_INT64),
            ("duration", MPV_FORMAT_DOUBLE),
            ("time-pos", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG),
            ("track-list", MPV_FORMAT_NONE),
            ("sid", MPV_FORMAT_NONE),
            ("aid", MPV_FORMAT_NONE)
        ]
        for (name, format) in properties {
            _ = name.withCString { mpv_observe_property(handle, 0, $0, format) }
        }
    }

    private func installWakeupHandler(handle: OpaquePointer) {
        mpv_set_wakeup_callback(handle, { userdata in
            guard let userdata else { return }
            let renderer = Unmanaged<MPVMetalSampleBufferRenderer>.fromOpaque(userdata).takeUnretainedValue()
            renderer.eventQueue.async { [weak renderer] in
                renderer?.readEvents()
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func readEvents() {
        guard let handle = mpv else { return }
        while true {
            guard let eventPointer = mpv_wait_event(handle, 0) else { break }
            let event = eventPointer.pointee
            if event.event_id == MPV_EVENT_NONE {
                break
            }

            switch event.event_id {
            case MPV_EVENT_START_FILE:
                performOnMain { self.updateState(.loading) }
            case MPV_EVENT_FILE_LOADED:
                performOnMain {
                    self.updateState(self.isPaused ? .paused : .playing)
                    self.forceRenderBurst(count: 8)
                }
            case MPV_EVENT_VIDEO_RECONFIG:
                performOnMain {
                    self.refreshVideoSize()
                    self.forceRenderBurst(count: 4)
                }
            case MPV_EVENT_PROPERTY_CHANGE:
                if let data = event.data {
                    let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                    guard let namePointer = property.name else { break }
                    let name = String(cString: namePointer)
                    performOnMain { self.refreshProperty(named: name) }
                }
            case MPV_EVENT_LOG_MESSAGE:
                if let logPointer = event.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
                    let text = logPointer.pointee.text.map { String(cString: $0) } ?? ""
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.localizedCaseInsensitiveContains("error") {
                        performOnMain { self.onError?(trimmed) }
                    }
                }
            case MPV_EVENT_SHUTDOWN:
                performOnMain { self.updateState(.stopped) }
            default:
                break
            }
        }
    }

    private func refreshProperty(named name: String) {
        switch name {
        case "dwidth", "dheight":
            refreshVideoSize()
        case "duration":
            cachedDuration = getDoubleProperty("duration") ?? 0
        case "time-pos":
            cachedPosition = getDoubleProperty("time-pos") ?? cachedPosition
        case "pause":
            isPaused = getFlagProperty("pause")
            updateState(isPaused ? .paused : .playing)
        case "paused-for-cache":
            if getFlagProperty("paused-for-cache") {
                updateState(.loading)
            } else {
                updateState(isPaused ? .paused : .playing)
            }
        case "track-list", "sid", "aid":
            forceRenderBurst(count: 2)
        default:
            break
        }
    }

    private func refreshVideoSize() {
        let width = getIntProperty("dwidth") ?? 0
        let height = getIntProperty("dheight") ?? 0
        if width > 0, height > 0 {
            videoSize = CGSize(width: width, height: height)
        }
    }

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        displayLink = link
        applyDisplayLinkFrameRate()
        link.add(to: .main, forMode: .common)
    }

    private func applyDisplayLinkFrameRate() {
        guard let link = displayLink else { return }
        let fps = max(1, options.preferredFramesPerSecond)
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(min(options.preferredPiPFramesPerSecond, fps)),
                maximum: Float(fps),
                preferred: Float(fps)
            )
        } else {
            link.preferredFramesPerSecond = fps
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        guard isRunning else { return }
        if !isPaused || forcedFrameCount > 0 {
            renderFrame(force: forcedFrameCount > 0)
        }
    }

    private func scheduleRender(force: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            if force {
                self.forcedFrameCount = max(self.forcedFrameCount, 1)
            }
            guard !self.isRenderScheduled else { return }
            self.isRenderScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRenderScheduled = false
                self.renderFrame(force: force)
            }
        }
    }

    private func forceRenderBurst(count: Int) {
        guard count > 0 else { return }
        forcedFrameCount = max(forcedFrameCount, count)
        for index in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + (0.04 * Double(index))) { [weak self] in
                self?.scheduleRender(force: true)
            }
        }
    }

    private func renderFrame(force: Bool) {
        guard let context = renderContext else { return }
        if forcedFrameCount > 0 {
            forcedFrameCount -= 1
        }

        let updateFlags = UInt32(mpv_render_context_update(context))
        let hasFrame = updateFlags & MPV_RENDER_UPDATE_FRAME.rawValue != 0
        guard hasFrame || force else { return }

        guard let targetSize = currentTargetSize() else { return }
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        guard width > 0, height > 0 else { return }

        renderAttemptCount += 1
        lastFrameSize = targetSize
        if poolWidth != width || poolHeight != height {
            recreatePixelBufferPool(width: width, height: height)
        }

        guard let buffer = makePixelBuffer(width: width, height: height) else {
            allocationFailureCount += 1
            return
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            allocationFailureCount += 1
            return
        }

        var size = [Int32(width), Int32(height)]
        var stride = CVPixelBufferGetBytesPerRow(buffer)
        let result = size.withUnsafeMutableBufferPointer { sizePointer in
            swFormat.withUnsafeMutableBufferPointer { formatPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePointer.baseAddress)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(formatPointer.baseAddress)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(&stride)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: baseAddress),
                    mpv_render_param()
                ]
                return params.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    guard let baseAddress = buffer.baseAddress else { return -1 }
                    return mpv_render_context_render(context, baseAddress)
                }
            }
        }
        lastRenderStatus = result
        guard result >= 0 else {
            renderFailureCount += 1
            reportError("sample-buffer render failed status=\(result)")
            return
        }

        probeMetalCompatibility(buffer: buffer, width: width, height: height)
        enqueue(buffer: buffer)
    }

    private func currentTargetSize() -> CGSize? {
        let source = videoSize.width > 0 && videoSize.height > 0
            ? videoSize
            : CGSize(
                width: max(1, displayLayer.bounds.width * UIScreen.main.scale),
                height: max(1, displayLayer.bounds.height * UIScreen.main.scale)
            )
        guard source.width > 0, source.height > 0 else { return nil }
        let maxSize = options.maximumFrameSize
        let scale = min(maxSize.width / source.width, maxSize.height / source.height, 1.0)
        return CGSize(width: max(1, floor(source.width * scale)), height: max(1, floor(source.height * scale)))
    }

    private func recreatePixelBufferPool(width: Int, height: Int) {
        pixelBufferPool = nil
        formatDescription = nil
        poolWidth = width
        poolHeight = height
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
        ]
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 4
        ]
        let auxAttrs: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: 4
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        if status == kCVReturnSuccess {
            pixelBufferPool = pool
            pixelBufferPoolAuxAttributes = auxAttrs as CFDictionary
        } else {
            reportError("pixel buffer pool creation failed status=\(status)")
        }
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool = pixelBufferPool {
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                pool,
                pixelBufferPoolAuxAttributes,
                &buffer
            )
            if status == kCVReturnSuccess, buffer != nil {
                return buffer
            }
        }

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        if status != kCVReturnSuccess {
            reportError("pixel buffer allocation failed status=\(status)")
        }
        return buffer
    }

    private func probeMetalCompatibility(buffer: CVPixelBuffer, width: Int, height: Int) {
        guard options.createsMetalCompatibilityProbe,
              let cache = metalTextureCache else { return }
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            buffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &texture
        )
        metalCompatibilityProbeSucceeded = status == kCVReturnSuccess && texture != nil
        if status == kCVReturnSuccess {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    private func enqueue(buffer: CVPixelBuffer) {
        if displayLayer.status == .failed {
            resetDisplayLayer(removingDisplayedImage: true)
        }

        let needsFlush = updateFormatDescriptionIfNeeded(for: buffer)
        guard let description = formatDescription else { return }
        let mediaSeconds = cachedPosition.isFinite ? max(0, cachedPosition) : 0
        lastPresentationTime = mediaSeconds
        let presentationTime = CMTime(seconds: mediaSeconds, preferredTimescale: 1000)
        let frameDuration = CMTime(seconds: 1.0 / Double(max(1, options.preferredPiPFramesPerSecond)), preferredTimescale: 1000)
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let result = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard result == noErr, let sampleBuffer else {
            enqueueFailureCount += 1
            reportError("sample buffer creation failed status=\(result)")
            return
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        if needsFlush {
            resetDisplayLayer(removingDisplayedImage: true)
        }
        ensureTimebase(at: presentationTime)
        displayLayer.enqueue(sampleBuffer)
        frameCount += 1
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let frame = MPVMetalSampleBufferFrame(
            sampleBuffer: sampleBuffer,
            pixelBuffer: buffer,
            presentationTime: presentationTime,
            dimensions: dimensions,
            frameIndex: frameCount
        )
        onFrame?(frame)
        onDiagnostics?(diagnosticsSnapshot())
    }

    private func updateFormatDescriptionIfNeeded(for buffer: CVPixelBuffer) -> Bool {
        let width = Int32(CVPixelBufferGetWidth(buffer))
        let height = Int32(CVPixelBufferGetHeight(buffer))
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        if let description = formatDescription {
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            if dimensions.width == width,
               dimensions.height == height,
               CMFormatDescriptionGetMediaSubType(description) == pixelFormat {
                return false
            }
        }

        var newDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &newDescription
        )
        if status == noErr, let newDescription {
            formatDescription = newDescription
            return true
        }
        reportError("format description creation failed status=\(status)")
        return false
    }

    private func ensureTimebase(at presentationTime: CMTime) {
        if displayLayer.controlTimebase == nil {
            var timebase: CMTimebase?
            if CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(),
                timebaseOut: &timebase
            ) == noErr, let timebase {
                CMTimebaseSetTime(timebase, time: presentationTime)
                CMTimebaseSetRate(timebase, rate: isPaused ? 0 : 1)
                displayLayer.controlTimebase = timebase
            }
        } else if let timebase = displayLayer.controlTimebase {
            CMTimebaseSetTime(timebase, time: presentationTime)
            CMTimebaseSetRate(timebase, rate: isPaused ? 0 : 1)
        }
    }

    private func resetDisplayLayer(removingDisplayedImage: Bool) {
        displayLayer.controlTimebase = nil
        if removingDisplayedImage {
            displayLayer.flushAndRemoveImage()
        } else {
            displayLayer.flush()
        }
    }

    private func updateHTTPHeaders(_ headers: [String: String]?) {
        guard let headers, !headers.isEmpty else {
            setOption("http-header-fields", "")
            return
        }
        let headerValue = headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
        setOption("http-header-fields", headerValue)
    }

    private func updateState(_ newState: MPVMetalSampleBufferRendererState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    private func reportError(_ message: String) {
        onError?(message)
        onDiagnostics?(diagnosticsSnapshot())
    }

    private func setOption(_ name: String, _ value: String) {
        guard let handle = mpv else { return }
        _ = name.withCString { namePointer in
            value.withCString { valuePointer in
                mpv_set_option_string(handle, namePointer, valuePointer)
            }
        }
    }

    private func setStringProperty(_ name: String, _ value: String) {
        guard let handle = mpv else { return }
        _ = name.withCString { namePointer in
            value.withCString { valuePointer in
                mpv_set_property_string(handle, namePointer, valuePointer)
            }
        }
    }

    private func setFlagProperty(_ name: String, _ value: Bool) {
        guard let handle = mpv else { return }
        var data: Int = value ? 1 : 0
        _ = name.withCString { mpv_set_property(handle, $0, MPV_FORMAT_FLAG, &data) }
    }

    private func getFlagProperty(_ name: String) -> Bool {
        guard let handle = mpv else { return false }
        var data: Int64 = 0
        _ = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_FLAG, &data) }
        return data != 0
    }

    private func getDoubleProperty(_ name: String) -> Double? {
        guard let handle = mpv else { return nil }
        var data = Double()
        let status = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_DOUBLE, &data) }
        return status >= 0 ? data : nil
    }

    private func getIntProperty(_ name: String) -> Int? {
        guard let handle = mpv else { return nil }
        var data: Int64 = 0
        let status = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_INT64, &data) }
        return status >= 0 ? Int(data) : nil
    }

    private func fetchTrackList() -> [MPVMetalSampleBufferTrack] {
        guard let handle = mpv else { return [] }
        var node = mpv_node()
        let status = "track-list".withCString { pointer in
            mpv_get_property(handle, pointer, MPV_FORMAT_NODE, &node)
        }
        guard status >= 0 else { return [] }
        defer { mpv_free_node_contents(&node) }
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list else { return [] }

        var tracks: [MPVMetalSampleBufferTrack] = []
        for index in 0..<Int(list.pointee.num) {
            let item = list.pointee.values[index]
            guard item.format == MPV_FORMAT_NODE_MAP, let map = item.u.list else { continue }
            var id = -1
            var type = ""
            var title = ""
            var lang = ""
            var codec = ""
            var selected = false
            for entryIndex in 0..<Int(map.pointee.num) {
                guard let keyPointer = map.pointee.keys[entryIndex] else { continue }
                let key = String(cString: keyPointer)
                let value = map.pointee.values[entryIndex]
                switch key {
                case "id":
                    if value.format == MPV_FORMAT_INT64 { id = Int(value.u.int64) }
                case "type":
                    if value.format == MPV_FORMAT_STRING, let string = value.u.string { type = String(cString: string) }
                case "title":
                    if value.format == MPV_FORMAT_STRING, let string = value.u.string { title = String(cString: string) }
                case "lang":
                    if value.format == MPV_FORMAT_STRING, let string = value.u.string { lang = String(cString: string) }
                case "codec":
                    if value.format == MPV_FORMAT_STRING, let string = value.u.string { codec = String(cString: string) }
                case "selected":
                    if value.format == MPV_FORMAT_FLAG { selected = value.u.flag != 0 }
                default:
                    break
                }
            }
            guard id >= 0, !type.isEmpty else { continue }
            tracks.append(MPVMetalSampleBufferTrack(
                id: id,
                type: type,
                title: title.isEmpty ? "Track \(id)" : title,
                language: lang,
                codec: codec,
                selected: selected
            ))
        }
        return tracks
    }

    private func mpvColorString(_ color: CGColor) -> String {
        let converted = color.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!,
            intent: .defaultIntent,
            options: nil
        ) ?? color
        let components = converted.components ?? [1, 1, 1, 1]
        let red = components.indices.contains(0) ? components[0] : 1
        let green = components.indices.contains(1) ? components[1] : red
        let blue = components.indices.contains(2) ? components[2] : red
        let alpha = components.indices.contains(3) ? components[3] : 1
        return String(
            format: "#%02X%02X%02X%02X",
            Int(max(0, min(1, red)) * 255),
            Int(max(0, min(1, green)) * 255),
            Int(max(0, min(1, blue)) * 255),
            Int(max(0, min(1, alpha)) * 255)
        )
    }

    private func performOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

#else

public final class MPVMetalSampleBufferRenderer {
    public static let isSupported = false
    public let displayLayer: AVSampleBufferDisplayLayer
    public var currentTime: Double { 0 }
    public var duration: Double { 0 }
    public var onFrame: ((MPVMetalSampleBufferFrame) -> Void)?
    public var onStateChange: ((MPVMetalSampleBufferRendererState) -> Void)?
    public var onError: ((String) -> Void)?
    public var onDiagnostics: ((MPVMetalSampleBufferRendererDiagnostics) -> Void)?

    public init(
        displayLayer: AVSampleBufferDisplayLayer,
        options: MPVMetalSampleBufferRendererOptions = MPVMetalSampleBufferRendererOptions()
    ) {
        self.displayLayer = displayLayer
        _ = options
    }

    public func start() throws {
        throw MPVMetalSampleBufferRendererError.unsupportedPlatform
    }

    public func stop() {}
    public func load(_ url: URL, headers: [String: String]? = nil) { _ = url; _ = headers }
    public func play() {}
    public func pause() {}
    public func seek(to seconds: Double) { _ = seconds }
    public func seek(by seconds: Double) { _ = seconds }
    public func primeFrames(reason: String = "manual", count: Int = 6) { _ = reason; _ = count }
    public func updateOptions(_ newOptions: MPVMetalSampleBufferRendererOptions) { _ = newOptions }
    public func setSpeed(_ speed: Double) { _ = speed }
    public func getSpeed() -> Double { 1.0 }
    public func audioTracks() -> [MPVMetalSampleBufferTrack] { [] }
    public func subtitleTracks() -> [MPVMetalSampleBufferTrack] { [] }
    public func currentAudioTrackID() -> Int { -1 }
    public func currentSubtitleTrackID() -> Int { -1 }
    public func setAudioTrack(id: Int) { _ = id }
    public func setSubtitleTrack(id: Int) { _ = id }
    public func disableSubtitles() {}
    public func loadExternalSubtitles(urls: [String], names: [String]? = nil, selectFirst: Bool = true) {
        _ = urls
        _ = names
        _ = selectFirst
    }
    public func applySubtitleStyle(_ style: MPVMetalSampleBufferSubtitleStyle) { _ = style }
    @discardableResult public func command(_ args: [String]) -> Int32 { _ = args; return -1 }
    public func diagnosticsSnapshot() -> MPVMetalSampleBufferRendererDiagnostics {
        MPVMetalSampleBufferRendererDiagnostics(
            state: .failed("unsupported platform"),
            frameCount: 0,
            renderAttemptCount: 0,
            renderFailureCount: 0,
            allocationFailureCount: 0,
            enqueueFailureCount: 0,
            lastRenderStatus: -1,
            lastFrameSize: .zero,
            lastPresentationTime: 0,
            displayLayerStatus: "unsupported",
            displayLayerReadyForMoreMediaData: false,
            metalCompatibilityProbeSucceeded: false,
            backendDescription: "unsupported"
        )
    }
}

#endif
