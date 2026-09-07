@preconcurrency import AVFoundation
import Accelerate
import CoreGraphics
import CoreMedia
@preconcurrency import CoreVideo
@preconcurrency import Dispatch
import Foundation
import MPVKitSampleBufferCore

// Immutable CoreGraphics objects are safe to reuse for every frame. Constructing them in the
// sample-buffer hot path needlessly consults ColorSync and allocates wrapper objects at PiP rate.
private let mpvMetalSampleBufferSRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
private let mpvMetalSampleBufferExtendedP3ColorSpace =
    CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

public enum MPVMetalSampleBufferRendererState: Equatable, Sendable {
    case idle
    case starting
    case loading
    case ready
    case playing
    case paused
    case stopping
    case stopped
    case failed(String)
}

public enum MPVMetalSampleBufferPresentationBackend: String, Equatable, Sendable {
    case metalHighBitDepthHDRIOSurface
    case metalHDRIOSurface
    case metalIOSurface
    case softwareIOSurface
}

public struct MPVMetalSampleBufferRendererOptions: Equatable, Sendable {
    public var maximumFrameSize: CGSize
    public var preferredFramesPerSecond: Int
    public var preferredPiPFramesPerSecond: Int
    public var createsMetalCompatibilityProbe: Bool
    public var prefersMetalPresentation: Bool
    public var prefersHDRPresentation: Bool
    public var prefersHighBitDepthRendering: Bool
    /// Whether the compatibility PiP decoder may fall back to CPU decoding when
    /// `videotoolbox-copy` cannot attach. Defaults to true for source compatibility.
    public var allowsSoftwareDecoderFallback: Bool
    /// Maximum number of IOSurface-backed buffers that the display path may have outstanding.
    /// Keeping this small is especially important on iPad while PiP and Stage Manager are active.
    public var maximumInFlightFrameCount: Int

    public init(
        maximumFrameSize: CGSize = CGSize(width: 1280, height: 720),
        preferredFramesPerSecond: Int = 30,
        preferredPiPFramesPerSecond: Int = 24,
        createsMetalCompatibilityProbe: Bool = true,
        prefersMetalPresentation: Bool = true,
        prefersHDRPresentation: Bool = true,
        prefersHighBitDepthRendering: Bool = true,
        allowsSoftwareDecoderFallback: Bool = true,
        maximumInFlightFrameCount: Int = 3
    ) {
        self.maximumFrameSize = maximumFrameSize
        self.preferredFramesPerSecond = preferredFramesPerSecond
        self.preferredPiPFramesPerSecond = preferredPiPFramesPerSecond
        self.createsMetalCompatibilityProbe = createsMetalCompatibilityProbe
        self.prefersMetalPresentation = prefersMetalPresentation
        self.prefersHDRPresentation = prefersHDRPresentation
        self.prefersHighBitDepthRendering = prefersHighBitDepthRendering
        self.allowsSoftwareDecoderFallback = allowsSoftwareDecoderFallback
        self.maximumInFlightFrameCount = min(3, max(1, maximumInFlightFrameCount))
    }
}

public struct MPVMetalSampleBufferFrame: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public let dimensions: CMVideoDimensions
    public let frameIndex: Int
}

public struct MPVMetalSampleBufferRendererDiagnostics: Equatable, Sendable {
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
    public let presentationBackend: MPVMetalSampleBufferPresentationBackend
    public let metalPresentationFrameCount: Int
    public let metalPresentationFailureCount: Int
    public let pixelFormatDescription: String
    public let sourcePixelFormatDescription: String
    public let highBitDepthRenderingActive: Bool
    public let highBitDepthRenderingFailureCount: Int
    public let hdrMetadataApplied: Bool
    public let videoColorPrimaries: String
    public let videoTransferFunction: String
    public let videoSignalPeak: Double
    public let renderAPI: String
    public let backendDescription: String
    public let coalescedRenderRequestCount: Int
    public let backpressureDropCount: Int
    public let poolExhaustionDropCount: Int
    public let staleGenerationDropCount: Int
    public let inFlightGPUFrameCount: Int
    public let lastGPULatencyMilliseconds: Double
    public let timelineEpoch: UInt64
    public let timelineRate: Double
}

public struct MPVMetalSampleBufferTrack: Equatable, Sendable {
    public let id: Int
    public let type: String
    public let title: String
    public let language: String
    public let codec: String
    public let selected: Bool
}

public struct MPVMetalSampleBufferSubtitleStyle: @unchecked Sendable {
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
    case teardownInProgress

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "MPVMetalSampleBufferRenderer is only available on iOS, tvOS, and Apple Silicon macOS."
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
        case .teardownInProgress:
            return "MPVMetalSampleBufferRenderer teardown is still in progress."
        }
    }
}

#if os(iOS) || os(tvOS) || (os(macOS) && arch(arm64))
import Darwin
import Libmpv
@preconcurrency import Metal
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private final class MPVMetalSampleBufferCallbackToken: @unchecked Sendable {
    enum Kind {
        case render
        case events
    }

    private weak var renderer: MPVMetalSampleBufferRenderer?
    private let engineGeneration: UInt64
    private let kind: Kind
    private let lock = NSLock()
    private var isActive = true
    private var isSignalPending = false

    init(renderer: MPVMetalSampleBufferRenderer, engineGeneration: UInt64, kind: Kind) {
        self.renderer = renderer
        self.engineGeneration = engineGeneration
        self.kind = kind
    }

    func signal() {
        lock.lock()
        guard isActive, !isSignalPending else {
            lock.unlock()
            return
        }
        isSignalPending = true
        lock.unlock()

        // libmpv may invoke this callback from arbitrary threads and in bursts. Coalesce the
        // callback before crossing onto the renderer's actor; the render queue will coalesce the
        // actual frame demand separately.
        DispatchQueue.main.async { @MainActor [weak self] in
            self?.deliverSignal()
        }
    }

    @MainActor
    private func deliverSignal() {
        lock.lock()
        isSignalPending = false
        guard isActive else {
            lock.unlock()
            return
        }
        let renderer = self.renderer
        let generation = engineGeneration
        let kind = self.kind
        lock.unlock()

        switch kind {
        case .render:
            renderer?.scheduleRender(force: false, engineGeneration: generation)
        case .events:
            break
        }
    }

    var active: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive
    }

    func deactivate() {
        lock.lock()
        isActive = false
        renderer = nil
        lock.unlock()
    }
}

private enum MPVMetalSampleBufferEvent: Sendable {
    case startFile(playlistEntryID: Int64)
    case fileLoaded(playlistEntryID: Int64?)
    case videoReconfigure(playlistEntryID: Int64?)
    case endFile(playlistEntryID: Int64)
    case propertyChange(String, value: MPVMetalObservedPropertyValue, playlistEntryID: Int64?)
    case logError(String, playlistEntryID: Int64?)
    case commandReply(requestID: UInt64, error: Int32)
    case shutdown
}

private enum MPVMetalObservedPropertyValue: Sendable {
    case unavailable
    case string(String)
    case flag(Bool)
    case int64(Int64)
    case double(Double)
}

private func copyMPVMetalObservedPropertyValue(
    _ property: mpv_event_property
) -> MPVMetalObservedPropertyValue {
    guard let data = property.data else { return .unavailable }
    switch property.format {
    case MPV_FORMAT_STRING:
        guard let value = data
            .assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
            .pointee else { return .unavailable }
        return .string(String(cString: value))
    case MPV_FORMAT_FLAG:
        return .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
    case MPV_FORMAT_INT64:
        return .int64(data.assumingMemoryBound(to: Int64.self).pointee)
    case MPV_FORMAT_DOUBLE:
        return .double(data.assumingMemoryBound(to: Double.self).pointee)
    default:
        return .unavailable
    }
}

private func copyMPVMetalSampleBufferEvent(
    _ event: mpv_event,
    activePlaylistEntryID: inout Int64?
) -> MPVMetalSampleBufferEvent? {
    switch event.event_id {
    case MPV_EVENT_START_FILE:
        guard let data = event.data else { return nil }
        let startFile = data.assumingMemoryBound(to: mpv_event_start_file.self).pointee
        activePlaylistEntryID = startFile.playlist_entry_id
        return .startFile(playlistEntryID: startFile.playlist_entry_id)
    case MPV_EVENT_FILE_LOADED:
        return .fileLoaded(playlistEntryID: activePlaylistEntryID)
    case MPV_EVENT_VIDEO_RECONFIG:
        return .videoReconfigure(playlistEntryID: activePlaylistEntryID)
    case MPV_EVENT_END_FILE:
        guard let data = event.data else { return nil }
        let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
        let playlistEntryID = endFile.playlist_entry_id
        if activePlaylistEntryID == playlistEntryID {
            activePlaylistEntryID = nil
        }
        return .endFile(playlistEntryID: playlistEntryID)
    case MPV_EVENT_PROPERTY_CHANGE:
        guard let data = event.data else { return nil }
        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        guard let name = property.name else { return nil }
        return .propertyChange(
            String(cString: name),
            value: copyMPVMetalObservedPropertyValue(property),
            playlistEntryID: activePlaylistEntryID
        )
    case MPV_EVENT_LOG_MESSAGE:
        guard let log = event.data?.assumingMemoryBound(to: mpv_event_log_message.self) else {
            return nil
        }
        let text = log.pointee.text.map { String(cString: $0) } ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? nil
            : .logError(trimmed, playlistEntryID: activePlaylistEntryID)
    case MPV_EVENT_COMMAND_REPLY:
        return .commandReply(requestID: event.reply_userdata, error: event.error)
    case MPV_EVENT_SHUTDOWN:
        return .shutdown
    default:
        return nil
    }
}

private enum MPVMetalSampleBufferDeferredLoadAction {
    case videoTrack(String)
    case audioTrack(Int)
    case subtitleStyle(MPVMetalSampleBufferSubtitleStyle)
}

private struct MPVMetalSampleBufferPendingDisplaySample: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let pixelBuffer: CVPixelBuffer
    let description: CMVideoFormatDescription
    let presentationTime: CMTime
    let mediaSeconds: Double
    let timelineEpoch: UInt64
    let forceSDR: Bool
}

private struct MPVMetalSampleBufferPendingRecoveryFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let forceSDR: Bool
    let loadGeneration: UInt64
    let timelineEpoch: UInt64
}

private struct MPVMetalSampleBufferDisplayFlushRequest: @unchecked Sendable {
    let loadGeneration: UInt64
    let removingDisplayedImage: Bool
    let pendingSample: MPVMetalSampleBufferPendingDisplaySample?
    let recoversDisplayRenderer: Bool
    let recoveryTimelineEpoch: UInt64?
}

/// Immutable handoff from the serial render queue to the main-actor diagnostics surface.
/// None of these values are read cross-queue in mutable form.
private struct MPVMetalSampleBufferRenderDiagnosticsSnapshot: @unchecked Sendable {
    var frameCount = 0
    var renderAttemptCount = 0
    var renderFailureCount = 0
    var allocationFailureCount = 0
    var enqueueFailureCount = 0
    var lastRenderStatus: Int32 = 0
    var lastFrameSize = CGSize.zero
    var lastPresentationTime: Double = 0
    var metalCompatibilityProbeSucceeded = false
    var presentationBackend: MPVMetalSampleBufferPresentationBackend = .softwareIOSurface
    var metalPresentationFrameCount = 0
    var metalPresentationFailureCount = 0
    var pixelFormatDescription = "BGRA8"
    var sourcePixelFormatDescription = "bgr0/BGRA8"
    var highBitDepthRenderingActive = false
    var highBitDepthRenderingFailureCount = 0
    var hdrMetadataApplied = false
    var videoColorPrimaries = ""
    var videoTransferFunction = ""
    var videoSignalPeak: Double = 0
    var backendDescription = "libmpv sample-buffer renderer with software IOSurface presentation"
    var coalescedRenderRequestCount = 0
    var backpressureDropCount = 0
    var poolExhaustionDropCount = 0
    var staleGenerationDropCount = 0
    var inFlightGPUFrameCount = 0
    var lastGPULatencyMilliseconds: Double = 0
    var timelineEpoch: UInt64 = 0
    var timelineRate: Double = 0
}

private final class MPVHighBitDepthStagingPool: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        let length: Int
        private let lock = NSLock()
        private var releaseHandler: (() -> Void)?

        fileprivate init(pointer: UnsafeMutableRawPointer, length: Int, releaseHandler: @escaping () -> Void) {
            self.pointer = pointer
            self.length = length
            self.releaseHandler = releaseHandler
        }

        func release() {
            lock.lock()
            let handler = releaseHandler
            releaseHandler = nil
            lock.unlock()
            handler?()
        }

        deinit { release() }
    }

    private struct Entry {
        let pointer: UnsafeMutableRawPointer
        var isInUse: Bool
    }

    let generation: UInt64
    let width: Int
    let height: Int
    let stride: Int
    let byteCount: Int
    let allocationLength: Int
    private let capacity: Int
    private let lock = NSLock()
    private var entries: [Entry] = []

    init(generation: UInt64, width: Int, height: Int, stride: Int, capacity: Int) {
        self.generation = generation
        self.width = width
        self.height = height
        self.stride = stride
        self.byteCount = stride * height
        let pageSize = Int(getpagesize())
        self.allocationLength = ((self.byteCount + pageSize - 1) / pageSize) * pageSize
        self.capacity = min(3, max(1, capacity))
    }

    func matches(generation: UInt64, width: Int, height: Int, stride: Int) -> Bool {
        self.generation == generation && self.width == width && self.height == height && self.stride == stride
    }

    func acquire() -> Lease? {
        lock.lock()
        let index: Int
        if let available = entries.firstIndex(where: { !$0.isInUse }) {
            index = available
            entries[index].isInUse = true
        } else if entries.count < capacity {
            var rawPointer: UnsafeMutableRawPointer?
            let pageSize = Int(getpagesize())
            guard posix_memalign(&rawPointer, pageSize, allocationLength) == 0, let pointer = rawPointer else {
                lock.unlock()
                return nil
            }
            index = entries.count
            entries.append(Entry(pointer: pointer, isInUse: true))
        } else {
            lock.unlock()
            return nil
        }
        let pointer = entries[index].pointer
        lock.unlock()

        return Lease(pointer: pointer, length: allocationLength) { [self] in
            release(index: index)
        }
    }

    private func release(index: Int) {
        lock.lock()
        if entries.indices.contains(index) { entries[index].isInUse = false }
        lock.unlock()
    }

    deinit { entries.forEach { free($0.pointer) } }
}

private final class MPVMetalUncheckedSendableReference<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private final class MPVMetalSampleBufferReadinessHandler: @unchecked Sendable {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    func callAsFunction() { body() }
}

private final class MPVMetalSampleBufferValueHandler<Value>: @unchecked Sendable {
    private let body: (Value) -> Void
    init(_ body: @escaping (Value) -> Void) { self.body = body }
    func callAsFunction(_ value: Value) { body(value) }
}

private struct MPVMetalSampleBufferTimelineWaiter: @unchecked Sendable {
    let engineGeneration: UInt64
    let loadGeneration: UInt64
    let timelineEpoch: UInt64
    let continuation: CheckedContinuation<Bool, Never>
}

/// Retains CoreVideo/Metal objects across the command-buffer callback and the serial render queue.
/// Their use remains ordered by the GPU fence; unchecked sendability only bridges SDK types that
/// do not yet declare Sendable conformance.
private final class MPVMetalGPUCompletionResources: @unchecked Sendable {
    let destinationBuffer: CVPixelBuffer
    let fallbackBuffer: CVPixelBuffer?
    let retainedObjects: [AnyObject]

    init(
        destinationBuffer: CVPixelBuffer,
        fallbackBuffer: CVPixelBuffer?,
        retainedObjects: [AnyObject]
    ) {
        self.destinationBuffer = destinationBuffer
        self.fallbackBuffer = fallbackBuffer
        self.retainedObjects = retainedObjects
    }
}

private final class MPVMetalGPUCompletionPayload: @unchecked Sendable {
    let commandBuffer: MTLCommandBuffer
    let resources: MPVMetalGPUCompletionResources

    init(commandBuffer: MTLCommandBuffer, resources: MPVMetalGPUCompletionResources) {
        self.commandBuffer = commandBuffer
        self.resources = resources
    }
}

/// Last-resort nonblocking cleanup for a host that releases a renderer without awaiting `stop()`.
/// Normal teardown disarms this owner after transferring the same resources to the explicit stop
/// pipeline. Pointer values are stored as integers so the cleanup snapshot is safely transferable.
private final class MPVMetalSampleBufferEmergencyCleanup: @unchecked Sendable {
    private final class Snapshot: @unchecked Sendable {
        let handleAddress: UInt
        let contextAddress: UInt
        let renderUserdataAddress: UInt
        let renderToken: MPVMetalSampleBufferCallbackToken?
        let eventToken: MPVMetalSampleBufferCallbackToken?
        let eventQueueGroup: DispatchGroup
        let gpuConversionGroup: DispatchGroup
        let renderQueue: DispatchQueue
        let displayLayer: AVSampleBufferDisplayLayer

