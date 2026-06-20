import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore

public enum MPVGPUPlayerRendererState: Equatable {
    case idle
    case starting
    case loading
    case ready
    case playing
    case paused
    case pictureInPicture
    case stopped
    case failed(String)
}

public enum MPVGPUPlayerPresentationMode: String, Equatable {
    case inlineGPU
    case pictureInPictureSampleBuffer
}

public struct MPVGPUPlayerRendererOptions: Equatable {
    public var maximumPiPFrameSize: CGSize
    public var preferredPiPFramesPerSecond: Int
    public var inlineProfile: String
    public var hardwareDecoding: String
    public var enablesTargetColorspaceHint: Bool
    public var pausesInlineRendererDuringPictureInPicture: Bool
    public var additionalMPVOptions: [String: String]

    public init(
        maximumPiPFrameSize: CGSize = CGSize(width: 1280, height: 720),
        preferredPiPFramesPerSecond: Int = 24,
        inlineProfile: String = "fast",
        hardwareDecoding: String = "videotoolbox",
        enablesTargetColorspaceHint: Bool = false,
        pausesInlineRendererDuringPictureInPicture: Bool = true,
        additionalMPVOptions: [String: String] = [:]
    ) {
        self.maximumPiPFrameSize = maximumPiPFrameSize
        self.preferredPiPFramesPerSecond = preferredPiPFramesPerSecond
        self.inlineProfile = inlineProfile
        self.hardwareDecoding = hardwareDecoding
        self.enablesTargetColorspaceHint = enablesTargetColorspaceHint
        self.pausesInlineRendererDuringPictureInPicture = pausesInlineRendererDuringPictureInPicture
        self.additionalMPVOptions = additionalMPVOptions
    }
}

public struct MPVGPUPlayerRendererDiagnostics: Equatable {
    public let state: MPVGPUPlayerRendererState
    public let presentationMode: MPVGPUPlayerPresentationMode
    public let currentTime: Double
    public let duration: Double
    public let isPaused: Bool
    public let inlineVideoOutput: String
    public let inlineGPUAPI: String
    public let inlineGPUContext: String
    public let pictureInPictureDiagnostics: MPVMetalSampleBufferRendererDiagnostics?
    public let backendDescription: String
    /// Decoded video frame width/height in pixels (`video-params/w`/`h`); 0 when no video.
    public let videoWidth: Int
    public let videoHeight: Int
    /// Transfer characteristics / gamma (`video-params/gamma`, e.g. "pq", "hlg", "bt.1886").
    public let videoTransferFunction: String
    /// Color primaries (`video-params/primaries`, e.g. "bt.2020", "bt.709").
    public let videoColorPrimaries: String
    /// Reference signal peak (`video-params/sig-peak`); > 1.0 indicates HDR.
    public let videoSignalPeak: Double
    /// Decoded pixel format (`video-params/pixelformat`, e.g. "yuv420p10", "p010"). High-bit-depth
    /// content contains "10"/"12"/"16".
    public let videoPixelFormat: String
    /// Active hardware decoder (`hwdec-current`, e.g. "videotoolbox" or "no").
    public let hardwareDecoder: String
}

public final class MPVGPUPlayerMetalLayer: CAMetalLayer {
    public override init() {
        super.init()
    }

    public override init(layer: Any) {
        super.init(layer: layer)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    public override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync {
                    super.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }
}

#if os(iOS)
import Libmpv
import Metal
import UIKit

public final class MPVGPUPlayerRenderer {
    public static var isSupported: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    public let inlineLayer: CAMetalLayer
    public let pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer
    public var currentTime: Double {
        isPictureInPictureActive ? pictureInPictureRenderer.currentTime : cachedPosition
    }
    public var duration: Double {
        max(cachedDuration, pictureInPictureRenderer.duration)
    }
    public var onStateChange: ((MPVGPUPlayerRendererState) -> Void)?
    public var onError: ((String) -> Void)?
    public var onDiagnostics: ((MPVGPUPlayerRendererDiagnostics) -> Void)?
    /// Fired on the main thread when the decoded video parameters may have changed (file loaded or
    /// VIDEO_RECONFIG), so the host can re-evaluate HDR/colorspace configuration per content.
    public var onVideoReconfigure: (() -> Void)?