        init(
            handleAddress: UInt,
            contextAddress: UInt,
            renderUserdataAddress: UInt,
            renderToken: MPVMetalSampleBufferCallbackToken?,
            eventToken: MPVMetalSampleBufferCallbackToken?,
            eventQueueGroup: DispatchGroup,
            gpuConversionGroup: DispatchGroup,
            renderQueue: DispatchQueue,
            displayLayer: AVSampleBufferDisplayLayer
        ) {
            self.handleAddress = handleAddress
            self.contextAddress = contextAddress
            self.renderUserdataAddress = renderUserdataAddress
            self.renderToken = renderToken
            self.eventToken = eventToken
            self.eventQueueGroup = eventQueueGroup
            self.gpuConversionGroup = gpuConversionGroup
            self.renderQueue = renderQueue
            self.displayLayer = displayLayer
        }
    }

    private let lock = NSLock()
    private var snapshot: Snapshot?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    func retainMemoryPressureSource(_ source: DispatchSourceMemoryPressure) {
        lock.lock()
        memoryPressureSource = source
        lock.unlock()
    }

    func install(
        handle: OpaquePointer,
        context: OpaquePointer,
        renderUserdata: UnsafeMutableRawPointer,
        renderToken: MPVMetalSampleBufferCallbackToken?,
        eventToken: MPVMetalSampleBufferCallbackToken?,
        eventQueueGroup: DispatchGroup,
        gpuConversionGroup: DispatchGroup,
        renderQueue: DispatchQueue,
        displayLayer: AVSampleBufferDisplayLayer
    ) {
        let installed = Snapshot(
            handleAddress: UInt(bitPattern: handle),
            contextAddress: UInt(bitPattern: context),
            renderUserdataAddress: UInt(bitPattern: renderUserdata),
            renderToken: renderToken,
            eventToken: eventToken,
            eventQueueGroup: eventQueueGroup,
            gpuConversionGroup: gpuConversionGroup,
            renderQueue: renderQueue,
            displayLayer: displayLayer
        )
        lock.lock()
        snapshot = installed
        lock.unlock()
    }

    func disarmNativeResources() {
        lock.lock()
        snapshot = nil
        lock.unlock()
    }

    func cleanup() {
        lock.lock()
        let cleanupSnapshot = snapshot
        snapshot = nil
        let pressureSource = memoryPressureSource
        memoryPressureSource = nil
        lock.unlock()

        pressureSource?.cancel()
        guard let cleanupSnapshot else { return }

        cleanupSnapshot.renderToken?.deactivate()
        cleanupSnapshot.eventToken?.deactivate()
        if let context = OpaquePointer(bitPattern: cleanupSnapshot.contextAddress) {
            mpv_render_context_set_update_callback(context, nil, nil)
        }
        if let handle = OpaquePointer(bitPattern: cleanupSnapshot.handleAddress) {
            mpv_wakeup(handle)
        }

        cleanupSnapshot.eventQueueGroup.notify(queue: cleanupSnapshot.renderQueue) {
            if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
                cleanupSnapshot.displayLayer.sampleBufferRenderer.stopRequestingMediaData()
            } else {
                cleanupSnapshot.displayLayer.stopRequestingMediaData()
            }
            cleanupSnapshot.gpuConversionGroup.notify(queue: cleanupSnapshot.renderQueue) {
                if let context = OpaquePointer(bitPattern: cleanupSnapshot.contextAddress) {
                    mpv_render_context_free(context)
                }
                if let handle = OpaquePointer(bitPattern: cleanupSnapshot.handleAddress) {
                    mpv_terminate_destroy(handle)
                }
                if let renderUserdata = UnsafeMutableRawPointer(
                    bitPattern: cleanupSnapshot.renderUserdataAddress
                ) {
                    Unmanaged<MPVMetalSampleBufferCallbackToken>
                        .fromOpaque(renderUserdata)
                        .release()
                }
                DispatchQueue.main.async {
                    cleanupSnapshot.displayLayer.controlTimebase = nil
                    cleanupSnapshot.displayLayer.flushAndRemoveImage()
                }
            }
        }
    }

    deinit { cleanup() }
}