    private var options: MPVGPUPlayerRendererOptions
    /// The active mpv audio-filter chain (`af`), kept so it can be re-applied to the PiP renderer
    /// when it loads (the PiP renderer is a separate mpv instance from the inline one).
    private var audioFilterChain: String = ""
    private let pictureInPictureRenderer: MPVMetalSampleBufferRenderer
    private let eventQueue = DispatchQueue(label: "mpvkit.gpu-player.events", qos: .userInitiated)
    private let eventQueueGroup = DispatchGroup()
    private var mpv: OpaquePointer?
    private var currentURL: URL?
    private var currentHeaders: [String: String]?
    private var externalSubtitleURLs: [String] = []
    private var externalSubtitleNames: [String]?
    private var shouldSelectFirstExternalSubtitle = true
    private var selectedAudioTrackID: Int?
    private var selectedSubtitleTrackID: Int?
    private var subtitleStyle: MPVMetalSampleBufferSubtitleStyle?
    private var cachedPosition: Double = 0
    private var cachedDuration: Double = 0
    private var isPaused = true
    private var isRunning = false
    private var isStopping = false
    private var isPictureInPicturePrepared = false
    private var isPictureInPictureActive = false
    private var wasPausedBeforePictureInPicture = true
    private var state: MPVGPUPlayerRendererState = .idle

    public convenience init(options: MPVGPUPlayerRendererOptions = MPVGPUPlayerRendererOptions()) {
        self.init(
            inlineLayer: MPVGPUPlayerMetalLayer(),
            pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer(),
            options: options
        )
    }

    public init(
        inlineLayer: CAMetalLayer,
        pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer(),
        options: MPVGPUPlayerRendererOptions = MPVGPUPlayerRendererOptions()
    ) {
        self.inlineLayer = inlineLayer
        self.pictureInPictureDisplayLayer = pictureInPictureDisplayLayer
        self.options = options
        self.pictureInPictureRenderer = MPVMetalSampleBufferRenderer(
            displayLayer: pictureInPictureDisplayLayer,
            options: MPVMetalSampleBufferRendererOptions(
                maximumFrameSize: options.maximumPiPFrameSize,
                preferredFramesPerSecond: options.preferredPiPFramesPerSecond,
                preferredPiPFramesPerSecond: options.preferredPiPFramesPerSecond,
                prefersHDRPresentation: false,
                prefersHighBitDepthRendering: false
            )
        )
        configureInlineLayer()
        configurePictureInPictureCallbacks()
    }

    deinit {
        stop()
    }

    public func updateInlineLayerLayout(bounds: CGRect, contentsScale: CGFloat = UIScreen.main.nativeScale) {
        performOnMain {
            self.inlineLayer.frame = bounds
            self.inlineLayer.contentsScale = contentsScale
            self.inlineLayer.drawableSize = CGSize(
                width: max(2, bounds.width * contentsScale),
                height: max(2, bounds.height * contentsScale)
            )
        }
    }

    public func updateOptions(_ newOptions: MPVGPUPlayerRendererOptions) {
        performOnMain {
            guard self.options != newOptions else { return }
            let previousOptions = self.options
            self.options = newOptions
            self.pictureInPictureRenderer.updateOptions(
                MPVMetalSampleBufferRendererOptions(
                    maximumFrameSize: newOptions.maximumPiPFrameSize,
                    preferredFramesPerSecond: newOptions.preferredPiPFramesPerSecond,
                    preferredPiPFramesPerSecond: newOptions.preferredPiPFramesPerSecond,
                    prefersHDRPresentation: false,
                    prefersHighBitDepthRendering: false
                )
            )
            if previousOptions.enablesTargetColorspaceHint != newOptions.enablesTargetColorspaceHint {
                self.setStringProperty("target-colorspace-hint", newOptions.enablesTargetColorspaceHint ? "yes" : "no")
            }
            self.configureInlineLayer()
            self.emitDiagnostics()
        }
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
        guard Self.isSupported else {
            updateState(.failed("Metal is unavailable"))
            throw MPVMetalSampleBufferRendererError.metalUnavailable
        }

        isStopping = false
        updateState(.starting)

        guard let handle = mpv_create() else {
            updateState(.failed("mpv_create failed"))
            throw MPVMetalSampleBufferRendererError.mpvCreationFailed
        }
        mpv = handle

        setOption("terminal", "no", handle: handle)
        setOption("msg-level", "all=warn,cplayer=v,ffmpeg=v,vo=v,gpu=v")
        setOption("idle", "yes", handle: handle)
        setOption("keep-open", "yes", handle: handle)
        setOption("wid", value: layerWindowID(), handle: handle)
        setOption("vo", "gpu-next", handle: handle)
        setOption("gpu-api", "vulkan", handle: handle)
        setOption("gpu-context", "moltenvk", handle: handle)
        setOption("hwdec", options.hardwareDecoding, handle: handle)
        setOption("profile", options.inlineProfile, handle: handle)
        setOption("vd-lavc-dr", "yes", handle: handle)
        setOption("video-sync", "audio", handle: handle)
        setOption("framedrop", "vo", handle: handle)
        setOption("interpolation", "no", handle: handle)
        setOption("target-colorspace-hint", options.enablesTargetColorspaceHint ? "yes" : "no", handle: handle)
        setOption("subs-match-os-language", "yes", handle: handle)
        setOption("sub-auto", "fuzzy", handle: handle)
        setOption("subs-fallback", "yes", handle: handle)
        setOption("sub-ass-override", "yes", handle: handle)
        setOption("sub-use-margins", "yes", handle: handle)
        for (name, value) in options.additionalMPVOptions.sorted(by: { $0.key < $1.key }) {
            setOption(name, value, handle: handle)
        }

        let initStatus = mpv_initialize(handle)
        guard initStatus >= 0 else {
            mpv_destroy(handle)
            mpv = nil
            let message = "mpv_initialize failed status=\(initStatus)"
            updateState(.failed(message))
            throw MPVMetalSampleBufferRendererError.mpvInitializationFailed(initStatus)
        }

        observeProperties(handle: handle)
        installWakeupHandler(handle: handle)
        isRunning = true
        updateState(.ready)
        emitDiagnostics()
    }

    public func stop() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync {
                self.stop()
            }
            return
        }