@preconcurrency @MainActor
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

    /// Main-actor configuration accepted from the host. Rendering reads only `renderOptions`,
    /// which is installed and consumed on `renderQueue`.
    private var options: MPVMetalSampleBufferRendererOptions
    private var renderOptions: MPVMetalSampleBufferRendererOptions
    private let eventQueue = DispatchQueue(label: "mpvkit.sample-buffer.events", qos: .utility)
    private let renderQueue = DispatchQueue(label: "mpvkit.sample-buffer.render", qos: .userInitiated)
    private let eventQueueGroup = DispatchGroup()
    private let gpuConversionGroup = DispatchGroup()
    private let emergencyCleanup = MPVMetalSampleBufferEmergencyCleanup()
    private var mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var renderCallbackToken: MPVMetalSampleBufferCallbackToken?
    private var eventCallbackToken: MPVMetalSampleBufferCallbackToken?
    private var renderCallbackUserdata: UnsafeMutableRawPointer?
    private var engineGeneration: UInt64 = 0
    private var loadGeneration: UInt64 = 0
    private let renderLifecycleFence = MPVRenderLifecycleFence()
    private var publishedRenderDiagnostics = MPVMetalSampleBufferRenderDiagnosticsSnapshot()
    private var loadIdentityTracker = MPVLoadIdentityTracker()
    private var deferredLoadActions = MPVGenerationDeferredActions<MPVMetalSampleBufferDeferredLoadAction>()
    private var isAwaitingCurrentFileLoaded = false
    private var pendingLoadSubmission: Task<Void, Never>?
    private var nextAsyncCommandRequestID: UInt64 = 0
    private var pendingAsyncCommandReplies: [UInt64: MPVAsyncCommandReply] = [:]
    private lazy var externalSubtitles = MPVExternalSubtitleQueue(
        submit: { [weak self] args in
            guard let self else {
                let reply = MPVAsyncCommandReply()
                reply.complete(-1)
                return reply
            }
            return self.submitAsyncCommand(args)
        },
        trackIDs: { [weak self] in self?.subtitleTracks().map(\.id) ?? [] },
        selectedTrackID: { [weak self] in self?.currentSubtitleTrackID() ?? -1 },
        applySelection: { [weak self] id in self?.applySubtitleTrack(id) },
        didChange: { [weak self] in
            self?.requestPausedPresentationRefresh()
            if let self {
                self.onDiagnostics?(self.diagnosticsSnapshot())
            }
        }
    )
    private var scheduledRenderWorkItem: DispatchWorkItem?
    private var demandScheduler = MPVFrameDemandScheduler()
    private var legacyPrimeBudget = MPVLegacyPrimeBudget(capacity: 2)
    private var poolExhaustionDropCount = 0
    /// Stale mpv events are rejected on the main actor. Render/GPU stale drops use the
    /// render-queue-owned counter with the same base name below and are published by snapshot.
    private var eventStaleGenerationDropCount = 0
    private var staleGenerationDropCount = 0
    private var lastGPULatencyMilliseconds: Double = 0
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferPoolAuxAttributes: CFDictionary?
    private var hdrPixelBufferPool: CVPixelBufferPool?
    private var hdrPixelBufferPoolAuxAttributes: CFDictionary?
    private var formatDescription: CMVideoFormatDescription?
    private var poolWidth = 0
    private var poolHeight = 0
    private var videoSize: CGSize = .zero
    private var renderVideoSize: CGSize = .zero
    private var displayBoundsSnapshot: CGRect = .zero
    private var presentationScaleSnapshot: CGFloat = 1
    private var cachedPosition: Double = 0
    private var cachedDuration: Double = 0
    private var cachedVideoPTS: Double?
    private var cachedSourceFPS: Double?
    private var cachedSpeed: Double = 1
    private var observedVideoColorPrimaries = ""
    private var observedVideoTransferFunction = ""
    private var observedVideoYCbCrMatrix = ""
    private var observedVideoSignalPeak: Double = 0
    private var videoColorMetadataPublishWorkItem: DispatchWorkItem?
    private var isPausedForCache = false
    private var renderPosition: Double = 0
    private var renderVideoPTS: Double?
    private var renderSourceFPS: Double?
    private var renderSpeed: Double = 1
    private var renderIsPaused = true
    private var renderIsBuffering = false
    private var sampleTimeline = MPVSampleTimeline()
    private var timelineIsAnchored = false
    private var lastTimebaseDriftCheckTime: CFTimeInterval = 0
    private var lastAppliedTimebaseRate: Double?
    private var allowsPausedDuplicateFrame = false
    private var flushInFlight = false
    private var flushCoordinator = MPVFlushEpochCoordinator()
    private var pendingDisplayFlush: MPVMetalSampleBufferDisplayFlushRequest?
    private var displayRecoveryGate = MPVDisplayLayerRecoveryGate()
    private var pendingDisplayRecoveryFrame: MPVMetalSampleBufferPendingRecoveryFrame?
    private var displayRecoveryProbeGeneration: UInt64?
    private var finishesStopAfterDisplayFlush = false
    /// True once MPV_EVENT_FILE_LOADED has fired for the current load. mpv silently drops an
    /// absolute seek issued before the file is loaded, so seeks requested earlier are deferred
    /// (see `pendingSeek`) and replayed here.
    private var isFileLoaded = false
    private var renderIsFileLoaded = false
    /// A seek target requested before the file finished loading. Applied on FILE_LOADED so a PiP
    /// hand-off that loads this instance and immediately seeks to the live position actually starts
    /// there instead of from the beginning.
    private var pendingSeek: Double?
    private var isPaused = true
    private var isRunning = false
    private var isStopping = false
    /// Becomes true only after libmpv reports a real frame update for the current loaded file.
    /// Forced renders before that point can contain mpv's blank pre-file framebuffer and must not
    /// make the host believe PiP has been primed.
    private var hasReceivedVideoFrameUpdate = false
    private var frameCount = 0
    private var lastFrameDiagnosticsEmissionTime: CFTimeInterval?
    private var renderAttemptCount = 0
    private var renderFailureCount = 0
    private var allocationFailureCount = 0
    private var enqueueFailureCount = 0
    private var metalPresentationFrameCount = 0
    private var metalPresentationFailureCount = 0
    private var lastRenderStatus: Int32 = 0
    private var lastFrameSize: CGSize = .zero
    private var lastPresentationTime: Double = 0
    private var state: MPVMetalSampleBufferRendererState = .idle
    private var metalDevice: MTLDevice?
    private var metalCommandQueue: MTLCommandQueue?
    private var metalTextureCache: CVMetalTextureCache?
    private var hdrConversionPipeline: MTLComputePipelineState?
    private var highBitDepthConversionPipeline: MTLComputePipelineState?
    private var highBitDepthStagingPool: MPVHighBitDepthStagingPool?
    private var metalCompatibilityProbeSucceeded = false
    private var presentationBackend: MPVMetalSampleBufferPresentationBackend = .softwareIOSurface
    private var lastPixelFormatDescription = "BGRA8"
    private var lastSourcePixelFormatDescription = "bgr0/BGRA8"
    private var lastPixelFormatType = kCVPixelFormatType_32BGRA
    private var hdrMetadataApplied = false
    private var hdrPresentationDisabled = false
    private var highBitDepthRenderingDisabled = false
    private var highBitDepthRenderingActive = false
    private var highBitDepthRenderingFailureCount = 0
    private var formatDescriptionMetadataSignature = ""
    private var videoColorPrimaries = ""
    private var videoTransferFunction = ""
    private var videoYCbCrMatrix = ""
    private var videoSignalPeak: Double = 0
    private var resolvedStreamLooksHDR = false
    private var cachedSourceColorAttachments: CFDictionary?
    private var cachedSDRColorAttachments: CFDictionary?
    private var cachedSourceColorMetadataSignature = "bt709|bt709|bt709|0.000"
    private var swFormat = Array("bgr0".utf8CString)
    private var highBitDepthSwFormat = Array("rgba64".utf8CString)
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []
    private var timelineWaiters: [MPVMetalSampleBufferTimelineWaiter] = []

    public init(
        displayLayer: AVSampleBufferDisplayLayer,
        options: MPVMetalSampleBufferRendererOptions = MPVMetalSampleBufferRendererOptions()
    ) {
        self.displayLayer = displayLayer
        self.options = options
        self.renderOptions = options
        self.metalDevice = MTLCreateSystemDefaultDevice()
        configureDisplayLayer()
        capturePresentationGeometry()
        if let metalDevice {
            metalCommandQueue = metalDevice.makeCommandQueue()
            var cache: CVMetalTextureCache?
            if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &cache) == kCVReturnSuccess {
                metalTextureCache = cache
            }
        }
        let pressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        pressureSource.setEventHandler { [weak self] in
            guard let self, let cache = self.metalTextureCache else { return }
            let cacheReference = MPVMetalUncheckedSendableReference(cache)
            // Serialize the exceptional cache flush with all texture creation/conversion work.
            self.enqueueRenderWork {
                CVMetalTextureCacheFlush(cacheReference.value, 0)
            }
        }
        pressureSource.resume()
        emergencyCleanup.retainMemoryPressureSource(pressureSource)
    }

    deinit {
        let replies = Array(pendingAsyncCommandReplies.values)
        Task { @MainActor in
            for reply in replies { reply.complete(-1) }
        }
        emergencyCleanup.cleanup()
    }

    public func start() throws {
        guard !isRunning else { return }
        guard !isStopping else {
            throw MPVMetalSampleBufferRendererError.teardownInProgress
        }
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
        // Avoid paying mpv's formatting and root-log-lock cost for verbose messages that are not
        // displayed. MPV_EVENT_LOG_MESSAGE remains at libmpv's default disabled request level;
        // recoverable log lines must not be promoted into fatal playback errors.
        setOption("msg-level", "all=error")
        setOption("idle", "yes")
        setOption("keep-open", "yes")
        setOption("vo", "libmpv")
        setOption("profile", options.prefersHighBitDepthRendering ? "high-quality" : "fast")
        setOption("hwdec", "videotoolbox-copy")
        setOption("hwdec-software-fallback", options.allowsSoftwareDecoderFallback ? "yes" : "no")
        setOption("vd-lavc-dr", "no")
        setOption("video-sync", "audio")
        setOption("framedrop", "vo")
        #if os(tvOS)
        // Prefer the AVFoundation output on tvOS because recent Dolby/Atmos HDMI routes can leave
        // AudioUnit open but silent. AudioUnit remains the fallback for older route combinations.
        setOption("ao", "avfoundation,audiounit")
        #endif
        setOption("dither-depth", "auto")
        setOption("target-colorspace-hint", "yes")
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

        engineGeneration &+= 1
        let generation = engineGeneration
        let renderStatus = createRenderContext(handle: handle, engineGeneration: generation)
        guard renderStatus >= 0, renderContext != nil else {
            mpv_terminate_destroy(handle)
            mpv = nil
            let message = "sample-buffer render context failed status=\(renderStatus)"
            updateState(.failed(message))
            throw MPVMetalSampleBufferRendererError.renderContextCreationFailed(renderStatus)
        }

        observeProperties(handle: handle)
        startEventLoop(handle: handle, engineGeneration: generation)
        if let context = renderContext,
           let renderUserdata = renderCallbackUserdata {
            emergencyCleanup.install(
                handle: handle,
                context: context,
                renderUserdata: renderUserdata,
                renderToken: renderCallbackToken,
                eventToken: eventCallbackToken,
                eventQueueGroup: eventQueueGroup,
                gpuConversionGroup: gpuConversionGroup,
                renderQueue: renderQueue,
                displayLayer: displayLayer
            )
        }
        isRunning = true
        updateRenderLifecycleFence()
        updateState(.ready)
    }

    public func stop() {
        guard !isStopping else { return }
        guard state != .stopped else { return }
        _ = externalSubtitles.beginGeneration()
        pendingLoadSubmission?.cancel()
        pendingLoadSubmission = nil
        let replies = Array(pendingAsyncCommandReplies.values)
        pendingAsyncCommandReplies.removeAll()
        for reply in replies { reply.complete(-1) }
        videoColorMetadataPublishWorkItem?.cancel()
        videoColorMetadataPublishWorkItem = nil
        guard mpv != nil || renderContext != nil else {
            isStopping = true
            isRunning = false
            engineGeneration &+= 1
            updateRenderLifecycleFence()
            updateState(.stopping)
            let stoppingLoadGeneration = loadGeneration
            enqueueRenderWork { [weak self] in
                guard let self else { return }
                self.pendingDisplayFlush = nil
                self.pendingDisplayRecoveryFrame = nil
                self.displayRecoveryProbeGeneration = nil
                self.displayRecoveryGate.cancel()
                self.finishesStopAfterDisplayFlush = true
                _ = self.flushCoordinator.beginEpoch()
                self.requestDisplayFlush(
                    removingDisplayedImage: true,
                    loadGeneration: stoppingLoadGeneration,
                    pendingSample: nil
                )
            }
            return
        }

        isStopping = true
        isRunning = false
        engineGeneration &+= 1
        updateRenderLifecycleFence()
        updateState(.stopping)

        let context = renderContext
        let handle = mpv
        let renderToken = renderCallbackToken
        let eventToken = eventCallbackToken
        let renderUserdata = renderCallbackUserdata
        emergencyCleanup.disarmNativeResources()
        mpv = nil
        renderCallbackToken = nil
        eventCallbackToken = nil
        renderCallbackUserdata = nil

        renderToken?.deactivate()
        eventToken?.deactivate()
        if let context {
            mpv_render_context_set_update_callback(context, nil, nil)
        }
        if let handle {
            mpv_wakeup(handle)
        }

        let displayLayer = self.displayLayer
        let gpuConversionGroup = self.gpuConversionGroup
        let renderQueue = self.renderQueue
        let stoppingLoadGeneration = loadGeneration
        let eventDrain = MPVMetalSampleBufferReadinessHandler { [weak self] in
            self?.scheduledRenderWorkItem?.cancel()
            self?.scheduledRenderWorkItem = nil
            _ = self?.demandScheduler.beginGeneration()
            self?.stopRequestingDisplayData()
            let gpuDrain = MPVMetalSampleBufferReadinessHandler { [weak self] in
                if let context {
                    mpv_render_context_free(context)
                    self?.renderContext = nil
                }
                if let handle {
                    mpv_terminate_destroy(handle)
                }
                if let renderUserdata {
                    Unmanaged<MPVMetalSampleBufferCallbackToken>.fromOpaque(renderUserdata).release()
                }
                guard let self else {
                    DispatchQueue.main.async {
                        displayLayer.controlTimebase = nil
                        displayLayer.flushAndRemoveImage()
                    }
                    return
                }
                self.pendingDisplayFlush = nil
                self.pendingDisplayRecoveryFrame = nil
                self.displayRecoveryProbeGeneration = nil
                self.displayRecoveryGate.cancel()
                self.finishesStopAfterDisplayFlush = true
                _ = self.flushCoordinator.beginEpoch()
                self.requestDisplayFlush(
                    removingDisplayedImage: true,
                    loadGeneration: stoppingLoadGeneration,
                    pendingSample: nil
                )
            }
            gpuConversionGroup.notify(queue: renderQueue) { gpuDrain() }
        }
        eventQueueGroup.notify(queue: renderQueue) { eventDrain() }
    }

    public func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            performOnMain {
                if !self.isStopping, self.mpv == nil, self.renderContext == nil {
                    continuation.resume()
                } else {
                    self.stopContinuations.append(continuation)
                }
            }
        }
    }

    /// Waits for timeline mutations already submitted by seek/pause/rate calls to reach the serial
    /// render queue. When `requiringCurrentFrame` is true, success additionally requires a sample
    /// from that exact load and presentation epoch after its flush/timebase update. Replacement or
    /// stop resolves false; an old frame can never satisfy a newer seek.
    public func waitForTimelineUpdate(requiringCurrentFrame: Bool = false) async -> Bool {
        let lifecycle = renderLifecycleFence.snapshot()
        return await withCheckedContinuation { continuation in
            enqueueRenderWork { [weak self] in
                guard let self,
                      self.renderLifecycleFence.accepts(
                        engineGeneration: lifecycle.engineGeneration,
                        loadGeneration: lifecycle.loadGeneration
                      ) else {
                    continuation.resume(returning: false)
                    return
                }
                guard requiringCurrentFrame else {
                    continuation.resume(returning: true)
                    return
                }
                let epoch = self.sampleTimeline.epoch
                if self.sampleTimeline.lastEnqueuedPTS != nil,
                   !self.sampleTimeline.needsFlush {
                    continuation.resume(returning: true)
                } else {
                    self.timelineWaiters.append(MPVMetalSampleBufferTimelineWaiter(
                        engineGeneration: lifecycle.engineGeneration,
                        loadGeneration: lifecycle.loadGeneration,
                        timelineEpoch: epoch,
                        continuation: continuation
                    ))
                }
            }
        }
    }

    private func cancelTimelineWaiters(loadGeneration: UInt64? = nil) {
        var remaining: [MPVMetalSampleBufferTimelineWaiter] = []
        for waiter in timelineWaiters {
            if loadGeneration == nil || waiter.loadGeneration == loadGeneration {
                waiter.continuation.resume(returning: false)
            } else {
                remaining.append(waiter)
            }
        }
        timelineWaiters = remaining
    }

    private func retargetTimelineWaiters(loadGeneration: UInt64, timelineEpoch: UInt64) {
        timelineWaiters = timelineWaiters.map { waiter in
            guard waiter.loadGeneration == loadGeneration else { return waiter }
            return MPVMetalSampleBufferTimelineWaiter(
                engineGeneration: waiter.engineGeneration,
                loadGeneration: loadGeneration,
                timelineEpoch: timelineEpoch,
                continuation: waiter.continuation
            )
        }
    }

    private func completeTimelineWaiters(
        engineGeneration: UInt64,
        loadGeneration: UInt64,
        timelineEpoch: UInt64
    ) {
        for waiter in timelineWaiters {
            waiter.continuation.resume(returning:
                waiter.engineGeneration == engineGeneration
                    && waiter.loadGeneration == loadGeneration
                    && waiter.timelineEpoch <= timelineEpoch
            )
        }
        timelineWaiters.removeAll(keepingCapacity: false)
    }

    private func finishStopping(renderDiagnostics: MPVMetalSampleBufferRenderDiagnosticsSnapshot) {
        publishedRenderDiagnostics = renderDiagnostics
        videoSize = .zero
        cachedPosition = 0
        cachedDuration = 0
        isStopping = false
        updateRenderLifecycleFence()
        isFileLoaded = false
        isAwaitingCurrentFileLoaded = false
        loadIdentityTracker.reset()
        deferredLoadActions.cancel()
        pendingSeek = nil
        eventStaleGenerationDropCount = 0
        lastFrameDiagnosticsEmissionTime = nil
        cachedVideoPTS = nil
        cachedSourceFPS = nil
        cachedSpeed = 1
        isPausedForCache = false
        updateState(.stopped)
        let continuations = stopContinuations
        stopContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    public func load(_ url: URL, headers: [String: String]? = nil) {
        load(url, headers: headers, preservingDisplayedImage: false)
    }

    /// The compatibility PiP bridge uses this during an active shared-GPU failover so AVKit can
    /// keep presenting the last valid native frame until this renderer has a replacement sample.
    /// Normal loads remove the old image immediately.
    func load(
        _ url: URL,
        headers: [String: String]? = nil,
        preservingDisplayedImage: Bool
    ) {
        performOnMain {
            guard self.mpv != nil, !self.isStopping else { return }
            let subtitleBarrier = self.externalSubtitles.beginGeneration()
            self.pendingLoadSubmission?.cancel()
            self.pendingLoadSubmission = nil
            self.isFileLoaded = false
            self.pendingSeek = nil
            self.beginNewLoadGeneration(removingDisplayedImage: !preservingDisplayedImage)
            self.eventStaleGenerationDropCount = 0
            self.deferredLoadActions.beginGeneration(self.loadGeneration)
            self.isAwaitingCurrentFileLoaded = true
            self.lastFrameDiagnosticsEmissionTime = nil
            self.videoSize = .zero
            self.cachedPosition = 0
            self.cachedDuration = 0
            self.setDisplayLayerExtendedDynamicRange(enabled: false)
            self.updateState(.loading)
            let loadIdentity = self.loadIdentityTracker.reserve(clientGeneration: self.loadGeneration)
            if let subtitleBarrier {
                let engineGeneration = self.engineGeneration
                self.pendingLoadSubmission = Task { @MainActor [weak self] in
                    _ = await subtitleBarrier.value()
                    guard let self,
                          !Task.isCancelled,
                          !self.isStopping,
                          self.engineGeneration == engineGeneration,
                          self.loadIdentityTracker.isLatest(loadIdentity) else { return }
                    self.pendingLoadSubmission = nil
                    self.submitLoad(url, headers: headers, identity: loadIdentity)
                }
            } else {
                self.submitLoad(url, headers: headers, identity: loadIdentity)
            }
        }
    }

    private func submitLoad(_ url: URL, headers: [String: String]?, identity: MPVLoadIdentityTracker.Identity) {
        guard loadIdentityTracker.submit(identity) else { return }
        updateHTTPHeaders(headers)
        let target = url.isFileURL ? url.path : url.absoluteString
        let replacedPlaylistEntryID = currentPlaylistEntryID()
        let status = command(["loadfile", target, "replace"])
        if status < 0 {
            loadIdentityTracker.cancel(identity)
            deferredLoadActions.cancel()
            isAwaitingCurrentFileLoaded = false
            reportError("loadfile failed status=\(status)")
        } else {
            if let playlistEntryID = currentPlaylistEntryID(), playlistEntryID != replacedPlaylistEntryID {
                loadIdentityTracker.bind(playlistEntryID: playlistEntryID, to: identity)
            }
            requestForcedFrames(count: 2)
        }
    }

    public func play() {
        performOnMain {
            self.isPaused = false
            self.setFlagProperty("pause", false)
            self.updateState(.playing)
            self.updateTimelineRate()
            self.requestForcedFrames(count: 2)
        }
    }

    public func pause() {
        performOnMain {
            self.isPaused = true
            self.setFlagProperty("pause", true)
            self.updateState(.paused)
            self.updateTimelineRate()
            self.requestForcedFrames(count: 1)
        }
    }

    public func seek(to seconds: Double) {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        performOnMain {
            self.cachedPosition = clamped
            self.requestTimelineDiscontinuity(removingDisplayedImage: false)
            guard self.isFileLoaded else {
                // File not loaded yet (e.g. the PiP hand-off loads this instance then immediately
                // seeks to the live position). mpv drops absolute seeks issued before FILE_LOADED,
                // so defer and replay on load — otherwise playback (and the frames fed to PiP)
                // would start from 0 while the timestamps say `clamped`, jumping back once decoded.
                self.pendingSeek = clamped
                return
            }
            _ = self.command(["seek", "\(clamped)", "absolute+exact"])
            self.requestForcedFrames(count: 2)
        }
    }

    public func seek(by seconds: Double) {
        seek(to: cachedPosition + seconds)
    }

    @available(*, deprecated, message: "Use MPVGPUPlayerRenderer.preparePictureInPicture() async throws")
    public func primeFrames(reason: String = "manual", count: Int = 6) {
        primeCompatibilityFrames(reason: reason, count: count)
    }

    func primeCompatibilityFrames(reason: String, count: Int) {
        _ = reason
        performOnMain {
            self.capturePresentationGeometry()
            let accepted = self.legacyPrimeBudget.consume(requested: max(1, count))
            self.requestForcedFrames(count: accepted)
        }
    }

    public func updateOptions(_ newOptions: MPVMetalSampleBufferRendererOptions) {
        performOnMain {
            guard self.options != newOptions else { return }
            let previousOptions = self.options
            self.options = newOptions
            if previousOptions.allowsSoftwareDecoderFallback
                != newOptions.allowsSoftwareDecoderFallback {
                self.setStringProperty(
                    "hwdec-software-fallback",
                    newOptions.allowsSoftwareDecoderFallback ? "yes" : "no"
                )
            }
            self.enqueueRenderWork { [weak self] in
                guard let self else { return }
                self.renderOptions = newOptions
                let sizeOrCapacityChanged = previousOptions.maximumFrameSize != newOptions.maximumFrameSize
                    || previousOptions.maximumInFlightFrameCount != newOptions.maximumInFlightFrameCount
                let hdrChanged = previousOptions.prefersHDRPresentation != newOptions.prefersHDRPresentation
                    || previousOptions.prefersHighBitDepthRendering != newOptions.prefersHighBitDepthRendering

                if sizeOrCapacityChanged || hdrChanged {
                    // Pool/cache replacement is queued after every outstanding Metal completion.
                    // Existing command buffers retain their buffers and texture references until
                    // that point, so a Stage Manager resize cannot invalidate an active encode.
                    self.gpuConversionGroup.notify(queue: self.renderQueue) { [weak self] in
                        guard let self else { return }
                        self.flushMetalTextureCache()
                        self.pixelBufferPool = nil
                        self.pixelBufferPoolAuxAttributes = nil
                        self.hdrPixelBufferPool = nil
                        self.hdrPixelBufferPoolAuxAttributes = nil
                        self.highBitDepthStagingPool = nil
                        self.formatDescription = nil
                        self.poolWidth = 0
                        self.poolHeight = 0
                        if hdrChanged {
                            self.hdrPresentationDisabled = false
                            self.highBitDepthRenderingDisabled = false
                            self.highBitDepthRenderingActive = false
                            self.formatDescriptionMetadataSignature = ""
                        }
                        self.requestForcedFrames(count: 2)
                    }
                } else {
                    self.requestForcedFrames(count: 1)
                }

                let extendedRangeEnabled = newOptions.prefersHDRPresentation && self.streamLooksHDR
                DispatchQueue.main.async { @MainActor [weak self] in
                    self?.setDisplayLayerExtendedDynamicRange(enabled: extendedRangeEnabled)
                }
            }
        }
    }

    public func setSpeed(_ speed: Double) {
        let clamped = speed.isFinite ? max(0.1, speed) : 1
        cachedSpeed = clamped
        setStringProperty("speed", "\(clamped)")
        updateTimelineRate()
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
        guard !deferLoadActionIfNeeded(.audioTrack(id)) else { return }
        applyAudioTrack(id)
    }

    /// Internal string form preserves mpv's `auto`/`no` values as well as numeric track IDs while
    /// the outer renderer temporarily suppresses its own video output.
    func setVideoTrackSelection(_ selection: String) {
        guard !deferLoadActionIfNeeded(.videoTrack(selection)) else { return }
        applyVideoTrackSelection(selection)
    }

    func currentVideoTrackSelection() -> String {
        getStringProperty("vid") ?? "auto"
    }

    public func setSubtitleTrack(id: Int) {
        externalSubtitles.select(externalSubtitles.selection(forTrackID: id))
    }

    public func disableSubtitles() {
        setSubtitleTrack(id: -1)
    }

    public func loadExternalSubtitles(urls: [String], names: [String]? = nil, selectFirst: Bool = true) {
        enqueueExternalSubtitles(MPVExternalSubtitleQueue.Batch(urls: urls, names: names, selectFirst: selectFirst))
    }

    func enqueueExternalSubtitles(_ batch: MPVExternalSubtitleQueue.Batch) {
        externalSubtitles.enqueue(batch)
    }

    func restoreSubtitleSelectionIntent(_ intent: MPVExternalSubtitleQueue.SelectionIntent?) {
        externalSubtitles.restoreSelectionIntent(intent)
    }

    public func applySubtitleStyle(_ style: MPVMetalSampleBufferSubtitleStyle) {
        guard !deferLoadActionIfNeeded(.subtitleStyle(style)) else { return }
        applySubtitleStyleImmediately(style)
    }

    private func deferLoadActionIfNeeded(_ action: MPVMetalSampleBufferDeferredLoadAction) -> Bool {
        guard isAwaitingCurrentFileLoaded else { return false }
        return deferredLoadActions.append(action, generation: loadGeneration)
    }

    private func applyDeferredLoadActions(generation: UInt64) {
        for action in deferredLoadActions.drain(generation: generation) {
            switch action {
            case .videoTrack(let selection):
                applyVideoTrackSelection(selection)
            case .audioTrack(let id):
                applyAudioTrack(id)
            case .subtitleStyle(let style):
                applySubtitleStyleImmediately(style)
            }
        }
    }

    private func applyAudioTrack(_ id: Int) {
        setStringProperty("aid", id < 0 ? "no" : "\(id)")
    }

    private func applyVideoTrackSelection(_ selection: String) {
        setStringProperty("vid", selection)
        requestPausedPresentationRefresh()
    }

    private func applySubtitleTrack(_ id: Int) {
        setStringProperty("sid", id < 0 ? "no" : "\(id)")
        requestPausedPresentationRefresh()
    }

    private func applySubtitleStyleImmediately(_ style: MPVMetalSampleBufferSubtitleStyle) {
        let fontSize = style.fontSize.isFinite ? max(1, Int(style.fontSize)) : 36
        let strokeWidth = style.strokeWidth.isFinite ? max(0, style.strokeWidth) : 0
        setStringProperty("sub-visibility", style.isVisible ? "yes" : "no")
        setStringProperty("sub-font-size", "\(fontSize)")
        setStringProperty("sub-border-size", "\(strokeWidth)")
        setStringProperty("sub-color", mpvColorString(style.foregroundColor))
        setStringProperty("sub-border-color", mpvColorString(style.strokeColor))
        requestPausedPresentationRefresh()
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

    private func submitAsyncCommand(_ args: [String]) -> MPVAsyncCommandReply {
        guard let handle = mpv, !isStopping, !args.isEmpty else {
            let reply = MPVAsyncCommandReply()
            reply.complete(-1)
            return reply
        }
        nextAsyncCommandRequestID &+= 1
        let requestID = nextAsyncCommandRequestID
        let generation = engineGeneration
        let reply = MPVAsyncCommandReply { [weak self] in
            guard let self,
                  self.engineGeneration == generation,
                  self.pendingAsyncCommandReplies[requestID] != nil,
                  let activeHandle = self.mpv else { return }
            mpv_abort_async_command(activeHandle, requestID)
        }
        pendingAsyncCommandReplies[requestID] = reply
        var cargs = args.map { UnsafePointer<CChar>(strdup($0)) }
        cargs.append(nil)
        let status = mpv_command_async(handle, requestID, &cargs)
        for pointer in cargs where pointer != nil {
            free(UnsafeMutablePointer(mutating: pointer))
        }
        if status < 0 {
            pendingAsyncCommandReplies.removeValue(forKey: requestID)?.complete(status)
        }
        return reply
    }

    public func diagnosticsSnapshot() -> MPVMetalSampleBufferRendererDiagnostics {
        let render = publishedRenderDiagnostics
        let statusName: String
        switch displayRenderingStatus {
        case .unknown: statusName = "unknown"
        case .rendering: statusName = "rendering"
        case .failed: statusName = "failed"
        @unknown default: statusName = "unknown"
        }
        return MPVMetalSampleBufferRendererDiagnostics(
            state: state,
            frameCount: render.frameCount,
            renderAttemptCount: render.renderAttemptCount,
            renderFailureCount: render.renderFailureCount,
            allocationFailureCount: render.allocationFailureCount,
            enqueueFailureCount: render.enqueueFailureCount,
            lastRenderStatus: render.lastRenderStatus,
            lastFrameSize: render.lastFrameSize,
            lastPresentationTime: render.lastPresentationTime,
            displayLayerStatus: statusName,
            displayLayerReadyForMoreMediaData: displayRendererReadyForMoreMediaData,
            metalCompatibilityProbeSucceeded: render.metalCompatibilityProbeSucceeded,
            presentationBackend: render.presentationBackend,
            metalPresentationFrameCount: render.metalPresentationFrameCount,
            metalPresentationFailureCount: render.metalPresentationFailureCount,
            pixelFormatDescription: render.pixelFormatDescription,
            sourcePixelFormatDescription: render.sourcePixelFormatDescription,
            highBitDepthRenderingActive: render.highBitDepthRenderingActive,
            highBitDepthRenderingFailureCount: render.highBitDepthRenderingFailureCount,
            hdrMetadataApplied: render.hdrMetadataApplied,
            videoColorPrimaries: render.videoColorPrimaries,
            videoTransferFunction: render.videoTransferFunction,
            videoSignalPeak: render.videoSignalPeak,
            renderAPI: "libmpv-\(MPV_RENDER_API_TYPE_SW):\(render.sourcePixelFormatDescription)",
            backendDescription: render.backendDescription,
            coalescedRenderRequestCount: render.coalescedRenderRequestCount,
            backpressureDropCount: render.backpressureDropCount,
            poolExhaustionDropCount: render.poolExhaustionDropCount,
            staleGenerationDropCount: render.staleGenerationDropCount + eventStaleGenerationDropCount,
            inFlightGPUFrameCount: render.inFlightGPUFrameCount,
            lastGPULatencyMilliseconds: render.lastGPULatencyMilliseconds,
            timelineEpoch: render.timelineEpoch,
            timelineRate: render.timelineRate
        )
    }

    private func makeRenderDiagnosticsSnapshot() -> MPVMetalSampleBufferRenderDiagnosticsSnapshot {
        MPVMetalSampleBufferRenderDiagnosticsSnapshot(
            frameCount: frameCount,
            renderAttemptCount: renderAttemptCount,
            renderFailureCount: renderFailureCount,
            allocationFailureCount: allocationFailureCount,
            enqueueFailureCount: enqueueFailureCount,
            lastRenderStatus: lastRenderStatus,
            lastFrameSize: lastFrameSize,
            lastPresentationTime: lastPresentationTime,
            metalCompatibilityProbeSucceeded: metalCompatibilityProbeSucceeded,
            presentationBackend: presentationBackend,
            metalPresentationFrameCount: metalPresentationFrameCount,
            metalPresentationFailureCount: metalPresentationFailureCount,
            pixelFormatDescription: lastPixelFormatDescription,
            sourcePixelFormatDescription: lastSourcePixelFormatDescription,
            highBitDepthRenderingActive: highBitDepthRenderingActive,
            highBitDepthRenderingFailureCount: highBitDepthRenderingFailureCount,
            hdrMetadataApplied: hdrMetadataApplied,
            videoColorPrimaries: videoColorPrimaries,
            videoTransferFunction: videoTransferFunction,
            videoSignalPeak: videoSignalPeak,
            backendDescription: backendDescription(),
            coalescedRenderRequestCount: demandScheduler.coalescedRequestCount,
            backpressureDropCount: demandScheduler.backpressureCount,
            poolExhaustionDropCount: poolExhaustionDropCount,
            staleGenerationDropCount: staleGenerationDropCount,
            inFlightGPUFrameCount: demandScheduler.inFlightCount,
            lastGPULatencyMilliseconds: lastGPULatencyMilliseconds,
            timelineEpoch: sampleTimeline.epoch,
            timelineRate: sampleTimeline.effectiveRate
        )
    }

    private func publishRenderDiagnostics(
        engineGeneration: UInt64,
        loadGeneration: UInt64
    ) {
        let snapshot = makeRenderDiagnosticsSnapshot()
        DispatchQueue.main.async { @MainActor [weak self] in
            guard let self,
                  self.renderLifecycleFence.accepts(
                    engineGeneration: engineGeneration,
                    loadGeneration: loadGeneration
                  ) else { return }
            self.publishedRenderDiagnostics = snapshot
        }
    }

    private func configureDisplayLayer() {
        displayLayer.videoGravity = .resizeAspect
        #if os(macOS)
        displayLayer.backgroundColor = NSColor.black.cgColor
        #else
        displayLayer.backgroundColor = UIColor.black.cgColor
        #endif
        displayLayer.isOpaque = true
        applyDisplayLayerDynamicRangePreference()
    }

    private var displayRenderingStatus: AVQueuedSampleBufferRenderingStatus {
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            return displayLayer.sampleBufferRenderer.status
        }
        return displayLayer.status
    }

    private var displayRendererIsFailed: Bool {
        displayRenderingStatus == .failed
    }

    private var displayRendererFailureDescription: String {
        let error: NSError?
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            error = displayLayer.sampleBufferRenderer.error.map { $0 as NSError }
        } else {
            error = displayLayer.error.map { $0 as NSError }
        }
        let detail = error.map { "\($0.domain)#\($0.code)" } ?? "unknown error"
        return "sample-buffer renderer remained failed after recovery flush (\(detail))"
    }

    private var displayRendererReadyForMoreMediaData: Bool {
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            return displayLayer.sampleBufferRenderer.isReadyForMoreMediaData
        }
        return displayLayer.isReadyForMoreMediaData
    }

    private func retainLatestDisplayRecoveryFrame(
        _ frame: MPVMetalSampleBufferPendingRecoveryFrame
    ) {
        if pendingDisplayRecoveryFrame != nil {
            staleGenerationDropCount += 1
        }
        pendingDisplayRecoveryFrame = MPVMetalSampleBufferPendingRecoveryFrame(
            pixelBuffer: frame.pixelBuffer,
            forceSDR: frame.forceSDR,
            loadGeneration: frame.loadGeneration,
            timelineEpoch: sampleTimeline.epoch
        )
    }

    /// Returns true while rendering must stay parked for a failed renderer or a serialized
    /// recovery flush. The one post-flush probe is carried through to sample enqueue so no second
    /// allocation/render can start before `.rendering` proves recovery.
    private func recoverDisplayRendererIfNeeded(
        loadGeneration: UInt64,
        retaining frame: MPVMetalSampleBufferPendingRecoveryFrame? = nil
    ) -> Bool {
        guard renderLifecycleFence.accepts(loadGeneration: loadGeneration) else { return true }

        if displayRenderingStatus == .rendering,
           displayRecoveryGate.markRenderingSucceeded(generation: loadGeneration) {
            displayRecoveryProbeGeneration = nil
        }

        if displayRendererIsFailed {
            switch displayRecoveryGate.observeFailure(generation: loadGeneration) {
            case .recover:
                scheduledRenderWorkItem?.cancel()
                scheduledRenderWorkItem = nil
                demandScheduler.cancelScheduledWork()
                if demandScheduler.isWaitingForReadiness {
                    _ = demandScheduler.becomeReady(generation: loadGeneration)
                }
                stopRequestingDisplayData()
                if lastPixelFormatType == kCVPixelFormatType_64RGBAHalf {
                    hdrPresentationDisabled = true
                }
                sampleTimeline.beginDiscontinuity()
                retargetTimelineWaiters(
                    loadGeneration: loadGeneration,
                    timelineEpoch: sampleTimeline.epoch
                )
                timelineIsAnchored = false
                allowsPausedDuplicateFrame = true
                _ = flushCoordinator.beginEpoch()
                if let frame {
                    retainLatestDisplayRecoveryFrame(frame)
                }
                requestDisplayFlush(
                    removingDisplayedImage: false,
                    loadGeneration: loadGeneration,
                    pendingSample: nil,
                    recoversDisplayRenderer: true
                )
            case .wait:
                if let frame {
                    retainLatestDisplayRecoveryFrame(frame)
                }
            case .report:
                pendingDisplayRecoveryFrame = nil
                displayRecoveryProbeGeneration = nil
                reportError(displayRendererFailureDescription)
            case .terminal, .stale:
                break
            }
            return true
        }

        if displayRecoveryProbeGeneration == loadGeneration {
            return false
        }
        if displayRecoveryGate.beginRenderingProbe(generation: loadGeneration) {
            displayRecoveryProbeGeneration = loadGeneration
            return false
        }
        if displayRecoveryGate.blocksRendering(generation: loadGeneration) {
            if let frame {
                retainLatestDisplayRecoveryFrame(frame)
            }
            return true
        }
        return false
    }

    private func completeDisplayRendererRecoveryIfNeeded(
        request: MPVMetalSampleBufferDisplayFlushRequest
    ) -> String? {
        guard request.recoversDisplayRenderer,
              let recoveryTimelineEpoch = request.recoveryTimelineEpoch else { return nil }
        switch displayRecoveryGate.complete(
            generation: request.loadGeneration,
            rendererRemainsFailed: displayRendererIsFailed
        ) {
        case .awaitingRendering:
            sampleTimeline.didFlush(epoch: recoveryTimelineEpoch)
            return nil
        case .failed:
            return displayRendererFailureDescription
        case .stale:
            return nil
        }
    }

    private func applyDisplayLayerDynamicRangePreference() {
        setDisplayLayerExtendedDynamicRange(enabled: options.prefersHDRPresentation && streamLooksHDR)
    }

    private func setDisplayLayerExtendedDynamicRange(enabled: Bool) {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            displayLayer.wantsExtendedDynamicRangeContent = enabled
        }
        #endif
    }

    private func flushMetalTextureCache() {
        if let metalTextureCache {
            CVMetalTextureCacheFlush(metalTextureCache, 0)
        }
    }

    private func createRenderContext(handle: OpaquePointer, engineGeneration: UInt64) -> Int32 {
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
            let token = MPVMetalSampleBufferCallbackToken(
                renderer: self,
                engineGeneration: engineGeneration,
                kind: .render
            )
            let userdata = Unmanaged.passRetained(token).toOpaque()
            renderCallbackToken = token
            renderCallbackUserdata = userdata
            mpv_render_context_set_update_callback(context, { userdata in
                guard let userdata else { return }
                let token = Unmanaged<MPVMetalSampleBufferCallbackToken>.fromOpaque(userdata).takeUnretainedValue()
                token.signal()
            }, userdata)
        }
        return status
    }

    private func observeProperties(handle: OpaquePointer) {
        let properties: [(String, mpv_format)] = [
            ("dwidth", MPV_FORMAT_INT64),
            ("dheight", MPV_FORMAT_INT64),
            ("duration", MPV_FORMAT_DOUBLE),
            ("time-pos", MPV_FORMAT_DOUBLE),
            ("video-pts", MPV_FORMAT_DOUBLE),
            ("estimated-vf-fps", MPV_FORMAT_DOUBLE),
            ("speed", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG),
            ("track-list", MPV_FORMAT_NONE),
            ("sid", MPV_FORMAT_NONE),
            ("aid", MPV_FORMAT_NONE),
            ("video-params/primaries", MPV_FORMAT_STRING),
            ("video-params/gamma", MPV_FORMAT_STRING),
            ("video-params/colormatrix", MPV_FORMAT_STRING),
            ("video-params/sig-peak", MPV_FORMAT_DOUBLE)
        ]
        for (name, format) in properties {
            _ = name.withCString { mpv_observe_property(handle, 0, $0, format) }
        }
    }

    private func startEventLoop(handle: OpaquePointer, engineGeneration: UInt64) {
        let token = MPVMetalSampleBufferCallbackToken(
            renderer: self,
            engineGeneration: engineGeneration,
            kind: .events
        )
        eventCallbackToken = token
        let group = eventQueueGroup
        let handleAddress = UInt(bitPattern: handle)
        group.enter()
        eventQueue.async { [weak self, token] in
            defer { group.leave() }
            guard let handle = OpaquePointer(bitPattern: handleAddress) else { return }
            var activePlaylistEntryID: Int64?
            while token.active {
                guard let eventPointer = mpv_wait_event(handle, -1) else { break }
                guard token.active else { break }
                guard let event = copyMPVMetalSampleBufferEvent(
                    eventPointer.pointee,
                    activePlaylistEntryID: &activePlaylistEntryID
                ) else {
                    continue
                }
                DispatchQueue.main.async { @MainActor [weak self] in
                    self?.handle(event, engineGeneration: engineGeneration)
                }
                if case .shutdown = event { break }
            }
        }
    }

    private func handle(_ event: MPVMetalSampleBufferEvent, engineGeneration: UInt64) {
        guard !isStopping, self.engineGeneration == engineGeneration else { return }
        switch event {
        case .startFile(let playlistEntryID):
            guard let identity = loadIdentityTracker.didStart(playlistEntryID: playlistEntryID),
                  loadIdentityTracker.isLatest(identity),
                  identity.clientGeneration == loadGeneration else {
                eventStaleGenerationDropCount += 1
                return
            }
            updateState(.loading)
        case .fileLoaded(let playlistEntryID):
            guard eventBelongsToCurrentLoad(playlistEntryID) else {
                eventStaleGenerationDropCount += 1
                return
            }
            isFileLoaded = true
            let loadedGeneration = loadGeneration
            isAwaitingCurrentFileLoaded = false
            refreshVideoColorMetadataCoherently()
            applyDeferredLoadActions(generation: loadGeneration)
            externalSubtitles.setReady()
            if let pending = pendingSeek {
                self.pendingSeek = nil
                requestTimelineDiscontinuity(removingDisplayedImage: false)
                _ = command(["seek", "\(pending)", "absolute+exact"])
            }
            enqueueRenderWork { [weak self] in
                guard let self,
                      self.renderLifecycleFence.accepts(loadGeneration: loadedGeneration) else { return }
                self.renderIsFileLoaded = true
            }
            updateState(isPaused ? .paused : .playing)
            requestForcedFrames(count: 2)
        case .videoReconfigure(let playlistEntryID):
            guard eventBelongsToCurrentLoad(playlistEntryID) else {
                eventStaleGenerationDropCount += 1
                return
            }
            refreshVideoSize()
            refreshVideoColorMetadataCoherently()
            requestForcedFrames(count: 2)
        case .endFile(let playlistEntryID):
            _ = loadIdentityTracker.didEnd(playlistEntryID: playlistEntryID)
        case .propertyChange(let name, let value, let playlistEntryID):
            if !MPVLoadPropertyFence.shouldAccept(
                property: name,
                hasPlaylistEntryID: playlistEntryID != nil,
                awaitingFileLoaded: isAwaitingCurrentFileLoaded
            ) {
                eventStaleGenerationDropCount += 1
                return
            }
            guard eventBelongsToCurrentLoad(playlistEntryID, allowsUnscopedEvent: true) else {
                eventStaleGenerationDropCount += 1
                return
            }
            refreshProperty(named: name, value: value)
        case .logError(let message, let playlistEntryID):
            if let playlistEntryID {
                guard eventBelongsToCurrentLoad(playlistEntryID) else {
                    eventStaleGenerationDropCount += 1
                    return
                }
            } else if isAwaitingCurrentFileLoaded {
                eventStaleGenerationDropCount += 1
                return
            }
            onError?(message)
        case .commandReply(let requestID, let error):
            pendingAsyncCommandReplies.removeValue(forKey: requestID)?.complete(error)
        case .shutdown:
            stop()
        }
    }

    private func eventBelongsToCurrentLoad(
        _ playlistEntryID: Int64?,
        allowsUnscopedEvent: Bool = false
    ) -> Bool {
        guard let playlistEntryID else { return allowsUnscopedEvent }
        guard let identity = loadIdentityTracker.identity(forPlaylistEntryID: playlistEntryID) else {
            return false
        }
        return loadIdentityTracker.isLatest(identity) && identity.clientGeneration == loadGeneration
    }

    private func refreshProperty(named name: String, value: MPVMetalObservedPropertyValue) {
        switch name {
        case "dwidth":
            if case .int64(let width) = value, width > 0 {
                videoSize.width = CGFloat(width)
                publishVideoSizeToRenderQueue()
            }
        case "dheight":
            if case .int64(let height) = value, height > 0 {
                videoSize.height = CGFloat(height)
                publishVideoSizeToRenderQueue()
            }
        case "duration":
            if case .double(let duration) = value {
                cachedDuration = duration
            }
        case "time-pos":
            guard case .double(let position) = value else { return }
            cachedPosition = position
            let generation = loadGeneration
            enqueueRenderWork { [weak self] in
                guard let self,
                      self.renderLifecycleFence.accepts(loadGeneration: generation) else { return }
                self.renderPosition = position
            }
        case "video-pts":
            if case .double(let videoPTS) = value, videoPTS.isFinite {
                cachedVideoPTS = videoPTS
                let generation = loadGeneration
                enqueueRenderWork { [weak self] in
                    guard let self,
                          self.renderLifecycleFence.accepts(loadGeneration: generation) else { return }
                    self.renderVideoPTS = videoPTS
                }
            } else if case .unavailable = value {
                cachedVideoPTS = nil
            }
        case "estimated-vf-fps":
            let generation = loadGeneration
            if case .double(let sourceFPS) = value, sourceFPS.isFinite, sourceFPS > 0 {
                cachedSourceFPS = sourceFPS
                enqueueRenderWork { [weak self] in
                    guard let self,
                          self.renderLifecycleFence.accepts(loadGeneration: generation) else { return }
                    self.renderSourceFPS = sourceFPS
                }
            } else {
                cachedSourceFPS = nil
                enqueueRenderWork { [weak self] in
                    guard let self,
                          self.renderLifecycleFence.accepts(loadGeneration: generation) else { return }
                    self.renderSourceFPS = nil
                }
            }
        case "speed":
            if case .double(let speed) = value, speed.isFinite {
                cachedSpeed = max(0.1, speed)
            }
            updateTimelineRate()
        case "pause":
            if case .flag(let paused) = value {
                isPaused = paused
            }
            if !isAwaitingCurrentFileLoaded {
                updateState(isPaused ? .paused : .playing)
            }
            updateTimelineRate()
        case "paused-for-cache":
            if case .flag(let buffering) = value {
                isPausedForCache = buffering
            }
            if isPausedForCache {
                updateState(.loading)
            } else if !isAwaitingCurrentFileLoaded {
                updateState(isPaused ? .paused : .playing)
            }
            updateTimelineRate()
        case "track-list", "sid", "aid":
            requestForcedFrames(count: 1)
        case "video-params/primaries", "video-params/gamma", "video-params/colormatrix", "video-params/sig-peak":
            var didChange = false
            switch (name, value) {
            case ("video-params/primaries", .string(let primaries)):
                didChange = observedVideoColorPrimaries != primaries
                observedVideoColorPrimaries = primaries
            case ("video-params/gamma", .string(let transfer)):
                didChange = observedVideoTransferFunction != transfer
                observedVideoTransferFunction = transfer
            case ("video-params/colormatrix", .string(let matrix)):
                didChange = observedVideoYCbCrMatrix != matrix
                observedVideoYCbCrMatrix = matrix
            case ("video-params/sig-peak", .double(let signalPeak)):
                didChange = observedVideoSignalPeak != signalPeak
                observedVideoSignalPeak = signalPeak
            case ("video-params/primaries", .unavailable):
                didChange = !observedVideoColorPrimaries.isEmpty
                observedVideoColorPrimaries = ""
            case ("video-params/gamma", .unavailable):
                didChange = !observedVideoTransferFunction.isEmpty
                observedVideoTransferFunction = ""
            case ("video-params/colormatrix", .unavailable):
                didChange = !observedVideoYCbCrMatrix.isEmpty
                observedVideoYCbCrMatrix = ""
            case ("video-params/sig-peak", .unavailable):
                didChange = observedVideoSignalPeak != 0
                observedVideoSignalPeak = 0
            default:
                break
            }
            if didChange {
                scheduleVideoColorMetadataPublish()
            }
        default:
            break
        }
    }

    private func refreshVideoSize() {
        let width = getIntProperty("dwidth") ?? 0
        let height = getIntProperty("dheight") ?? 0
        if width > 0, height > 0 {
            videoSize = CGSize(width: width, height: height)
            publishVideoSizeToRenderQueue()
        }
    }

    private func publishVideoSizeToRenderQueue() {
        let size = videoSize
        guard size.width > 0, size.height > 0 else { return }
        let generation = loadGeneration
        enqueueRenderWork { [weak self] in
            guard let self,
                  self.renderLifecycleFence.accepts(loadGeneration: generation) else { return }
            self.renderVideoSize = size
        }
    }

    private func publishVideoColorMetadataToRenderQueue() {
        let generation = loadGeneration
        let primaries = observedVideoColorPrimaries
        let transfer = observedVideoTransferFunction
        let matrix = observedVideoYCbCrMatrix
        let signalPeak = observedVideoSignalPeak
        enqueueRenderWork { [weak self] in
            guard let self,
                  self.renderLifecycleFence.accepts(loadGeneration: generation) else { return }
            self.videoColorPrimaries = primaries
            self.videoTransferFunction = transfer
            self.videoYCbCrMatrix = matrix
            self.videoSignalPeak = signalPeak
            self.rebuildColorMetadataCache()
            self.formatDescription = nil
            self.formatDescriptionMetadataSignature = ""
            self.flushMetalTextureCache()
            let extendedRangeEnabled = self.renderOptions.prefersHDRPresentation && self.streamLooksHDR
            DispatchQueue.main.async { @MainActor [weak self] in
                guard let self,
                      !self.isStopping,
                      self.loadGeneration == generation else { return }
                self.setDisplayLayerExtendedDynamicRange(enabled: extendedRangeEnabled)
            }
        }
    }

    /// Property notifications for primaries, transfer, matrix, and signal peak are independent.
    /// Read a coherent snapshot at the two rare load/reconfigure boundaries, then coalesce any
    /// later dynamic metadata burst so the render queue never rebuilds a transient partial format.
    private func refreshVideoColorMetadataCoherently() {
        let hadPendingPublish = videoColorMetadataPublishWorkItem != nil
        videoColorMetadataPublishWorkItem?.cancel()
        videoColorMetadataPublishWorkItem = nil
        let primaries = getStringProperty("video-params/primaries") ?? ""
        let transfer = getStringProperty("video-params/gamma") ?? ""
        let matrix = getStringProperty("video-params/colormatrix") ?? ""
        let signalPeak = getDoubleProperty("video-params/sig-peak") ?? 0
        let didChange = observedVideoColorPrimaries != primaries
            || observedVideoTransferFunction != transfer
            || observedVideoYCbCrMatrix != matrix
            || observedVideoSignalPeak != signalPeak
        guard hadPendingPublish || didChange else { return }
        observedVideoColorPrimaries = primaries
        observedVideoTransferFunction = transfer
        observedVideoYCbCrMatrix = matrix
        observedVideoSignalPeak = signalPeak
        publishVideoColorMetadataToRenderQueue()
        requestTimelineDiscontinuity(removingDisplayedImage: false)
        requestForcedFrames(count: 1)
    }

    private func scheduleVideoColorMetadataPublish() {
        videoColorMetadataPublishWorkItem?.cancel()
        let expectedGeneration = loadGeneration
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      !self.isStopping,
                      self.loadGeneration == expectedGeneration else { return }
                self.videoColorMetadataPublishWorkItem = nil
                self.publishVideoColorMetadataToRenderQueue()
                self.requestTimelineDiscontinuity(removingDisplayedImage: false)
                self.requestForcedFrames(count: 1)
            }
        }
        videoColorMetadataPublishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10), execute: workItem)
    }

    fileprivate func scheduleRender(force: Bool, engineGeneration: UInt64) {
        enqueueRenderWork { [weak self] in
            guard let self else { return }
            let lifecycle = self.renderLifecycleFence.snapshot()
            guard lifecycle.isRunning,
                  !lifecycle.isStopping,
                  lifecycle.engineGeneration == engineGeneration else { return }
            let loadGeneration = lifecycle.loadGeneration
            if self.demandScheduler.request(
                forcedCount: force ? 1 : 0,
                generation: loadGeneration
            ) {
                self.schedulePendingRenderIfNeeded(
                    engineGeneration: engineGeneration,
                    loadGeneration: loadGeneration
                )
            }
        }
    }

    private func requestForcedFrames(count: Int) {
        let boundedCount = min(2, max(0, count))
        guard boundedCount > 0 else { return }
        let lifecycle = renderLifecycleFence.snapshot()
        enqueueRenderWork { [weak self] in
            guard let self,
                  self.renderLifecycleFence.accepts(
                    engineGeneration: lifecycle.engineGeneration,
                    loadGeneration: lifecycle.loadGeneration
                  ) else { return }
            let loadGeneration = lifecycle.loadGeneration
            if self.demandScheduler.request(forcedCount: boundedCount, generation: loadGeneration) {
                self.schedulePendingRenderIfNeeded(
                    engineGeneration: lifecycle.engineGeneration,
                    loadGeneration: loadGeneration
                )
            }
        }
    }

    private func schedulePendingRenderIfNeeded(engineGeneration: UInt64, loadGeneration: UInt64) {
        guard scheduledRenderWorkItem == nil,
              !flushInFlight,
              demandScheduler.canSchedule,
              demandScheduler.markWorkScheduled(generation: loadGeneration) else { return }

        let configuredFPS = Double(max(1, min(renderOptions.preferredFramesPerSecond, renderOptions.preferredPiPFramesPerSecond)))
        let effectiveFPS = renderSourceFPS.map { min(configuredFPS, max(1, $0)) } ?? configuredFPS
        let interval = 1.0 / effectiveFPS
        let delay = max(
            0,
            demandScheduler.lastWorkTime + interval - ProcessInfo.processInfo.systemUptime
        )
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.scheduledRenderWorkItem === workItem {
                self.scheduledRenderWorkItem = nil
            }
            self.processRenderDemand(
                engineGeneration: engineGeneration,
                loadGeneration: loadGeneration
            )
        }
        scheduledRenderWorkItem = workItem
        renderQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func processRenderDemand(engineGeneration: UInt64, loadGeneration: UInt64) {
        guard renderLifecycleFence.accepts(
            engineGeneration: engineGeneration,
            loadGeneration: loadGeneration
        ) else {
            staleGenerationDropCount += 1
            demandScheduler.cancelScheduledWork()
            return
        }
        guard demandScheduler.inFlightCount == 0, !flushInFlight else {
            demandScheduler.cancelScheduledWork()
            return
        }
        if recoverDisplayRendererIfNeeded(loadGeneration: loadGeneration) {
            demandScheduler.cancelScheduledWork()
            return
        }
        guard displayRendererReadyForMoreMediaData else {
            demandScheduler.waitForReadiness(generation: loadGeneration)
            armDisplayReadinessCallback(engineGeneration: engineGeneration, loadGeneration: loadGeneration)
            return
        }

        guard let demand = demandScheduler.consume(
            at: ProcessInfo.processInfo.systemUptime,
            generation: loadGeneration
        ) else { return }
        renderFrame(force: demand.isForced, loadGeneration: loadGeneration)
        if demandScheduler.canSchedule {
            schedulePendingRenderIfNeeded(engineGeneration: engineGeneration, loadGeneration: loadGeneration)
        }
    }

    private func armDisplayReadinessCallback(engineGeneration: UInt64, loadGeneration: UInt64) {
        guard demandScheduler.isWaitingForReadiness else { return }
        let readinessHandler = MPVMetalSampleBufferReadinessHandler { [weak self] in
            guard let self else { return }
            guard self.demandScheduler.isWaitingForReadiness else { return }
            if self.recoverDisplayRendererIfNeeded(loadGeneration: loadGeneration) {
                return
            }
            guard self.displayRendererReadyForMoreMediaData else { return }
            self.stopRequestingDisplayData()
            guard self.renderLifecycleFence.accepts(
                engineGeneration: engineGeneration,
                loadGeneration: loadGeneration
            ) else {
                self.staleGenerationDropCount += 1
                return
            }
            if self.demandScheduler.becomeReady(generation: loadGeneration) {
                if let recoveryFrame = self.pendingDisplayRecoveryFrame,
                   recoveryFrame.loadGeneration == loadGeneration,
                   recoveryFrame.timelineEpoch == self.sampleTimeline.epoch {
                    self.pendingDisplayRecoveryFrame = nil
                    _ = self.enqueue(
                        buffer: recoveryFrame.pixelBuffer,
                        forceSDR: recoveryFrame.forceSDR,
                        loadGeneration: loadGeneration
                    )
                    return
                }
                self.schedulePendingRenderIfNeeded(
                    engineGeneration: engineGeneration,
                    loadGeneration: loadGeneration
                )
            }
        }
        let callback: @Sendable () -> Void = { readinessHandler() }
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            displayLayer.sampleBufferRenderer.requestMediaDataWhenReady(on: renderQueue, using: callback)
        } else {
            displayLayer.requestMediaDataWhenReady(on: renderQueue, using: callback)
        }
    }

    private func stopRequestingDisplayData() {
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            displayLayer.sampleBufferRenderer.stopRequestingMediaData()
        } else {
            displayLayer.stopRequestingMediaData()
        }
    }

    private func beginNewLoadGeneration(removingDisplayedImage: Bool = true) {
        loadGeneration &+= 1
        videoColorMetadataPublishWorkItem?.cancel()
        videoColorMetadataPublishWorkItem = nil
        updateRenderLifecycleFence()
        legacyPrimeBudget.reset()
        cachedVideoPTS = nil
        cachedSourceFPS = nil
        observedVideoColorPrimaries = ""
        observedVideoTransferFunction = ""
        observedVideoYCbCrMatrix = ""
        observedVideoSignalPeak = 0
        let generation = loadGeneration
        let engineGeneration = self.engineGeneration
        let initialSpeed = cachedSpeed
        let initiallyPaused = isPaused
        let initiallyBuffering = isPausedForCache
        enqueueRenderWork { [weak self] in
            guard let self,
                  self.renderLifecycleFence.accepts(
                    engineGeneration: engineGeneration,
                    loadGeneration: generation
                  ) else {
                self?.staleGenerationDropCount += 1
                return
            }
            self.frameCount = 0
            self.renderAttemptCount = 0
            self.renderFailureCount = 0
            self.allocationFailureCount = 0
            self.enqueueFailureCount = 0
            self.metalPresentationFrameCount = 0
            self.metalPresentationFailureCount = 0
            self.highBitDepthRenderingFailureCount = 0
            self.lastPresentationTime = 0
            self.cancelTimelineWaiters()
            self.demandScheduler.beginGeneration(generation)
            self.displayRecoveryGate.beginGeneration(generation)
            self.pendingDisplayRecoveryFrame = nil
            self.displayRecoveryProbeGeneration = nil
            self.scheduledRenderWorkItem?.cancel()
            self.scheduledRenderWorkItem = nil
            self.stopRequestingDisplayData()
            self.highBitDepthStagingPool = nil
            self.renderVideoSize = .zero
            self.renderPosition = 0
            self.renderVideoPTS = nil
            self.renderSourceFPS = nil
            self.renderIsFileLoaded = false
            self.hasReceivedVideoFrameUpdate = false
            self.renderSpeed = initialSpeed
            self.renderIsPaused = initiallyPaused
            self.renderIsBuffering = initiallyBuffering
            self.videoColorPrimaries = ""
            self.videoTransferFunction = ""
            self.videoYCbCrMatrix = ""
            self.videoSignalPeak = 0
            self.rebuildColorMetadataCache()
            self.formatDescription = nil
            self.formatDescriptionMetadataSignature = ""
            self.sampleTimeline.beginDiscontinuity()
            self.timelineIsAnchored = false
            self.lastTimebaseDriftCheckTime = 0
            self.lastAppliedTimebaseRate = nil
            self.allowsPausedDuplicateFrame = false
            _ = self.flushCoordinator.beginEpoch()
            self.requestDisplayFlush(
                removingDisplayedImage: removingDisplayedImage,
                loadGeneration: generation,
                pendingSample: nil
            )
            self.publishRenderDiagnostics(
                engineGeneration: engineGeneration,
                loadGeneration: generation
            )
        }
    }

    private func requestTimelineDiscontinuity(removingDisplayedImage: Bool) {
        let loadGeneration = self.loadGeneration
        enqueueRenderWork { [weak self] in
            guard let self,
                  self.renderLifecycleFence.accepts(loadGeneration: loadGeneration) else { return }
            self.sampleTimeline.beginDiscontinuity()
            self.retargetTimelineWaiters(
                loadGeneration: loadGeneration,
                timelineEpoch: self.sampleTimeline.epoch
            )
            self.timelineIsAnchored = false
            _ = self.flushCoordinator.beginEpoch()
            if removingDisplayedImage {
                self.requestDisplayFlush(
                    removingDisplayedImage: true,
                    loadGeneration: loadGeneration,
                    pendingSample: nil
                )
            }
        }
    }

    private func requestPausedPresentationRefresh() {
        let shouldCreatePresentationEpoch = isPaused || isPausedForCache
        let generation = loadGeneration
        if shouldCreatePresentationEpoch {
            enqueueRenderWork { [weak self] in
                guard let self,
                      self.renderLifecycleFence.accepts(loadGeneration: generation) else { return }
                self.allowsPausedDuplicateFrame = true
                self.sampleTimeline.beginDiscontinuity()
                self.retargetTimelineWaiters(
                    loadGeneration: generation,
                    timelineEpoch: self.sampleTimeline.epoch
                )
                self.timelineIsAnchored = false
                _ = self.flushCoordinator.beginEpoch()
            }
        }
        requestForcedFrames(count: 2)
    }

    private func updateTimelineRate() {
        let generation = loadGeneration
        let paused = isPaused
        let buffering = isPausedForCache
        let speed = cachedSpeed
        let rate = (paused || buffering) ? 0 : speed
        enqueueRenderWork { [weak self] in
            guard let self,
                  self.renderLifecycleFence.accepts(loadGeneration: generation) else { return }
            self.renderIsPaused = paused
            self.renderIsBuffering = buffering
            self.renderSpeed = speed
            self.sampleTimeline.updatePlayback(
                paused: paused,
                buffering: buffering,
                rate: speed
            )
            if let timebase = self.displayLayer.controlTimebase {
                self.applyTimebaseRateIfNeeded(timebase, rate: rate)
            }
        }
    }

    private func capturePresentationGeometry() {
        let bounds = displayLayer.bounds
        let scale = presentationScale
        enqueueRenderWork { [weak self] in
            self?.displayBoundsSnapshot = bounds
            self?.presentationScaleSnapshot = scale
        }
    }

    private func renderFrame(force: Bool, loadGeneration: UInt64) {
        guard renderLifecycleFence.accepts(loadGeneration: loadGeneration),
              let context = renderContext,
              renderIsFileLoaded else { return }
        if recoverDisplayRendererIfNeeded(loadGeneration: loadGeneration) {
            _ = demandScheduler.request(
                forcedCount: force ? 1 : 0,
                generation: loadGeneration
            )
            return
        }

        let updateFlags = UInt32(mpv_render_context_update(context))
        let hasFrame = updateFlags & MPV_RENDER_UPDATE_FRAME.rawValue != 0
        if hasFrame {
            hasReceivedVideoFrameUpdate = true
        }
        guard hasFrame || (force && hasReceivedVideoFrameUpdate) else { return }

        guard let targetSize = currentTargetSize() else { return }
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        guard width > 0, height > 0 else { return }

        renderAttemptCount += 1
        lastFrameSize = targetSize
        if poolWidth != width || poolHeight != height {
            recreatePixelBufferPool(width: width, height: height)
        }

        if shouldUseHighBitDepthRendering,
           renderHighBitDepthFrame(context: context, width: width, height: height, loadGeneration: loadGeneration) {
            return
        }

        renderBGRAFrame(context: context, width: width, height: height, loadGeneration: loadGeneration)
    }

    private func renderBGRAFrame(context: OpaquePointer, width: Int, height: Int, loadGeneration: UInt64) {
        guard let buffer = makePixelBuffer(width: width, height: height) else {
            allocationFailureCount += 1
            return
        }

        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else {
            allocationFailureCount += 1
            reportError("pixel buffer lock failed status=\(lockStatus)")
            return
        }
        let result: Int32
        if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            var size = [Int32(width), Int32(height)]
            var stride = CVPixelBufferGetBytesPerRow(buffer)
            result = size.withUnsafeMutableBufferPointer { sizePointer in
                swFormat.withUnsafeMutableBufferPointer { formatPointer in
                    withUnsafeMutablePointer(to: &stride) { stridePointer in
                        var params = [
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePointer.baseAddress)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(formatPointer.baseAddress)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePointer)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: baseAddress),
                            mpv_render_param()
                        ]
                        return params.withUnsafeMutableBufferPointer { buffer -> Int32 in
                            guard let baseAddress = buffer.baseAddress else { return -1 }
                            return mpv_render_context_render(context, baseAddress)
                        }
                    }
                }
            }
        } else {
            result = -1
        }
        if result >= 0, let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            normalizeOpaqueBGRAAlpha(
                baseAddress: baseAddress,
                width: width,
                height: height,
                rowBytes: CVPixelBufferGetBytesPerRow(buffer)
            )
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        lastRenderStatus = result
        guard result >= 0 else {
            renderFailureCount += 1
            reportError("sample-buffer render failed status=\(result)")
            return
        }
        guard renderLifecycleFence.accepts(loadGeneration: loadGeneration) else {
            staleGenerationDropCount += 1
            return
        }

        highBitDepthRenderingActive = false
        lastSourcePixelFormatDescription = "bgr0/BGRA8"
        probeMetalCompatibility(buffer: buffer, width: width, height: height)
        if shouldUseHDRPresentation,
           beginHDRMetalPresentation(
            from: buffer,
            width: width,
            height: height,
            loadGeneration: loadGeneration
           ) {
            return
        }
        presentationBackend = metalCompatibilityProbeSucceeded ? .metalIOSurface : .softwareIOSurface
        _ = enqueue(
            buffer: buffer,
            forceSDR: hdrPresentationDisabled,
            loadGeneration: loadGeneration
        )
    }

    private func renderHighBitDepthFrame(
        context: OpaquePointer,
        width: Int,
        height: Int,
        loadGeneration: UInt64
    ) -> Bool {
        guard renderOptions.prefersMetalPresentation,
              let cache = metalTextureCache,
              let commandQueue = metalCommandQueue else {
            return false
        }

        let bytesPerPixel = MemoryLayout<UInt16>.size * 4
        let stride = alignedBytesPerRow(width: width, bytesPerPixel: bytesPerPixel)
        let stagingPool: MPVHighBitDepthStagingPool
        if let existing = highBitDepthStagingPool,
           existing.matches(generation: loadGeneration, width: width, height: height, stride: stride) {
            stagingPool = existing
        } else {
            let replacement = MPVHighBitDepthStagingPool(
                generation: loadGeneration,
                width: width,
                height: height,
                stride: stride,
                capacity: renderOptions.maximumInFlightFrameCount
            )
            highBitDepthStagingPool = replacement
            stagingPool = replacement
        }
        guard let stagingLease = stagingPool.acquire() else {
            allocationFailureCount += 1
            highBitDepthRenderingFailureCount += 1
            poolExhaustionDropCount += 1
            return false
        }
        let baseAddress = stagingLease.pointer
        memset(baseAddress, 0, stagingLease.length)

        var result: Int32 = -1
        var size = [Int32(width), Int32(height)]
        var strideValue = stride
        result = size.withUnsafeMutableBufferPointer { sizePointer in
            highBitDepthSwFormat.withUnsafeMutableBufferPointer { formatPointer in
                withUnsafeMutablePointer(to: &strideValue) { stridePointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePointer.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(formatPointer.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: baseAddress),
                        mpv_render_param()
                    ]
                    return params.withUnsafeMutableBufferPointer { buffer -> Int32 in
                        guard let baseAddress = buffer.baseAddress else { return -1 }
                        return mpv_render_context_render(context, baseAddress)
                    }
                }
            }
        }
        lastRenderStatus = result
        guard result >= 0 else {
            stagingLease.release()
            highBitDepthRenderingDisabled = true
            highBitDepthRenderingActive = false
            highBitDepthRenderingFailureCount += 1
            reportError("sample-buffer rgba64 render failed status=\(result)")
            // `mpv_render_context_render` was already invoked for this demand. Preserve the last
            // displayed frame; the next natural VO update will use the SDR path.
            return true
        }
        guard renderLifecycleFence.accepts(loadGeneration: loadGeneration) else {
            stagingLease.release()
            staleGenerationDropCount += 1
            return true
        }

        guard beginHighBitDepthHDRPresentation(
            stagingLease: stagingLease,
            sourceStride: stride,
            width: width,
            height: height,
            cache: cache,
            commandQueue: commandQueue,
            loadGeneration: loadGeneration
        ) else {
            stagingLease.release()
            highBitDepthRenderingDisabled = true
            highBitDepthRenderingActive = false
            highBitDepthRenderingFailureCount += 1
            // The libmpv frame has already been rendered into the staging lease. Keep the last
            // valid presentation and let the next natural VO update use SDR.
            return true
        }

        highBitDepthRenderingActive = true
        lastSourcePixelFormatDescription = "rgba64/RGBA16"
        presentationBackend = .metalHighBitDepthHDRIOSurface
        return true
    }

    private func currentTargetSize() -> CGSize? {
        let source = renderVideoSize.width > 0 && renderVideoSize.height > 0
            ? renderVideoSize
            : CGSize(
                width: max(1, displayBoundsSnapshot.width * presentationScaleSnapshot),
                height: max(1, displayBoundsSnapshot.height * presentationScaleSnapshot)
            )
        guard source.width.isFinite, source.height.isFinite,
              source.width > 0, source.height > 0 else { return nil }
        let maxSize = renderOptions.maximumFrameSize
        guard maxSize.width.isFinite, maxSize.height.isFinite,
              maxSize.width > 0, maxSize.height > 0 else { return nil }
        let scale = min(maxSize.width / source.width, maxSize.height / source.height, 1.0)
        let requested = MPVPixelSize(
            width: max(1, floor(source.width * scale)),
            height: max(1, floor(source.height * scale))
        )
        let previous = poolWidth > 0 && poolHeight > 0
            ? MPVPixelSize(width: Double(poolWidth), height: Double(poolHeight))
            : nil
        let policy = MPVResizePolicy(
            maximumPixelCount: maximumOutputPixelCount,
            maximumDimension: maximumMetalTextureDimension
        )
        guard let resolved = policy.resolve(requested, previous: previous) else { return nil }
        return CGSize(width: resolved.width, height: resolved.height)
    }

    private var maximumOutputPixelCount: Double {
        #if os(macOS)
        return 14_745_600
        #else
        return 8_294_400
        #endif
    }

    private var maximumMetalTextureDimension: Double {
        guard let metalDevice else { return 4_096 }
        #if os(macOS)
        // The native macOS renderer is Apple Silicon-only. Its Metal devices support 16K
        // textures; the independent pixel cap still prevents oversized normal-video pools.
        _ = metalDevice
        return 16_384
        #else
        // Apple3 and newer support 16K 2D textures. Older iOS/tvOS GPUs are conservatively
        // limited to 8K; the separate pixel-count cap remains the tighter normal-video limit.
        return metalDevice.supportsFamily(.apple3) ? 16_384 : 8_192
        #endif
    }

    private var presentationScale: CGFloat {
        #if os(macOS)
        return displayLayer.delegate.flatMap { ($0 as? NSView)?.window?.backingScaleFactor }
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        #else
        displayLayer.delegate.flatMap { ($0 as? UIView)?.window?.screen.scale }
            ?? UIScreen.main.scale
        #endif
    }

    private func recreatePixelBufferPool(width: Int, height: Int) {
        flushMetalTextureCache()
        pixelBufferPool = nil
        pixelBufferPoolAuxAttributes = nil
        hdrPixelBufferPool = nil
        hdrPixelBufferPoolAuxAttributes = nil
        formatDescription = nil
        poolWidth = width
        poolHeight = height
        let standard = createPixelBufferPool(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        pixelBufferPool = standard.pool
        pixelBufferPoolAuxAttributes = standard.auxAttributes
        if standard.status != kCVReturnSuccess {
            reportError("pixel buffer pool creation failed status=\(standard.status)")
        }

        let hdr = createPixelBufferPool(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_64RGBAHalf
        )
        hdrPixelBufferPool = hdr.pool
        hdrPixelBufferPoolAuxAttributes = hdr.auxAttributes
    }

    private func createPixelBufferPool(
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) -> (pool: CVPixelBufferPool?, auxAttributes: CFDictionary?, status: CVReturn) {
        let attrs = pixelBufferAttributes(width: width, height: height, pixelFormat: pixelFormat)
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: renderOptions.maximumInFlightFrameCount
        ]
        let auxAttrs: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: renderOptions.maximumInFlightFrameCount
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        return (
            status == kCVReturnSuccess ? pool : nil,
            status == kCVReturnSuccess ? auxAttrs as CFDictionary : nil,
            status
        )
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let pool: CVPixelBufferPool?
        let auxAttributes: CFDictionary?
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            pool = pixelBufferPool
            auxAttributes = pixelBufferPoolAuxAttributes
        case kCVPixelFormatType_64RGBAHalf:
            pool = hdrPixelBufferPool
            auxAttributes = hdrPixelBufferPoolAuxAttributes
        default:
            pool = nil
            auxAttributes = nil
        }
        guard let pool else {
            poolExhaustionDropCount += 1
            return nil
        }
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            auxAttributes,
            &buffer
        )
        if status == kCVReturnSuccess, buffer != nil {
            return buffer
        }
        poolExhaustionDropCount += 1
        return nil
    }

    /// libmpv's `bgr0` software output leaves the fourth byte undefined. CoreVideo's 32BGRA
    /// format interprets that byte as alpha, and the iPad PiP compositor respects it. Normalize
    /// only that channel with Accelerate's vectorized in-place operation instead of a Swift
    /// per-pixel loop on every frame.
    private func normalizeOpaqueBGRAAlpha(
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        rowBytes: Int
    ) {
        var image = vImage_Buffer(
            data: baseAddress,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: rowBytes
        )
        let status = vImageOverwriteChannelsWithScalar_ARGB8888(
            255,
            &image,
            &image,
            0x1,
            vImage_Flags(kvImageDoNotTile)
        )
        if status != kvImageNoError {
            reportError("BGRA alpha normalization failed status=\(status)")
        }
    }

    private func pixelBufferAttributes(width: Int, height: Int, pixelFormat: OSType) -> [CFString: Any] {
        var attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!
        ]
        if pixelFormat == kCVPixelFormatType_32BGRA {
            attrs[kCVPixelBufferCGImageCompatibilityKey] = kCFBooleanTrue!
            attrs[kCVPixelBufferCGBitmapContextCompatibilityKey] = kCFBooleanTrue!
        }
        return attrs
    }

    private func probeMetalCompatibility(buffer: CVPixelBuffer, width: Int, height: Int) {
        guard renderOptions.createsMetalCompatibilityProbe,
              !metalCompatibilityProbeSucceeded,
              let cache = metalTextureCache,
              let textureFormat = metalTexturePixelFormat(for: CVPixelBufferGetPixelFormatType(buffer)) else { return }
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            buffer,
            nil,
            textureFormat,
            width,
            height,
            0,
            &texture
        )
        metalCompatibilityProbeSucceeded = status == kCVReturnSuccess && texture != nil
    }

    private func metalTexturePixelFormat(for pixelFormat: OSType) -> MTLPixelFormat? {
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            return .bgra8Unorm
        case kCVPixelFormatType_64RGBAHalf:
            return .rgba16Float
        default:
            return nil
        }
    }

    private func pixelFormatDescription(_ pixelFormat: OSType) -> String {
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            return "BGRA8"
        case kCVPixelFormatType_64RGBAHalf:
            return "RGBA16F"
        default:
            return "unknown(\(pixelFormat))"
        }
    }

    private func alignedBytesPerRow(width: Int, bytesPerPixel: Int, alignment: Int = 64) -> Int {
        let rowBytes = width * bytesPerPixel
        return ((rowBytes + alignment - 1) / alignment) * alignment
    }

    private var shouldUseHDRPresentation: Bool {
        renderOptions.prefersHDRPresentation && !hdrPresentationDisabled && streamLooksHDR
    }

    private var shouldUseHighBitDepthRendering: Bool {
        shouldUseHDRPresentation
            && renderOptions.prefersHighBitDepthRendering
            && !highBitDepthRenderingDisabled
            && renderOptions.prefersMetalPresentation
            && metalTextureCache != nil
            && metalCommandQueue != nil
    }

    private var streamLooksHDR: Bool {
        resolvedStreamLooksHDR
    }

    private func beginHDRMetalPresentation(
        from sourceBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        loadGeneration: UInt64
    ) -> Bool {
        guard demandScheduler.inFlightCount == 0,
              let cache = metalTextureCache,
              let commandQueue = metalCommandQueue else { return false }
        guard let pipeline = hdrConversionPipeline ?? makeHDRConversionPipeline(),
              let destinationBuffer = makePixelBuffer(
                width: width,
                height: height,
                pixelFormat: kCVPixelFormatType_64RGBAHalf
              ) else {
            metalPresentationFailureCount += 1
            hdrPresentationDisabled = true
            return false
        }
        hdrConversionPipeline = pipeline

        var sourceTextureRef: CVMetalTexture?
        var destinationTextureRef: CVMetalTexture?
        let sourceStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            sourceBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &sourceTextureRef
        )
        let destinationStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            destinationBuffer,
            nil,
            .rgba16Float,
            width,
            height,
            0,
            &destinationTextureRef
        )
        guard sourceStatus == kCVReturnSuccess,
              destinationStatus == kCVReturnSuccess,
              let sourceTextureRef,
              let destinationTextureRef,
              let sourceTexture = CVMetalTextureGetTexture(sourceTextureRef),
              let destinationTexture = CVMetalTextureGetTexture(destinationTextureRef),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            metalPresentationFailureCount += 1
            hdrPresentationDisabled = true
            return false
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(destinationTexture, index: 1)
        let threadsPerThreadgroup = MTLSize(width: 8, height: 8, depth: 1)
        let threadgroups = MTLSize(
            width: (width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
            height: (height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        let startedAt = ProcessInfo.processInfo.systemUptime
        guard demandScheduler.beginInFlight(generation: loadGeneration) else { return false }
        let group = gpuConversionGroup
        let resources = MPVMetalGPUCompletionResources(
            destinationBuffer: destinationBuffer,
            fallbackBuffer: sourceBuffer,
            retainedObjects: [sourceTextureRef, destinationTextureRef]
        )
        let finish = MPVMetalSampleBufferValueHandler<MPVMetalGPUCompletionPayload> { [weak self] payload in
            self?.finishGPUFrame(
                commandBuffer: payload.commandBuffer,
                destinationBuffer: payload.resources.destinationBuffer,
                fallbackBuffer: payload.resources.fallbackBuffer,
                loadGeneration: loadGeneration,
                startedAt: startedAt,
                highBitDepth: false
            )
            group.leave()
        }
        group.enter()
        commandBuffer.addCompletedHandler { [weak self, resources] completed in
            let payload = MPVMetalGPUCompletionPayload(
                commandBuffer: completed,
                resources: resources
            )
            guard let queue = self?.renderQueue else {
                group.leave()
                return
            }
            queue.async { finish(payload) }
        }
        commandBuffer.commit()
        return true
    }

    private func beginHighBitDepthHDRPresentation(
        stagingLease: MPVHighBitDepthStagingPool.Lease,
        sourceStride: Int,
        width: Int,
        height: Int,
        cache: CVMetalTextureCache,
        commandQueue: MTLCommandQueue,
        loadGeneration: UInt64
    ) -> Bool {
        guard demandScheduler.inFlightCount == 0,
              let pipeline = highBitDepthConversionPipeline ?? makeHighBitDepthConversionPipeline(),
              let sourceBuffer = metalDevice?.makeBuffer(
                bytesNoCopy: stagingLease.pointer,
                length: stagingLease.length,
                options: .storageModeShared,
                deallocator: nil
              ),
              let destinationBuffer = makePixelBuffer(
                width: width,
                height: height,
                pixelFormat: kCVPixelFormatType_64RGBAHalf
              ) else {
            metalPresentationFailureCount += 1
            return false
        }
        highBitDepthConversionPipeline = pipeline

        var destinationTextureRef: CVMetalTexture?
        let destinationStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            destinationBuffer,
            nil,
            .rgba16Float,
            width,
            height,
            0,
            &destinationTextureRef
        )
        var sourceStridePixels = UInt32(sourceStride / MemoryLayout<UInt16>.size / 4)
        guard destinationStatus == kCVReturnSuccess,
              let destinationTextureRef,
              let destinationTexture = CVMetalTextureGetTexture(destinationTextureRef),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            metalPresentationFailureCount += 1
            return false
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(sourceBuffer, offset: 0, index: 0)
        encoder.setBytes(&sourceStridePixels, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setTexture(destinationTexture, index: 0)
        let threadsPerThreadgroup = MTLSize(width: 8, height: 8, depth: 1)
        let threadgroups = MTLSize(
            width: (width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
            height: (height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        let startedAt = ProcessInfo.processInfo.systemUptime
        guard demandScheduler.beginInFlight(generation: loadGeneration) else { return false }
        let group = gpuConversionGroup
        let resources = MPVMetalGPUCompletionResources(
            destinationBuffer: destinationBuffer,
            fallbackBuffer: nil,
            retainedObjects: [sourceBuffer as AnyObject, destinationTextureRef]
        )
        let finish = MPVMetalSampleBufferValueHandler<MPVMetalGPUCompletionPayload> { [weak self, stagingLease] payload in
            self?.finishGPUFrame(
                commandBuffer: payload.commandBuffer,
                destinationBuffer: payload.resources.destinationBuffer,
                fallbackBuffer: nil,
                loadGeneration: loadGeneration,
                startedAt: startedAt,
                highBitDepth: true
            )
            stagingLease.release()
            group.leave()
        }
        group.enter()
        commandBuffer.addCompletedHandler { [weak self, resources, stagingLease] completed in
            let payload = MPVMetalGPUCompletionPayload(
                commandBuffer: completed,
                resources: resources
            )
            guard let queue = self?.renderQueue else {
                stagingLease.release()
                group.leave()
                return
            }
            queue.async { finish(payload) }
        }
        commandBuffer.commit()
        return true
    }

    private func finishGPUFrame(
        commandBuffer: MTLCommandBuffer,
        destinationBuffer: CVPixelBuffer,
        fallbackBuffer: CVPixelBuffer?,
        loadGeneration: UInt64,
        startedAt: TimeInterval,
        highBitDepth: Bool
    ) {
        let shouldScheduleCurrentGeneration = demandScheduler.finishInFlight(generation: loadGeneration)
        lastGPULatencyMilliseconds = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        let lifecycle = renderLifecycleFence.snapshot()
        guard lifecycle.isRunning,
              !lifecycle.isStopping,
              lifecycle.loadGeneration == loadGeneration else {
            staleGenerationDropCount += 1
            if shouldScheduleCurrentGeneration,
               lifecycle.isRunning,
               !lifecycle.isStopping {
                schedulePendingRenderIfNeeded(
                    engineGeneration: lifecycle.engineGeneration,
                    loadGeneration: lifecycle.loadGeneration
                )
            }
            return
        }

        if commandBuffer.status == .completed {
            presentationBackend = highBitDepth ? .metalHighBitDepthHDRIOSurface : .metalHDRIOSurface
            metalPresentationFrameCount += 1
            _ = enqueue(buffer: destinationBuffer, loadGeneration: loadGeneration)
        } else {
            metalPresentationFailureCount += 1
            hdrPresentationDisabled = true
            if highBitDepth {
                highBitDepthRenderingDisabled = true
                highBitDepthRenderingActive = false
                highBitDepthRenderingFailureCount += 1
            }
            reportError("Metal HDR conversion failed status=\(commandBuffer.status.rawValue)")
            if let fallbackBuffer {
                presentationBackend = .softwareIOSurface
                _ = enqueue(buffer: fallbackBuffer, forceSDR: true, loadGeneration: loadGeneration)
            }
        }
        schedulePendingRenderIfNeeded(
            engineGeneration: lifecycle.engineGeneration,
            loadGeneration: loadGeneration
        )
        publishRenderDiagnostics(
            engineGeneration: lifecycle.engineGeneration,
            loadGeneration: loadGeneration
        )
    }

    private func makeHDRConversionPipeline() -> MTLComputePipelineState? {
        guard let metalDevice else { return nil }
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void mpvkit_bgra8_to_rgba16f(
            texture2d<float, access::read> sourceTexture [[texture(0)]],
            texture2d<half, access::write> destinationTexture [[texture(1)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= destinationTexture.get_width() || gid.y >= destinationTexture.get_height()) {
                return;
            }
            float4 color = sourceTexture.read(gid);
            destinationTexture.write(half4(color), gid);
        }
        """
        do {
            let library = try metalDevice.makeLibrary(source: source, options: nil)
            guard let function = library.makeFunction(name: "mpvkit_bgra8_to_rgba16f") else {
                return nil
            }
            return try metalDevice.makeComputePipelineState(function: function)
        } catch {
            reportError("HDR Metal presentation pipeline failed: \(error)")
            return nil
        }
    }

    private func makeHighBitDepthConversionPipeline() -> MTLComputePipelineState? {
        guard let metalDevice else { return nil }
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void mpvkit_rgba64_to_rgba16f(
            const device ushort4 *sourcePixels [[buffer(0)]],
            constant uint &sourceStridePixels [[buffer(1)]],
            texture2d<half, access::write> destinationTexture [[texture(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= destinationTexture.get_width() || gid.y >= destinationTexture.get_height()) {
                return;
            }
            ushort4 rawColor = sourcePixels[gid.y * sourceStridePixels + gid.x];
            float4 color = float4(rawColor) / 65535.0;
            destinationTexture.write(half4(color), gid);
        }
        """
        do {
            let library = try metalDevice.makeLibrary(source: source, options: nil)
            guard let function = library.makeFunction(name: "mpvkit_rgba64_to_rgba16f") else {
                return nil
            }
            return try metalDevice.makeComputePipelineState(function: function)
        } catch {
            reportError("High-bit-depth HDR Metal presentation pipeline failed: \(error)")
            return nil
        }
    }

    private func backendDescription() -> String {
        switch presentationBackend {
        case .metalHighBitDepthHDRIOSurface:
            return "libmpv sample-buffer renderer with rgba64 source and Metal RGBA16F IOSurface HDR presentation"
        case .metalHDRIOSurface:
            return "libmpv sample-buffer renderer with HDR-capable Metal RGBA16F IOSurface presentation"
        case .metalIOSurface:
            return "libmpv sample-buffer renderer with Metal-backed IOSurface presentation"
        case .softwareIOSurface:
            return "libmpv sample-buffer renderer with software IOSurface presentation"
        }
    }

    @discardableResult
    private func enqueue(
        buffer: CVPixelBuffer,
        forceSDR: Bool = false,
        loadGeneration: UInt64
    ) -> Bool {
        let lifecycle = renderLifecycleFence.snapshot()
        guard lifecycle.isRunning,
              !lifecycle.isStopping,
              lifecycle.loadGeneration == loadGeneration else {
            staleGenerationDropCount += 1
            return false
        }
        let recoveryFrame = MPVMetalSampleBufferPendingRecoveryFrame(
            pixelBuffer: buffer,
            forceSDR: forceSDR,
            loadGeneration: loadGeneration,
            timelineEpoch: sampleTimeline.epoch
        )
        if recoverDisplayRendererIfNeeded(
            loadGeneration: loadGeneration,
            retaining: recoveryFrame
        ) {
            return true
        }
        guard displayRendererReadyForMoreMediaData else {
            if displayRecoveryProbeGeneration == loadGeneration {
                retainLatestDisplayRecoveryFrame(recoveryFrame)
            }
            demandScheduler.waitForReadiness(generation: loadGeneration)
            armDisplayReadinessCallback(
                engineGeneration: lifecycle.engineGeneration,
                loadGeneration: loadGeneration
            )
            return false
        }
        applyColorAttachments(to: buffer, forceSDR: forceSDR)
        let formatChanged = updateFormatDescriptionIfNeeded(for: buffer, forceSDR: forceSDR)
        guard let description = formatDescription else { return false }
        let timelineDecision = sampleTimeline.evaluate(
            pts: renderVideoPTS,
            fallbackPTS: renderPosition,
            allowsPausedRefresh: allowsPausedDuplicateFrame
        )
        guard case .enqueue(let mediaSeconds, let timelineEpoch, let timelineFlush, _) = timelineDecision else {
            return false
        }
        allowsPausedDuplicateFrame = false
        lastPresentationTime = mediaSeconds
        let presentationTime = CMTime(seconds: mediaSeconds, preferredTimescale: 1000)
        let frameDuration = CMTime(seconds: 1.0 / Double(max(1, renderOptions.preferredPiPFramesPerSecond)), preferredTimescale: 1000)
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
            if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_64RGBAHalf {
                hdrPresentationDisabled = true
            }
            reportError("sample buffer creation failed status=\(result)")
            return false
        }

        if formatChanged || timelineFlush {
            timelineIsAnchored = false
            requestDisplayFlush(
                removingDisplayedImage: true,
                loadGeneration: loadGeneration,
                pendingSample: MPVMetalSampleBufferPendingDisplaySample(
                    sampleBuffer: sampleBuffer,
                    pixelBuffer: buffer,
                    description: description,
                    presentationTime: presentationTime,
                    mediaSeconds: mediaSeconds,
                    timelineEpoch: timelineEpoch,
                    forceSDR: forceSDR
                )
            )
            return true
        }
        enqueuePrepared(
            sampleBuffer: sampleBuffer,
            pixelBuffer: buffer,
            description: description,
            presentationTime: presentationTime,
            mediaSeconds: mediaSeconds,
            timelineEpoch: timelineEpoch,
            forceSDR: forceSDR,
            loadGeneration: loadGeneration
        )
        return true
    }

    /// Serializes the physical AVSampleBufferDisplayLayer flush. A newer load/epoch replaces any
    /// queued request, while an already-running AVFoundation completion is allowed to finish before
    /// the replacement starts. No sample can be enqueued between those completions.
    private func requestDisplayFlush(
        removingDisplayedImage: Bool,
        loadGeneration: UInt64,
        pendingSample: MPVMetalSampleBufferPendingDisplaySample?,
        recoversDisplayRenderer: Bool = false
    ) {
        var request = MPVMetalSampleBufferDisplayFlushRequest(
            loadGeneration: loadGeneration,
            removingDisplayedImage: recoversDisplayRenderer ? false : removingDisplayedImage,
            pendingSample: recoversDisplayRenderer ? nil : pendingSample,
            recoversDisplayRenderer: recoversDisplayRenderer,
            recoveryTimelineEpoch: recoversDisplayRenderer ? sampleTimeline.epoch : nil
        )
        if flushInFlight {
            if let pending = pendingDisplayFlush,
               pending.loadGeneration == request.loadGeneration,
               (pending.recoversDisplayRenderer || request.recoversDisplayRenderer) {
                if pending.pendingSample != nil || request.pendingSample != nil {
                    staleGenerationDropCount += 1
                }
                request = MPVMetalSampleBufferDisplayFlushRequest(
                    loadGeneration: request.loadGeneration,
                    removingDisplayedImage: false,
                    pendingSample: nil,
                    recoversDisplayRenderer: true,
                    recoveryTimelineEpoch: request.recoveryTimelineEpoch
                        ?? pending.recoveryTimelineEpoch
                )
            } else if pendingDisplayFlush?.pendingSample != nil {
                staleGenerationDropCount += 1
            }
            pendingDisplayFlush = request
            return
        }
        startDisplayFlush(request)
    }

    private func startDisplayFlush(_ request: MPVMetalSampleBufferDisplayFlushRequest) {
        flushInFlight = true
        displayLayer.controlTimebase = nil
        lastAppliedTimebaseRate = nil
        lastTimebaseDriftCheckTime = 0
        let token = flushCoordinator.beginFlush()
        let renderQueue = self.renderQueue
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            let finish = MPVMetalSampleBufferReadinessHandler { [weak self] in
                self?.finishDisplayFlush(request, token: token)
            }
            displayLayer.sampleBufferRenderer.flush(
                removingDisplayedImage: request.removingDisplayedImage
            ) {
                renderQueue.async { finish() }
            }
            return
        }
        if request.removingDisplayedImage {
            displayLayer.flushAndRemoveImage()
        } else {
            displayLayer.flush()
        }
        finishDisplayFlush(request, token: token)
    }

    private func finishDisplayFlush(
        _ request: MPVMetalSampleBufferDisplayFlushRequest,
        token: MPVFlushEpochCoordinator.Token
    ) {
        let isCurrentEpoch = flushCoordinator.complete(token)
        if let failure = completeDisplayRendererRecoveryIfNeeded(request: request) {
            pendingDisplayFlush = nil
            pendingDisplayRecoveryFrame = nil
            displayRecoveryProbeGeneration = nil
            flushInFlight = false
            reportError(failure)
            return
        }
        if let replacement = pendingDisplayFlush {
            pendingDisplayFlush = nil
            if request.pendingSample != nil {
                staleGenerationDropCount += 1
            }
            startDisplayFlush(replacement)
            return
        }

        flushInFlight = false
        let lifecycle = renderLifecycleFence.snapshot()
        if isCurrentEpoch,
           request.loadGeneration == lifecycle.loadGeneration,
           let pendingSample = request.pendingSample,
           sampleTimeline.epoch == pendingSample.timelineEpoch,
           lifecycle.isRunning,
           !lifecycle.isStopping {
            enqueuePrepared(
                sampleBuffer: pendingSample.sampleBuffer,
                pixelBuffer: pendingSample.pixelBuffer,
                description: pendingSample.description,
                presentationTime: pendingSample.presentationTime,
                mediaSeconds: pendingSample.mediaSeconds,
                timelineEpoch: pendingSample.timelineEpoch,
                forceSDR: pendingSample.forceSDR,
                loadGeneration: request.loadGeneration
            )
        } else if request.pendingSample != nil {
            staleGenerationDropCount += 1
        }

        if finishesStopAfterDisplayFlush {
            finishesStopAfterDisplayFlush = false
            let renderDiagnostics = resetRenderStateAfterStop()
            DispatchQueue.main.async { @MainActor [weak self] in
                self?.finishStopping(renderDiagnostics: renderDiagnostics)
            }
            return
        }
        guard lifecycle.isRunning, !lifecycle.isStopping else { return }
        if let recoveryFrame = pendingDisplayRecoveryFrame {
            pendingDisplayRecoveryFrame = nil
            if recoveryFrame.loadGeneration == lifecycle.loadGeneration,
               recoveryFrame.timelineEpoch == sampleTimeline.epoch {
                _ = enqueue(
                    buffer: recoveryFrame.pixelBuffer,
                    forceSDR: recoveryFrame.forceSDR,
                    loadGeneration: recoveryFrame.loadGeneration
                )
            } else {
                staleGenerationDropCount += 1
            }
        }
        schedulePendingRenderIfNeeded(
            engineGeneration: lifecycle.engineGeneration,
            loadGeneration: lifecycle.loadGeneration
        )
    }

    /// Clears render-queue-owned resources only after event, render, GPU, and display work have
    /// drained. The immutable result is the sole state handed back to the main actor.
    private func resetRenderStateAfterStop() -> MPVMetalSampleBufferRenderDiagnosticsSnapshot {
        scheduledRenderWorkItem?.cancel()
        scheduledRenderWorkItem = nil
        _ = demandScheduler.beginGeneration()
        stopRequestingDisplayData()
        flushMetalTextureCache()
        pixelBufferPool = nil
        pixelBufferPoolAuxAttributes = nil
        hdrPixelBufferPool = nil
        hdrPixelBufferPoolAuxAttributes = nil
        formatDescription = nil
        poolWidth = 0
        poolHeight = 0
        hasReceivedVideoFrameUpdate = false
        frameCount = 0
        renderAttemptCount = 0
        renderFailureCount = 0
        allocationFailureCount = 0
        enqueueFailureCount = 0
        metalPresentationFrameCount = 0
        metalPresentationFailureCount = 0
        highBitDepthRenderingFailureCount = 0
        hdrPresentationDisabled = false
        formatDescriptionMetadataSignature = ""
        lastPixelFormatDescription = "BGRA8"
        lastSourcePixelFormatDescription = "bgr0/BGRA8"
        lastPixelFormatType = kCVPixelFormatType_32BGRA
        hdrMetadataApplied = false
        highBitDepthRenderingDisabled = false
        highBitDepthRenderingActive = false
        highBitDepthStagingPool = nil
        renderVideoPTS = nil
        renderSourceFPS = nil
        renderIsFileLoaded = false
        sampleTimeline = MPVSampleTimeline()
        cancelTimelineWaiters()
        _ = flushCoordinator.beginEpoch()
        timelineIsAnchored = false
        lastAppliedTimebaseRate = nil
        lastTimebaseDriftCheckTime = 0
        allowsPausedDuplicateFrame = false
        flushInFlight = false
        pendingDisplayFlush = nil
        pendingDisplayRecoveryFrame = nil
        displayRecoveryProbeGeneration = nil
        displayRecoveryGate.cancel()
        finishesStopAfterDisplayFlush = false
        return makeRenderDiagnosticsSnapshot()
    }

    private func enqueuePrepared(
        sampleBuffer: CMSampleBuffer,
        pixelBuffer: CVPixelBuffer,
        description: CMVideoFormatDescription,
        presentationTime: CMTime,
        mediaSeconds: Double,
        timelineEpoch: UInt64,
        forceSDR: Bool,
        loadGeneration: UInt64
    ) {
        let lifecycle = renderLifecycleFence.snapshot()
        guard lifecycle.isRunning,
              !lifecycle.isStopping,
              lifecycle.loadGeneration == loadGeneration else {
            staleGenerationDropCount += 1
            return
        }
        let recoveryFrame = MPVMetalSampleBufferPendingRecoveryFrame(
            pixelBuffer: pixelBuffer,
            forceSDR: forceSDR,
            loadGeneration: loadGeneration,
            timelineEpoch: timelineEpoch
        )
        if recoverDisplayRendererIfNeeded(
            loadGeneration: loadGeneration,
            retaining: recoveryFrame
        ) {
            return
        }
        guard displayRendererReadyForMoreMediaData else {
            if displayRecoveryProbeGeneration == loadGeneration {
                retainLatestDisplayRecoveryFrame(recoveryFrame)
            }
            demandScheduler.waitForReadiness(generation: loadGeneration)
            armDisplayReadinessCallback(
                engineGeneration: lifecycle.engineGeneration,
                loadGeneration: loadGeneration
            )
            return
        }
        // Use timestamped presentation with a control timebase. AVFoundation explicitly
        // discourages combining that model with kCMSampleAttachmentKey_DisplayImmediately.
        ensureTimebase(at: presentationTime)
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        } else {
            displayLayer.enqueue(sampleBuffer)
        }
        if displayRendererIsFailed {
            _ = recoverDisplayRendererIfNeeded(
                loadGeneration: loadGeneration,
                retaining: recoveryFrame
            )
            return
        }
        if displayRecoveryProbeGeneration == loadGeneration {
            displayRecoveryGate.finishRenderingProbeSubmission(generation: loadGeneration)
            displayRecoveryProbeGeneration = nil
        }
        if displayRenderingStatus == .rendering {
            displayRecoveryGate.markRenderingSucceeded(generation: loadGeneration)
        }
        sampleTimeline.didEnqueue(pts: mediaSeconds, epoch: timelineEpoch)
        completeTimelineWaiters(
            engineGeneration: lifecycle.engineGeneration,
            loadGeneration: loadGeneration,
            timelineEpoch: timelineEpoch
        )
        frameCount += 1
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let frame = MPVMetalSampleBufferFrame(
            sampleBuffer: sampleBuffer,
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            dimensions: dimensions,
            frameIndex: frameCount
        )
        let renderDiagnostics = makeRenderDiagnosticsSnapshot()
        let engineGeneration = lifecycle.engineGeneration
        DispatchQueue.main.async { @MainActor [weak self, frame] in
            guard let self,
                  self.renderLifecycleFence.accepts(
                    engineGeneration: engineGeneration,
                    loadGeneration: loadGeneration
                  ) else { return }
            self.publishedRenderDiagnostics = renderDiagnostics
            self.onFrame?(frame)
            self.emitFrameDiagnosticsIfNeeded(frameCount: renderDiagnostics.frameCount)
        }
    }

    private func emitFrameDiagnosticsIfNeeded(frameCount: Int) {
        guard let onDiagnostics else { return }
        let now = CACurrentMediaTime()
        if frameCount != 1,
           let lastFrameDiagnosticsEmissionTime,
           now - lastFrameDiagnosticsEmissionTime < 1.0 {
            return
        }
        self.lastFrameDiagnosticsEmissionTime = now
        onDiagnostics(diagnosticsSnapshot())
    }

    private func updateFormatDescriptionIfNeeded(for buffer: CVPixelBuffer, forceSDR: Bool) -> Bool {
        let width = Int32(CVPixelBufferGetWidth(buffer))
        let height = Int32(CVPixelBufferGetHeight(buffer))
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        let metadataSignature = currentColorMetadataSignature(pixelFormat: pixelFormat, forceSDR: forceSDR)
        if let description = formatDescription {
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            if dimensions.width == width,
               dimensions.height == height,
               CMFormatDescriptionGetMediaSubType(description) == pixelFormat,
               formatDescriptionMetadataSignature == metadataSignature {
                return false
            }
        }

        flushMetalTextureCache()
        var newDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &newDescription
        )
        if status == noErr, let newDescription {
            formatDescription = newDescription
            formatDescriptionMetadataSignature = metadataSignature
            lastPixelFormatType = pixelFormat
            lastPixelFormatDescription = pixelFormatDescription(pixelFormat)
            return true
        }
        reportError("format description creation failed status=\(status)")
        return false
    }

    private func applyColorAttachments(to buffer: CVPixelBuffer, forceSDR: Bool) {
        let isHDR = streamLooksHDR && !forceSDR
        hdrMetadataApplied = isHDR
        ensureColorMetadataCache()
        if let attachments = forceSDR
            ? cachedSDRColorAttachments
            : cachedSourceColorAttachments {
            CVBufferSetAttachments(buffer, attachments, .shouldPropagate)
        }
    }

    private func currentColorMetadataSignature(pixelFormat: OSType, forceSDR: Bool) -> String {
        if forceSDR {
            return "\(pixelFormatDescription(pixelFormat))|bt709|bt709|bt709|sdr"
        }
        ensureColorMetadataCache()
        return "\(pixelFormatDescription(pixelFormat))|\(cachedSourceColorMetadataSignature)"
    }

    /// Resolve string metadata and immutable attachment objects only when mpv reports a metadata
    /// change. The previous path lowercased strings, formatted a signature, allocated a color
    /// space, and made five CoreVideo attachment calls for every frame.
    private func rebuildColorMetadataCache() {
        let transfer = videoTransferFunction.lowercased()
        resolvedStreamLooksHDR = videoSignalPeak > 1.0
            || transfer.contains("pq")
            || transfer.contains("hlg")
            || transfer.contains("2084")

        let primaries = colorPrimariesAttachmentValue()
        let transferFunction = transferFunctionAttachmentValue()
        let matrix = ycbcrMatrixAttachmentValue()
        let colorSpace = resolvedStreamLooksHDR
            ? mpvMetalSampleBufferExtendedP3ColorSpace
            : mpvMetalSampleBufferSRGBColorSpace
        cachedSourceColorAttachments = [
            kCVImageBufferAlphaChannelIsOpaque: kCFBooleanTrue!,
            kCVImageBufferColorPrimariesKey: primaries,
            kCVImageBufferTransferFunctionKey: transferFunction,
            kCVImageBufferYCbCrMatrixKey: matrix,
            kCVImageBufferCGColorSpaceKey: colorSpace,
        ] as CFDictionary
        cachedSourceColorMetadataSignature = [
            primaries as String,
            transferFunction as String,
            matrix as String,
            String(format: "%.3f", videoSignalPeak),
        ].joined(separator: "|")
    }

    private func ensureColorMetadataCache() {
        if cachedSourceColorAttachments == nil {
            rebuildColorMetadataCache()
        }
        if cachedSDRColorAttachments == nil {
            cachedSDRColorAttachments = [
                kCVImageBufferAlphaChannelIsOpaque: kCFBooleanTrue!,
                kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
                kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                kCVImageBufferCGColorSpaceKey: mpvMetalSampleBufferSRGBColorSpace,
            ] as CFDictionary
        }
    }

    private func colorPrimariesAttachmentValue() -> CFString {
        let primaries = videoColorPrimaries.lowercased()
        if primaries.contains("2020") {
            return kCVImageBufferColorPrimaries_ITU_R_2020
        }
        if primaries.contains("p3") {
            return kCVImageBufferColorPrimaries_P3_D65
        }
        return kCVImageBufferColorPrimaries_ITU_R_709_2
    }

    private func transferFunctionAttachmentValue() -> CFString {
        let transfer = videoTransferFunction.lowercased()
        if transfer.contains("pq") || transfer.contains("2084") {
            return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        }
        if transfer.contains("hlg") {
            return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        }
        if transfer.contains("srgb") {
            return kCVImageBufferTransferFunction_sRGB
        }
        return kCVImageBufferTransferFunction_ITU_R_709_2
    }

    private func ycbcrMatrixAttachmentValue() -> CFString {
        let matrix = videoYCbCrMatrix.lowercased()
        if matrix.contains("2020") || videoColorPrimaries.lowercased().contains("2020") {
            return kCVImageBufferYCbCrMatrix_ITU_R_2020
        }
        return kCVImageBufferYCbCrMatrix_ITU_R_709_2
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
                lastAppliedTimebaseRate = nil
                applyTimebaseRateIfNeeded(timebase, rate: sampleTimeline.effectiveRate)
                displayLayer.controlTimebase = timebase
                timelineIsAnchored = true
                lastTimebaseDriftCheckTime = CACurrentMediaTime()
            }
        } else if let timebase = displayLayer.controlTimebase {
            let now = CACurrentMediaTime()
            if !timelineIsAnchored || now - lastTimebaseDriftCheckTime >= 0.25 {
                let current = CMTimebaseGetTime(timebase)
                let drift = abs(CMTimeGetSeconds(current) - CMTimeGetSeconds(presentationTime))
                lastTimebaseDriftCheckTime = now
                if !timelineIsAnchored || !drift.isFinite || drift > 1.0 {
                    CMTimebaseSetTime(timebase, time: presentationTime)
                    timelineIsAnchored = true
                }
            }
            applyTimebaseRateIfNeeded(timebase, rate: sampleTimeline.effectiveRate)
        }
    }

    private func applyTimebaseRateIfNeeded(_ timebase: CMTimebase, rate: Double) {
        guard lastAppliedTimebaseRate != rate else { return }
        CMTimebaseSetRate(timebase, rate: rate)
        lastAppliedTimebaseRate = rate
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

    private func updateState(_ newState: MPVMetalSampleBufferRendererState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    private func updateRenderLifecycleFence() {
        renderLifecycleFence.update(
            engineGeneration: engineGeneration,
            loadGeneration: loadGeneration,
            isRunning: isRunning,
            isStopping: isStopping
        )
    }

    private func reportError(_ message: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { @MainActor [weak self] in
                self?.reportError(message)
            }
            return
        }
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

    private func clearProperty(_ name: String) {
        guard let handle = mpv else { return }
        _ = name.withCString { namePointer in
            mpv_set_property(handle, namePointer, MPV_FORMAT_NONE, nil)
        }
    }

    private func setFlagProperty(_ name: String, _ value: Bool) {
        guard let handle = mpv else { return }
        var data: Int32 = value ? 1 : 0
        _ = name.withCString { mpv_set_property(handle, $0, MPV_FORMAT_FLAG, &data) }
    }

    private func getDoubleProperty(_ name: String) -> Double? {
        guard let handle = mpv else { return nil }
        var data = Double()
        let status = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_DOUBLE, &data) }
        return status >= 0 ? data : nil
    }

    private func getStringProperty(_ name: String) -> String? {
        guard let handle = mpv else { return nil }
        var data: UnsafeMutablePointer<CChar>?
        let status = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_STRING, &data) }
        guard status >= 0, let data else { return nil }
        defer { mpv_free(data) }
        return String(cString: data)
    }

    private func getIntProperty(_ name: String) -> Int? {
        guard let handle = mpv else { return nil }
        var data: Int64 = 0
        let status = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_INT64, &data) }
        return status >= 0 ? Int(data) : nil
    }

    private func getInt64Property(_ name: String) -> Int64? {
        guard let handle = mpv else { return nil }
        var data: Int64 = 0
        let status = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_INT64, &data) }
        return status >= 0 ? data : nil
    }

    private func currentPlaylistEntryID() -> Int64? {
        if let position = getInt64Property("playlist-pos"), position >= 0,
           let playlistEntryID = getInt64Property("playlist/\(position)/id") {
            return playlistEntryID
        }
        return getInt64Property("playlist/0/id")
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

    private func performOnMain(_ block: () -> Void) { block() }

    /// Bridges actor-owned scheduling to the renderer's separately audited serial queue. The
    /// handler itself is unchecked-Sendable because every captured mutable value is either owned
    /// by `renderQueue` or guarded by `renderLifecycleFence`.
    private func enqueueRenderWork(_ block: @escaping () -> Void) {
        let handler = MPVMetalSampleBufferReadinessHandler(block)
        renderQueue.async { handler() }
    }
}