        isStopping = true
        pictureInPictureRenderer.stop()
        isPictureInPicturePrepared = false
        isPictureInPictureActive = false
        if let handle = mpv {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_wakeup(handle)
        }
        eventQueueGroup.wait()
        if let handle = mpv {
            mpv_terminate_destroy(handle)
            mpv = nil
        }
        isRunning = false
        isStopping = false
        isPaused = true
        updateState(.stopped)
    }

    public func load(_ url: URL, headers: [String: String]? = nil) {
        performOnMain {
            self.currentURL = url
            self.currentHeaders = headers
            if self.isPictureInPicturePrepared || self.isPictureInPictureActive {
                self.pictureInPictureRenderer.pause()
                self.pictureInPictureRenderer.stop()
            }
            self.isPictureInPicturePrepared = false
            self.isPictureInPictureActive = false
            guard self.mpv != nil else { return }
            self.updateState(.loading)
            self.updateHTTPHeaders(headers)
            let target = url.isFileURL ? url.path : url.absoluteString
            let status = self.command(["loadfile", target, "replace"])
            if status < 0 {
                self.reportError("gpu-next loadfile failed status=\(status)")
            }
        }
    }

    public func play() {
        performOnMain {
            self.isPaused = false
            if self.isPictureInPictureActive {
                self.pictureInPictureRenderer.play()
                self.updateState(.pictureInPicture)
            } else {
                self.setFlagProperty("pause", false)
                self.updateState(.playing)
            }
        }
    }

    public func pause() {
        performOnMain {
            self.isPaused = true
            if self.isPictureInPictureActive {
                self.pictureInPictureRenderer.pause()
                self.updateState(.pictureInPicture)
            } else {
                self.setFlagProperty("pause", true)
                self.updateState(.paused)
            }
        }
    }

    public func seek(to seconds: Double) {
        let clamped = max(0, seconds)
        performOnMain {
            self.cachedPosition = clamped
            if self.isPictureInPictureActive {
                self.pictureInPictureRenderer.seek(to: clamped)
            } else {
                _ = self.command(["seek", "\(clamped)", "absolute+exact"])
            }
        }
    }

    public func seek(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    public func setSpeed(_ speed: Double) {
        let clamped = max(0.1, speed)
        performOnMain {
            self.setStringProperty("speed", "\(clamped)")
            if self.isPictureInPicturePrepared || self.isPictureInPictureActive {
                self.pictureInPictureRenderer.setSpeed(clamped)
            }
        }
    }

    public func getSpeed() -> Double {
        if isPictureInPictureActive {
            return pictureInPictureRenderer.getSpeed()
        }
        return getDoubleProperty("speed") ?? 1.0
    }

    public func prepareForPictureInPictureStart(primeFrameCount: Int = 8) -> Bool {
        var result = false
        performOnMainSync {
            guard self.currentURL != nil else {
                self.reportError("PiP prepare requested before a media URL was loaded")
                return
            }
            if self.isPictureInPicturePrepared {
                self.pictureInPictureRenderer.seek(to: self.cachedPosition)
                self.pictureInPictureRenderer.primeFrames(reason: "gpu-player-pip-prepare", count: primeFrameCount)
                result = true
                self.emitDiagnostics()
                return
            }
            do {
                try self.startPictureInPictureRendererIfNeeded()
                self.loadPictureInPictureRenderer(seekTo: self.cachedPosition, startsPaused: true)
                self.pictureInPictureRenderer.primeFrames(reason: "gpu-player-pip-prepare", count: primeFrameCount)
                self.isPictureInPicturePrepared = true
                result = true
                self.emitDiagnostics()
            } catch {
                self.reportError("PiP prepare failed: \(error.localizedDescription)")
            }
        }
        return result
    }

    public func beginPictureInPicture() {
        performOnMain {
            guard self.prepareForPictureInPictureStart() else { return }
            self.wasPausedBeforePictureInPicture = self.isPaused
            // Sync the PiP renderer to the live inline position, but only when it is actually out of
            // sync. prepare/prime already positioned it, so this avoids a redundant same-position
            // seek (which re-decodes and can stutter the PiP start) while still correcting for any
            // time that elapsed during priming.
            let handoffPosition = self.cachedPosition
            if abs(handoffPosition - self.pictureInPictureRenderer.currentTime) > 0.25 {
                self.pictureInPictureRenderer.seek(to: handoffPosition)
            }
            self.pictureInPictureRenderer.setSpeed(self.getSpeed())
            if self.options.pausesInlineRendererDuringPictureInPicture {
                self.setFlagProperty("pause", true)
                self.setStringProperty("vid", "no")
            }
            if self.wasPausedBeforePictureInPicture {
                self.pictureInPictureRenderer.pause()
            } else {
                self.pictureInPictureRenderer.play()
            }
            self.isPictureInPictureActive = true
            self.updateState(.pictureInPicture)
            self.emitDiagnostics()
        }
    }

    public func endPictureInPicture(restoringInlinePlayback: Bool = true) {
        performOnMain {
            let resumePosition = self.pictureInPictureRenderer.currentTime
            let shouldResume = !self.wasPausedBeforePictureInPicture
            self.pictureInPictureRenderer.pause()
            self.pictureInPictureRenderer.stop()
            self.isPictureInPicturePrepared = false
            self.isPictureInPictureActive = false
            self.setStringProperty("vid", "auto")

            guard restoringInlinePlayback else {
                self.setFlagProperty("pause", true)
                self.isPaused = true
                self.updateState(.paused)
                self.emitDiagnostics()
                return
            }

            if resumePosition.isFinite, resumePosition > 0 {
                self.cachedPosition = resumePosition
                _ = self.command(["seek", "\(resumePosition)", "absolute+exact"])
            }
            self.setFlagProperty("pause", !shouldResume)
            self.isPaused = !shouldResume
            self.updateState(shouldResume ? .playing : .paused)
            self.emitDiagnostics()
        }
    }

    @discardableResult
    public func command(_ args: [String]) -> Int32 {
        guard let handle = mpv, !args.isEmpty else { return -1 }
        return command(handle: handle, args: args)
    }

    /// Primes additional frames into the PiP sample-buffer renderer without re-preparing it.
    /// No-op until PiP has been prepared. Used to accumulate buffered frames before the
    /// AVPictureInPictureController hand-off, matching the sample-buffer path's multi-prime warmup.
    public func primePictureInPictureFrames(reason: String, count: Int = 6) {
        performOnMain {
            guard self.isPictureInPicturePrepared || self.isPictureInPictureActive else { return }
            self.pictureInPictureRenderer.primeFrames(reason: reason, count: count)
        }
    }

    /// Sets the mpv audio-filter chain (`af`) on the inline renderer and keeps it so the PiP
    /// renderer (a separate mpv instance) gets the same processing when it loads or is already
    /// active. Pass an empty string to clear all filters.
    public func setAudioFilterChain(_ chain: String) {
        performOnMain {
            self.audioFilterChain = chain
            self.setStringProperty("af", chain)
            if self.isPictureInPicturePrepared || self.isPictureInPictureActive {
                _ = self.pictureInPictureRenderer.command(["set", "af", chain])
            }
        }
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
        selectedAudioTrackID = id
        setStringProperty("aid", id < 0 ? "no" : "\(id)")
        if isPictureInPicturePrepared || isPictureInPictureActive {
            pictureInPictureRenderer.setAudioTrack(id: id)
        }
    }

    public func setSubtitleTrack(id: Int) {
        selectedSubtitleTrackID = id
        setStringProperty("sid", id < 0 ? "no" : "\(id)")
        if isPictureInPicturePrepared || isPictureInPictureActive {
            pictureInPictureRenderer.setSubtitleTrack(id: id)
        }
    }

    public func disableSubtitles() {
        selectedSubtitleTrackID = -1
        setStringProperty("sid", "no")
        if isPictureInPicturePrepared || isPictureInPictureActive {
            pictureInPictureRenderer.disableSubtitles()
        }
    }

    public func loadExternalSubtitles(urls: [String], names: [String]? = nil, selectFirst: Bool = true) {
        externalSubtitleURLs = urls
        externalSubtitleNames = names
        shouldSelectFirstExternalSubtitle = selectFirst
        for (index, url) in urls.enumerated() {
            var args = ["sub-add", url, index == 0 && selectFirst ? "select" : "auto"]
            if let names, names.indices.contains(index) {
                args.append(names[index])
            }
            _ = command(args)
        }
        if isPictureInPicturePrepared || isPictureInPictureActive {
            pictureInPictureRenderer.loadExternalSubtitles(urls: urls, names: names, selectFirst: selectFirst)
        }
    }

    public func applySubtitleStyle(_ style: MPVMetalSampleBufferSubtitleStyle) {
        subtitleStyle = style
        setStringProperty("sub-visibility", style.isVisible ? "yes" : "no")
        setStringProperty("sub-font-size", "\(max(1, Int(style.fontSize)))")
        setStringProperty("sub-border-size", "\(max(0, style.strokeWidth))")
        setStringProperty("sub-color", mpvColorString(style.foregroundColor))
        setStringProperty("sub-border-color", mpvColorString(style.strokeColor))
        if isPictureInPicturePrepared || isPictureInPictureActive {
            pictureInPictureRenderer.applySubtitleStyle(style)
        }
    }

    public func diagnosticsSnapshot() -> MPVGPUPlayerRendererDiagnostics {
        MPVGPUPlayerRendererDiagnostics(
            state: state,
            presentationMode: isPictureInPictureActive ? .pictureInPictureSampleBuffer : .inlineGPU,
            currentTime: currentTime,
            duration: duration,
            isPaused: isPaused,
            inlineVideoOutput: "gpu-next",
            inlineGPUAPI: "vulkan",
            inlineGPUContext: "moltenvk",
            pictureInPictureDiagnostics: isPictureInPicturePrepared || isPictureInPictureActive
                ? pictureInPictureRenderer.diagnosticsSnapshot()
                : nil,
            backendDescription: isPictureInPictureActive
                ? "AVSampleBufferDisplayLayer PiP bridge backed by MPVMetalSampleBufferRenderer"
                : "mpv gpu-next renderer backed by MoltenVK CAMetalLayer",
            videoWidth: Int(getInt64Property("video-params/w") ?? 0),
            videoHeight: Int(getInt64Property("video-params/h") ?? 0),
            videoTransferFunction: getStringProperty("video-params/gamma") ?? "",
            videoColorPrimaries: getStringProperty("video-params/primaries") ?? "",
            videoSignalPeak: getDoubleProperty("video-params/sig-peak") ?? 0,
            videoPixelFormat: getStringProperty("video-params/pixelformat") ?? "",
            hardwareDecoder: getStringProperty("hwdec-current") ?? ""
        )
    }

    private func configureInlineLayer() {
        inlineLayer.framebufferOnly = true
        inlineLayer.backgroundColor = UIColor.black.cgColor
        inlineLayer.contentsScale = UIScreen.main.nativeScale
        inlineLayer.wantsExtendedDynamicRangeContent = options.enablesTargetColorspaceHint
    }

    private func configurePictureInPictureCallbacks() {
        pictureInPictureRenderer.onError = { [weak self] message in
            self?.reportError("PiP bridge: \(message)")
        }
        pictureInPictureRenderer.onDiagnostics = { [weak self] _ in
            self?.emitDiagnostics()
        }
        pictureInPictureRenderer.onStateChange = { [weak self] _ in
            self?.emitDiagnostics()
        }
    }

    private func startPictureInPictureRendererIfNeeded() throws {
        try pictureInPictureRenderer.start()
    }

    private func loadPictureInPictureRenderer(seekTo position: Double, startsPaused: Bool) {
        guard let currentURL else { return }
        pictureInPictureRenderer.load(currentURL, headers: currentHeaders)
        pictureInPictureRenderer.setSpeed(getSpeed())
        if position.isFinite, position > 0 {
            pictureInPictureRenderer.seek(to: position)
        }
        if let selectedAudioTrackID {
            pictureInPictureRenderer.setAudioTrack(id: selectedAudioTrackID)
        }
        if let selectedSubtitleTrackID {
            if selectedSubtitleTrackID < 0 {
                pictureInPictureRenderer.disableSubtitles()
            } else {
                pictureInPictureRenderer.setSubtitleTrack(id: selectedSubtitleTrackID)
            }
        }
        if !externalSubtitleURLs.isEmpty {
            pictureInPictureRenderer.loadExternalSubtitles(
                urls: externalSubtitleURLs,
                names: externalSubtitleNames,
                selectFirst: shouldSelectFirstExternalSubtitle
            )
        }
        if let subtitleStyle {
            pictureInPictureRenderer.applySubtitleStyle(subtitleStyle)
        }
        if !audioFilterChain.isEmpty {
            _ = pictureInPictureRenderer.command(["set", "af", audioFilterChain])
        }
        startsPaused ? pictureInPictureRenderer.pause() : pictureInPictureRenderer.play()
    }

    private func layerWindowID() -> Int64 {
        Int64(Int(bitPattern: Unmanaged.passUnretained(inlineLayer).toOpaque()))
    }

    private func observeProperties(handle: OpaquePointer) {
        let properties: [(String, mpv_format)] = [
            ("duration", MPV_FORMAT_DOUBLE),
            ("time-pos", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG),
            ("track-list", MPV_FORMAT_NONE),
            ("sid", MPV_FORMAT_NONE),
            ("aid", MPV_FORMAT_NONE),
            ("video-params/gamma", MPV_FORMAT_NONE),
            ("video-params/primaries", MPV_FORMAT_NONE),
            ("video-params/sig-peak", MPV_FORMAT_NONE)
        ]
        for (name, format) in properties {
            _ = name.withCString { mpv_observe_property(handle, 0, $0, format) }
        }
    }

    private func installWakeupHandler(handle: OpaquePointer) {
        mpv_set_wakeup_callback(handle, { userdata in
            guard let userdata else { return }
            let renderer = Unmanaged<MPVGPUPlayerRenderer>.fromOpaque(userdata).takeUnretainedValue()
            let group = renderer.eventQueueGroup
            group.enter()
            renderer.eventQueue.async { [weak renderer] in
                defer { group.leave() }
                renderer?.readEvents()
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func readEvents() {
        guard let handle = mpv, !isStopping else { return }
        while !isStopping {
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
                    self.emitDiagnostics()
                    self.onVideoReconfigure?()
                }
            case MPV_EVENT_VIDEO_RECONFIG:
                performOnMain { self.onVideoReconfigure?() }
            case MPV_EVENT_END_FILE:
                // Surface decode/IO failures the host's onError can act on (the log-message scan
                // alone misses some). Only report genuine error terminations, not normal EOF/stop.
                if let data = event.data {
                    let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    if endFile.reason == MPV_END_FILE_REASON_ERROR {
                        let message = String(cString: mpv_error_string(endFile.error))
                        performOnMain { self.onError?("playback ended with error: \(message)") }
                    }
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
        case "duration":
            cachedDuration = getDoubleProperty("duration") ?? cachedDuration
        case "time-pos":
            cachedPosition = getDoubleProperty("time-pos") ?? cachedPosition
        case "pause":
            isPaused = getFlagProperty("pause")
            if !isPictureInPictureActive {
                updateState(isPaused ? .paused : .playing)
            }
        case "paused-for-cache":
            if getFlagProperty("paused-for-cache") {
                updateState(.loading)
            } else if !isPictureInPictureActive {
                updateState(isPaused ? .paused : .playing)
            }
        case "track-list", "sid", "aid":
            emitDiagnostics()
        case "video-params/gamma", "video-params/primaries", "video-params/sig-peak":
            // Colorspace/HDR characteristics resolved or changed — let the host re-evaluate HDR.
            emitDiagnostics()
            onVideoReconfigure?()
        default:
            break
        }
    }

    private func updateHTTPHeaders(_ headers: [String: String]?) {
        guard let headers, !headers.isEmpty else {
            clearProperty("http-header-fields")
            return
        }
        let headerValue = headers
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        if headerValue.isEmpty {
            clearProperty("http-header-fields")
        } else {
            setStringProperty("http-header-fields", headerValue)
        }
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

    @discardableResult
    private func command(handle: OpaquePointer, args: [String]) -> Int32 {
        var cargs = args.map { UnsafePointer<CChar>(strdup($0)) }
        cargs.append(nil)
        defer {
            for pointer in cargs where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }
        return mpv_command(handle, &cargs)
    }

    private func setOption(_ name: String, _ value: String, handle: OpaquePointer? = nil) {
        guard let handle = handle ?? mpv else { return }
        _ = name.withCString { namePointer in
            value.withCString { valuePointer in
                mpv_set_option_string(handle, namePointer, valuePointer)
            }
        }
    }

    private func setOption(_ name: String, value: Int64, handle: OpaquePointer? = nil) {
        guard let handle = handle ?? mpv else { return }
        var data = value
        _ = name.withCString { mpv_set_option(handle, $0, MPV_FORMAT_INT64, &data) }
    }

    private func setStringProperty(_ name: String, _ value: String) {
        guard let handle = mpv else { return }
        _ = name.withCString { namePointer in
            value.withCString { valuePointer in
                mpv_set_property_string(handle, namePointer, valuePointer)
            }
        }
    }

    private func clearProperty(_ name: String) {
        guard let handle = mpv else { return }
        _ = name.withCString { mpv_set_property(handle, $0, MPV_FORMAT_NONE, nil) }
    }

    private func setFlagProperty(_ name: String, _ value: Bool) {
        guard let handle = mpv else { return }
        var data: Int32 = value ? 1 : 0
        _ = name.withCString { mpv_set_property(handle, $0, MPV_FORMAT_FLAG, &data) }
    }

    private func getFlagProperty(_ name: String) -> Bool {
        guard let handle = mpv else { return false }
        var data: Int32 = 0
        _ = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_FLAG, &data) }
        return data != 0
    }

    private func getDoubleProperty(_ name: String) -> Double? {
        guard let handle = mpv else { return nil }
        var data = Double()
        let status = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_DOUBLE, &data) }
        return status >= 0 ? data : nil
    }

    private func getInt64Property(_ name: String) -> Int64? {
        guard let handle = mpv else { return nil }
        var data = Int64()
        let status = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_INT64, &data) }
        return status >= 0 ? data : nil
    }

    /// Reads a string-valued mpv property (e.g. `video-params/gamma`). The libmpv client API is
    /// thread-safe, so this is safe to call from the main thread (diagnostics/overlay) while the
    /// event loop runs on `eventQueue`. Returns nil when the property is unavailable.
    private func getStringProperty(_ name: String) -> String? {
        guard let handle = mpv else { return nil }
        guard let raw = name.withCString({ mpv_get_property_string(handle, $0) }) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
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

    private func updateState(_ newState: MPVGPUPlayerRendererState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
        emitDiagnostics()
    }

    private func reportError(_ message: String) {
        onError?(message)
        onDiagnostics?(diagnosticsSnapshot())
    }

    private func emitDiagnostics() {
        onDiagnostics?(diagnosticsSnapshot())
    }

    private func performOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func performOnMainSync(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
    }
}

#else

public final class MPVGPUPlayerRenderer {
    public static let isSupported = false
    public let inlineLayer: CAMetalLayer
    public let pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer
    public var currentTime: Double { 0 }
    public var duration: Double { 0 }
    public var onStateChange: ((MPVGPUPlayerRendererState) -> Void)?
    public var onError: ((String) -> Void)?
    public var onDiagnostics: ((MPVGPUPlayerRendererDiagnostics) -> Void)?

    public convenience init(options: MPVGPUPlayerRendererOptions = MPVGPUPlayerRendererOptions()) {
        self.init(
            inlineLayer: MPVGPUPlayerMetalLayer(),
            pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer(),
            options: options
        )
    }

    public init(
        inlineLayer: CAMetalLayer,
        pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer(),
        options: MPVGPUPlayerRendererOptions = MPVGPUPlayerRendererOptions()
    ) {
        self.inlineLayer = inlineLayer
        self.pictureInPictureDisplayLayer = pictureInPictureDisplayLayer
        _ = options
    }

    public func updateInlineLayerLayout(bounds: CGRect, contentsScale: CGFloat = 1) { _ = bounds; _ = contentsScale }
    public func updateOptions(_ newOptions: MPVGPUPlayerRendererOptions) { _ = newOptions }
    public func start() throws { throw MPVMetalSampleBufferRendererError.unsupportedPlatform }
    public func stop() {}
    public func load(_ url: URL, headers: [String: String]? = nil) { _ = url; _ = headers }
    public func play() {}
    public func pause() {}
    public func seek(to seconds: Double) { _ = seconds }
    public func seek(by seconds: Double) { _ = seconds }
    public func setSpeed(_ speed: Double) { _ = speed }
    public func getSpeed() -> Double { 1 }
    public func prepareForPictureInPictureStart(primeFrameCount: Int = 8) -> Bool { _ = primeFrameCount; return false }
    public func beginPictureInPicture() {}
    public func endPictureInPicture(restoringInlinePlayback: Bool = true) { _ = restoringInlinePlayback }
    @discardableResult public func command(_ args: [String]) -> Int32 { _ = args; return -1 }
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
    public func diagnosticsSnapshot() -> MPVGPUPlayerRendererDiagnostics {
        MPVGPUPlayerRendererDiagnostics(
            state: .failed("unsupported platform"),
            presentationMode: .inlineGPU,
            currentTime: 0,
            duration: 0,
            isPaused: true,
            inlineVideoOutput: "unsupported",
            inlineGPUAPI: "unsupported",
            inlineGPUContext: "unsupported",
            pictureInPictureDiagnostics: nil,
            backendDescription: "unsupported",
            videoWidth: 0,
            videoHeight: 0,
            videoTransferFunction: "",
            videoColorPrimaries: "",
            videoSignalPeak: 0,
            videoPixelFormat: "",
            hardwareDecoder: ""
        )
    }
}

#endif