#else

@preconcurrency @MainActor
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
    public func waitUntilStopped() async {}
    public func waitForTimelineUpdate(requiringCurrentFrame: Bool = false) async -> Bool {
        _ = requiringCurrentFrame
        return false
    }
    public func load(_ url: URL, headers: [String: String]? = nil) { _ = url; _ = headers }
    func load(
        _ url: URL,
        headers: [String: String]? = nil,
        preservingDisplayedImage: Bool
    ) {
        _ = url
        _ = headers
        _ = preservingDisplayedImage
    }
    public func play() {}
    public func pause() {}
    public func seek(to seconds: Double) { _ = seconds }
    public func seek(by seconds: Double) { _ = seconds }
    @available(*, deprecated, message: "Use MPVGPUPlayerRenderer.preparePictureInPicture() async throws")
    public func primeFrames(reason: String = "manual", count: Int = 6) { _ = reason; _ = count }
    func primeCompatibilityFrames(reason: String, count: Int) { _ = reason; _ = count }
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
    func enqueueExternalSubtitles(_ batch: MPVExternalSubtitleQueue.Batch) { _ = batch }
    func restoreSubtitleSelectionIntent(_ intent: MPVExternalSubtitleQueue.SelectionIntent?) { _ = intent }
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
            presentationBackend: .softwareIOSurface,
            metalPresentationFrameCount: 0,
            metalPresentationFailureCount: 0,
            pixelFormatDescription: "unsupported",
            sourcePixelFormatDescription: "unsupported",
            highBitDepthRenderingActive: false,
            highBitDepthRenderingFailureCount: 0,
            hdrMetadataApplied: false,
            videoColorPrimaries: "",
            videoTransferFunction: "",
            videoSignalPeak: 0,
            renderAPI: "unsupported",
            backendDescription: "unsupported",
            coalescedRenderRequestCount: 0,
            backpressureDropCount: 0,
            poolExhaustionDropCount: 0,
            staleGenerationDropCount: 0,
            inFlightGPUFrameCount: 0,
            lastGPULatencyMilliseconds: 0,
            timelineEpoch: 0,
            timelineRate: 0
        )
    }
}

#endif
