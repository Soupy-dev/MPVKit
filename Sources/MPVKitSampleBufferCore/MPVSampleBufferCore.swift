import Foundation

/// A lock-backed handoff between a renderer's main-actor lifecycle and its serial render queue.
/// Render work never reads actor-owned generation/teardown fields directly, which keeps stop/load
/// invalidation deterministic even under Thread Sanitizer.
public final class MPVRenderLifecycleFence: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let engineGeneration: UInt64
        public let loadGeneration: UInt64
        public let isRunning: Bool
        public let isStopping: Bool

        public func accepts(engineGeneration: UInt64, loadGeneration: UInt64) -> Bool {
            isRunning && !isStopping
                && self.engineGeneration == engineGeneration
                && self.loadGeneration == loadGeneration
        }
    }

    private let lock = NSLock()
    private var value = Snapshot(
        engineGeneration: 0,
        loadGeneration: 0,
        isRunning: false,
        isStopping: false
    )

    public init() {}

    public func update(
        engineGeneration: UInt64,
        loadGeneration: UInt64,
        isRunning: Bool,
        isStopping: Bool
    ) {
        lock.lock()
        value = Snapshot(
            engineGeneration: engineGeneration,
            loadGeneration: loadGeneration,
            isRunning: isRunning,
            isStopping: isStopping
        )
        lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        let result = value
        lock.unlock()
        return result
    }

    public func accepts(engineGeneration: UInt64, loadGeneration: UInt64) -> Bool {
        snapshot().accepts(engineGeneration: engineGeneration, loadGeneration: loadGeneration)
    }

    public func accepts(loadGeneration: UInt64) -> Bool {
        let current = snapshot()
        return current.isRunning && !current.isStopping
            && current.loadGeneration == loadGeneration
    }
}

/// Resolves a caller preference without allowing it to exceed a platform's safety ceiling.
public enum MPVDrawablePixelLimit {
    public static func resolved(configured: Int, platformMaximum: Int) -> Int {
        let hardMaximum = max(1, platformMaximum)
        let minimumDrawableArea = min(4, hardMaximum)
        guard configured > 0 else { return hardMaximum }
        return min(hardMaximum, max(minimumDrawableArea, configured))
    }
}

/// Classifies callbacks from the optional native gpu-next PiP sink before the platform wrapper
/// touches its IOSurface ownership table. Token zero is reserved for the inline-restoration
/// notification and therefore deliberately has no matching in-flight pixel buffer.
public enum MPVNativePiPCallbackDisposition: Equatable, Sendable {
    case inlineRestored
    case surfaceFrame(token: UInt64)
    case stale

    public static func classify(
        token: UInt64,
        generation: UInt64,
        currentGeneration: UInt64,
        status: UInt32,
        readyStatus: UInt32
    ) -> Self {
        if token == 0 {
            return generation == currentGeneration && status == readyStatus
                ? .inlineRestored
                : .stale
        }
        return .surfaceFrame(token: token)
    }
}

/// Decides whether the native gpu-next PiP sink should ask libmpv for another target.
///
/// Warmup and restoration are bounded handshakes, while active offscreen playback is the only
/// mode that continuously consumes targets. A forced demand represents a discontinuity, resize,
/// recovery, or AVKit-readiness edge and deliberately produces one frame even while paused.
public enum MPVNativePiPTargetMode: Equatable, Sendable {
    case inline
    case warmup
    case offscreen
    case restore
}

public enum MPVNativePiPTargetDemand {
    public static func shouldSubmit(
        mode: MPVNativePiPTargetMode,
        forced: Bool,
        preparationCompleted: Bool,
        timelineRate: Double,
        restoreFramePending: Bool
    ) -> Bool {
        if forced { return true }
        switch mode {
        case .inline:
            return false
        case .warmup:
            return !preparationCompleted
        case .offscreen:
            return timelineRate.isFinite && timelineRate > 0
        case .restore:
            return restoreFramePending
        }
    }
}

/// Associates host load generations with mpv's process-lifetime-unique playlist entry IDs.
///
/// A synchronous `loadfile` command can be followed immediately by another replacement before
/// the main actor consumes `START_FILE`. Callers should submit before issuing the command and,
/// when available, bind the resulting `playlist/N/id` afterwards. `START_FILE` then uses the
/// exact ID; the submission-order queue is only a fallback for libmpv builds where that property
/// cannot be read yet. Events for an older entry remain distinguishable from the newest load even
/// when the client-facing generation value is reused.
public struct MPVLoadIdentityTracker: Sendable {
    public struct Identity: Equatable, Sendable {
        public let sequence: UInt64
        public let clientGeneration: UInt64

        public init(sequence: UInt64, clientGeneration: UInt64) {
            self.sequence = sequence
            self.clientGeneration = clientGeneration
        }
    }

    public private(set) var latestIdentity: Identity?
    public private(set) var lastStartedIdentity: Identity?
    private var nextSequence: UInt64 = 0
    private var pendingIdentities: [Identity] = []
    private var identitiesByPlaylistEntryID: [Int64: Identity] = [:]

    public init() {}

    @discardableResult
    public mutating func submit(clientGeneration: UInt64) -> Identity {
        nextSequence &+= 1
        let identity = Identity(sequence: nextSequence, clientGeneration: clientGeneration)
        latestIdentity = identity
        pendingIdentities.append(identity)
        return identity
    }

    /// Installs the exact identity discovered from `playlist/N/id` after `loadfile` succeeds.
    public mutating func bind(playlistEntryID: Int64, to identity: Identity) {
        identitiesByPlaylistEntryID[playlistEntryID] = identity
        pendingIdentities.removeAll { $0 == identity }
    }

    public mutating func cancel(_ identity: Identity) {
        pendingIdentities.removeAll { $0 == identity }
        identitiesByPlaylistEntryID = identitiesByPlaylistEntryID.filter { $0.value != identity }
        if latestIdentity == identity {
            latestIdentity = pendingIdentities.last ?? lastStartedIdentity
        }
    }

    /// Associates a `START_FILE` ID. Exact post-command bindings win; command ordering is used
    /// only when an exact ID could not be queried. A start without a pending command inherits the
    /// last started identity for playlist redirects/automatic advancement within the same load.
    @discardableResult
    public mutating func didStart(playlistEntryID: Int64) -> Identity? {
        let identity: Identity?
        if let exact = identitiesByPlaylistEntryID[playlistEntryID] {
            identity = exact
            // Event delivery is serial. Once an exactly-bound newer START_FILE is consumed, any
            // older unbound submission can no longer legitimately start later; retaining it would
            // let a redirect/automatic-next entry inherit the superseded load.
            pendingIdentities.removeAll { $0.sequence <= exact.sequence }
        } else if !pendingIdentities.isEmpty {
            let pending = pendingIdentities.removeFirst()
            identitiesByPlaylistEntryID[playlistEntryID] = pending
            identity = pending
        } else {
            identity = lastStartedIdentity
            if let identity {
                identitiesByPlaylistEntryID[playlistEntryID] = identity
            }
        }
        lastStartedIdentity = identity
        return identity
    }

    public func identity(forPlaylistEntryID playlistEntryID: Int64) -> Identity? {
        identitiesByPlaylistEntryID[playlistEntryID]
    }

    public func isLatest(_ identity: Identity) -> Bool {
        identity == latestIdentity
    }

    @discardableResult
    public mutating func didEnd(playlistEntryID: Int64) -> Identity? {
        identitiesByPlaylistEntryID.removeValue(forKey: playlistEntryID)
    }

    /// Clears handle-scoped IDs without reusing the internal sequence. Keeping the sequence
    /// monotonic makes any already-copied event harmless after teardown/restart.
    public mutating func reset() {
        latestIdentity = nil
        lastStartedIdentity = nil
        pendingIdentities.removeAll(keepingCapacity: false)
        identitiesByPlaylistEntryID.removeAll(keepingCapacity: false)
    }
}

/// Stores load-sensitive work until the matching generation reaches `FILE_LOADED`.
/// Beginning a replacement atomically discards the superseded generation's actions; a stale
/// completion cannot drain or erase actions queued for the new generation.
public struct MPVGenerationDeferredActions<Action> {
    public private(set) var generation: UInt64?
    private var actions: [Action] = []

    public init() {}

    public mutating func beginGeneration(_ generation: UInt64) {
        self.generation = generation
        actions.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func append(_ action: Action, generation: UInt64) -> Bool {
        guard self.generation == generation else { return false }
        actions.append(action)
        return true
    }

    public mutating func drain(generation: UInt64) -> [Action] {
        guard self.generation == generation else { return [] }
        let result = actions
        actions.removeAll(keepingCapacity: true)
        return result
    }

    public mutating func cancel() {
        generation = nil
        actions.removeAll(keepingCapacity: false)
    }
}

/// Generation-scoped budget for the deprecated priming API. Keeping this separate from ordinary
/// render demand is important: load, seek, subtitle, and format-discontinuity refreshes must remain
/// able to request forced frames after legacy callers have exhausted their two compatibility hints.
public struct MPVLegacyPrimeBudget: Equatable, Sendable {
    public let capacity: Int
    public private(set) var remaining: Int

    public init(capacity: Int = 2) {
        self.capacity = max(0, capacity)
        self.remaining = max(0, capacity)
    }

    public mutating func reset() {
        remaining = capacity
    }

    /// Returns the number of newly accepted attempts. Across a generation this can never exceed
    /// `capacity`, even when callers alternate priming requests with completed renders.
    public mutating func consume(requested: Int) -> Int {
        let accepted = min(remaining, max(0, requested))
        remaining -= accepted
        return accepted
    }
}

/// Retains one coalesced allocation demand and grants at most one retry until that demand either
/// succeeds or is explicitly replaced by a new presentation epoch.
public struct MPVLatestDemandRetryGate: Equatable, Sendable {
    public private(set) var isPending = false
    public private(set) var retryRemaining = true

    public init() {}

    public mutating func beginDemand() {
        guard !isPending else { return }
        isPending = true
        retryRemaining = true
    }

    public mutating func replaceDemand() {
        isPending = true
        retryRemaining = true
    }

    public mutating func consumeRetry() -> Bool {
        guard isPending, retryRemaining else { return false }
        retryRemaining = false
        return true
    }

    public mutating func complete() {
        isPending = false
        retryRemaining = true
    }

    public mutating func cancel() {
        complete()
    }
}

/// Serializes recovery from a failed AVSampleBuffer renderer without allowing a callback storm
/// to issue repeated flushes or errors. A nonfailed flush must be followed by one successful
/// replacement sample reaching the renderer's `.rendering` state before the current episode
/// resets. A failed attempt stays
/// terminal until the owner installs a new generation or stops.
public struct MPVDisplayLayerRecoveryGate: Equatable, Sendable {
    public enum FailureObservation: Equatable, Sendable {
        case recover
        case wait
        case report
        case terminal
        case stale
    }

    public enum Completion: Equatable, Sendable {
        case awaitingRendering
        case failed
        case stale
    }

    public private(set) var generation: UInt64?
    public private(set) var isRecovering = false
    public private(set) var isAwaitingRendering = false
    public private(set) var isRecoveryProbeAvailable = false
    public private(set) var isRecoveryProbeInProgress = false
    public private(set) var didReportFailure = false

    public init() {}

    public mutating func beginGeneration(_ generation: UInt64) {
        self.generation = generation
        isRecovering = false
        isAwaitingRendering = false
        isRecoveryProbeAvailable = false
        isRecoveryProbeInProgress = false
        didReportFailure = false
    }

    public func blocksRendering(generation: UInt64) -> Bool {
        self.generation == generation
            && (isRecovering
                || didReportFailure
                || (isAwaitingRendering && !isRecoveryProbeAvailable))
    }

    public mutating func observeFailure(generation: UInt64) -> FailureObservation {
        guard self.generation == generation else { return .stale }
        if didReportFailure { return .terminal }
        if isRecovering { return .wait }
        if isAwaitingRendering {
            isAwaitingRendering = false
            isRecoveryProbeAvailable = false
            isRecoveryProbeInProgress = false
            didReportFailure = true
            return .report
        }
        isRecovering = true
        return .recover
    }

    public mutating func complete(
        generation: UInt64,
        rendererRemainsFailed: Bool
    ) -> Completion {
        guard self.generation == generation, isRecovering else { return .stale }
        isRecovering = false
        if rendererRemainsFailed {
            isRecoveryProbeAvailable = false
            isRecoveryProbeInProgress = false
            didReportFailure = true
            return .failed
        }
        isAwaitingRendering = true
        isRecoveryProbeAvailable = true
        isRecoveryProbeInProgress = false
        return .awaitingRendering
    }

    /// Grants exactly one replacement-frame pipeline after a nonfailed recovery flush. Owners
    /// carry this permit through any asynchronous GPU conversion and finish it after enqueue.
    public mutating func beginRenderingProbe(generation: UInt64) -> Bool {
        guard self.generation == generation,
              isAwaitingRendering,
              isRecoveryProbeAvailable,
              !isRecoveryProbeInProgress else { return false }
        isRecoveryProbeAvailable = false
        isRecoveryProbeInProgress = true
        return true
    }

    @discardableResult
    public mutating func finishRenderingProbeSubmission(generation: UInt64) -> Bool {
        guard self.generation == generation,
              isAwaitingRendering,
              isRecoveryProbeInProgress else { return false }
        isRecoveryProbeInProgress = false
        return true
    }

    /// A nonfailed flush only resets AVFoundation to an enqueueable state. The episode is not
    /// considered recovered until the owner observes `.rendering` for the replacement sample; a
    /// failure before that point is reported instead of starting a flush loop.
    @discardableResult
    public mutating func markRenderingSucceeded(generation: UInt64) -> Bool {
        guard self.generation == generation, isAwaitingRendering else { return false }
        isAwaitingRendering = false
        isRecoveryProbeAvailable = false
        isRecoveryProbeInProgress = false
        didReportFailure = false
        return true
    }

    public mutating func cancel() {
        generation = nil
        isRecovering = false
        isAwaitingRendering = false
        isRecoveryProbeAvailable = false
        isRecoveryProbeInProgress = false
        didReportFailure = false
    }
}

/// Classifies the only observed libmpv properties that can safely arrive without a playlist entry
/// identity while a replacement is waiting for `FILE_LOADED`. File-derived values emitted while
/// the old entry tears down must not be attributed to the new load.
public enum MPVLoadPropertyFence {
    public static func shouldAccept(
        property name: String,
        hasPlaylistEntryID: Bool,
        awaitingFileLoaded: Bool
    ) -> Bool {
        guard awaitingFileLoaded, !hasPlaylistEntryID else { return true }
        switch name {
        case "pause", "paused-for-cache", "speed":
            return true
        default:
            return false
        }
    }
}

/// Remembers the video selection that the primary handle must regain after the compatibility
/// renderer temporarily disables inline video. Selection changes made while inline video is
/// suppressed update the desired value without re-enabling the primary decoder/output.
public struct MPVCompatibilityVideoSelectionState: Equatable, Sendable {
    public private(set) var desiredSelection: String = "auto"
    public private(set) var isInlineSuppressed = false

    public init() {}

    /// Video-track selection is media-item state. A replacement starts from mpv's automatic
    /// selection and cannot inherit `vid=no` from the old compatibility handoff.
    @discardableResult
    public mutating func beginLoad() -> String {
        desiredSelection = "auto"
        isInlineSuppressed = false
        return desiredSelection
    }

    /// Records a real primary-handle selection only while the primary is authoritative. Property
    /// notifications caused by the temporary `vid=no` must not overwrite the value to restore.
    public mutating func observePrimarySelection(_ selection: String?) {
        guard !isInlineSuppressed, let selection else { return }
        desiredSelection = Self.normalized(selection)
    }

    /// Returns the value to apply to the primary, or nil when only the compatibility renderer may
    /// change because inline video is currently suppressed.
    @discardableResult
    public mutating func select(_ selection: String) -> String? {
        desiredSelection = Self.normalized(selection)
        return isInlineSuppressed ? nil : desiredSelection
    }

    /// Captures mpv's resolved selection (normally a numeric track ID) before disabling inline
    /// video. The caller should apply the returned `no` value to the primary handle.
    @discardableResult
    public mutating func suppressInline(observedPrimarySelection: String?) -> String {
        observePrimarySelection(observedPrimarySelection)
        isInlineSuppressed = true
        return "no"
    }

    /// Returns the exact desired selection once. Repeated exit/failure callbacks are idempotent.
    public mutating func restoreInline() -> String? {
        guard isInlineSuppressed else { return nil }
        isInlineSuppressed = false
        return desiredSelection
    }

    private static func normalized(_ selection: String) -> String {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "auto" }
        switch trimmed.lowercased() {
        case "auto": return "auto"
        case "no", "none": return "no"
        default: return trimmed
        }
    }
}

/// Resolves the playback command for the video-only compatibility PiP handle. The primary handle
/// remains the sole audio/clock authority, so cache pauses must stop the secondary video even when
/// the user-facing pause property is false. A material drift is corrected only at explicit
/// synchronization points such as activation or recovery from buffering.
public struct MPVCompatibilityPlaybackDecision: Equatable, Sendable {
    public let shouldPause: Bool
    public let seekPosition: Double?

    public init(shouldPause: Bool, seekPosition: Double?) {
        self.shouldPause = shouldPause
        self.seekPosition = seekPosition
    }

    public static func resolve(
        isPaused: Bool,
        isBuffering: Bool,
        primaryPosition: Double,
        secondaryPosition: Double,
        shouldRealign: Bool,
        allowsPlayback: Bool = true,
        driftThreshold: Double = 0.25
    ) -> Self {
        let threshold = driftThreshold.isFinite ? max(0, driftThreshold) : 0.25
        let seekPosition: Double?
        if shouldRealign,
           primaryPosition.isFinite,
           secondaryPosition.isFinite,
           abs(primaryPosition - secondaryPosition) > threshold {
            seekPosition = max(0, primaryPosition)
        } else {
            seekPosition = nil
        }
        return Self(
            shouldPause: !allowsPlayback || isPaused || isBuffering,
            seekPosition: seekPosition
        )
    }
}

/// Queue-independent demand coalescing for a sample-buffer renderer. The host owns the serial
/// executor; this value only decides whether work should be scheduled and what that work consumes.
public struct MPVFrameDemandScheduler: Equatable, Sendable {
    public struct Demand: Equatable, Sendable {
        public let generation: UInt64
        public let isForced: Bool
    }

    public private(set) var generation: UInt64 = 0
    public private(set) var hasPendingDemand = false
    public private(set) var forcedBudget = 0
    public private(set) var isWorkScheduled = false
    public private(set) var isWaitingForReadiness = false
    public private(set) var inFlightCount = 0
    public private(set) var coalescedRequestCount = 0
    public private(set) var backpressureCount = 0
    public private(set) var staleGenerationCount = 0
    public private(set) var lastWorkTime: TimeInterval = 0

    public let maximumForcedBudget: Int
    public let maximumInFlightCount: Int
    public let minimumFrameInterval: TimeInterval

    public init(
        maximumForcedBudget: Int = 2,
        maximumInFlightCount: Int = 1,
        minimumFrameInterval: TimeInterval = 1.0 / 24.0
    ) {
        self.maximumForcedBudget = max(1, maximumForcedBudget)
        self.maximumInFlightCount = max(1, maximumInFlightCount)
        self.minimumFrameInterval = max(0, minimumFrameInterval)
    }

    @discardableResult
    public mutating func beginGeneration() -> UInt64 {
        beginGeneration(generation &+ 1)
    }

    @discardableResult
    public mutating func beginGeneration(_ generation: UInt64) -> UInt64 {
        self.generation = generation
        hasPendingDemand = false
        forcedBudget = 0
        isWorkScheduled = false
        isWaitingForReadiness = false
        return self.generation
    }

    /// Returns true when the owner should install one timer/work item.
    @discardableResult
    public mutating func request(forcedCount: Int = 0, generation: UInt64) -> Bool {
        guard generation == self.generation else {
            staleGenerationCount += 1
            return false
        }
        if hasPendingDemand || isWorkScheduled || isWaitingForReadiness || inFlightCount > 0 {
            coalescedRequestCount += 1
        }
        hasPendingDemand = true
        forcedBudget = max(
            forcedBudget,
            min(maximumForcedBudget, max(0, forcedCount))
        )
        return canSchedule
    }

    public var canSchedule: Bool {
        (hasPendingDemand || forcedBudget > 0)
            && !isWorkScheduled
            && !isWaitingForReadiness
            && inFlightCount < maximumInFlightCount
    }

    public mutating func markWorkScheduled(generation: UInt64) -> Bool {
        guard generation == self.generation, canSchedule else {
            if generation != self.generation { staleGenerationCount += 1 }
            return false
        }
        isWorkScheduled = true
        return true
    }

    public func delay(at now: TimeInterval) -> TimeInterval {
        max(0, lastWorkTime + minimumFrameInterval - now)
    }

    public mutating func consume(at now: TimeInterval, generation: UInt64) -> Demand? {
        guard generation == self.generation else {
            staleGenerationCount += 1
            return nil
        }
        isWorkScheduled = false
        guard inFlightCount < maximumInFlightCount,
              !isWaitingForReadiness,
              hasPendingDemand || forcedBudget > 0 else { return nil }
        let forced = forcedBudget > 0
        if forced {
            forcedBudget -= 1
        }
        hasPendingDemand = false
        lastWorkTime = now
        return Demand(generation: generation, isForced: forced)
    }

    public mutating func waitForReadiness(generation: UInt64) {
        guard generation == self.generation else {
            staleGenerationCount += 1
            return
        }
        isWorkScheduled = false
        isWaitingForReadiness = true
        hasPendingDemand = true
        backpressureCount += 1
    }

    @discardableResult
    public mutating func becomeReady(generation: UInt64) -> Bool {
        guard generation == self.generation else {
            staleGenerationCount += 1
            return false
        }
        isWaitingForReadiness = false
        return canSchedule
    }

    public mutating func beginInFlight(generation: UInt64) -> Bool {
        guard generation == self.generation, inFlightCount < maximumInFlightCount else {
            if generation != self.generation { staleGenerationCount += 1 }
            return false
        }
        inFlightCount += 1
        return true
    }

    @discardableResult
    public mutating func finishInFlight(generation: UInt64) -> Bool {
        guard inFlightCount > 0 else {
            if generation != self.generation { staleGenerationCount += 1 }
            return canSchedule
        }
        if generation != self.generation {
            staleGenerationCount += 1
            inFlightCount -= 1
            return canSchedule
        }
        inFlightCount -= 1
        return canSchedule
    }

    public mutating func cancelScheduledWork() {
        isWorkScheduled = false
    }
}

/// Coalesces any number of display-readiness misses into one request for a freshly rendered
/// frame. The owner deliberately does not retain the completed frame that encountered
/// backpressure: by the time AVKit becomes ready, that frame's PTS may be arbitrarily stale.
public struct MPVLatestReadinessDemand: Equatable, Sendable {
    public private(set) var isPending = false
    public private(set) var coalescedRequestCount = 0

    public init() {}

    @discardableResult
    public mutating func request() -> Bool {
        if isPending {
            coalescedRequestCount += 1
            return false
        }
        isPending = true
        return true
    }

    /// Returns true exactly once for all requests accumulated since the previous consumption.
    @discardableResult
    public mutating func consume() -> Bool {
        guard isPending else { return false }
        isPending = false
        return true
    }

    public mutating func reset() {
        isPending = false
    }
}

/// A deterministic throttle for high-frequency diagnostics. The first event and any material
/// transition are emitted immediately; steady-state events are bounded by `minimumInterval`.
public struct MPVDiagnosticsEmissionThrottle: Equatable, Sendable {
    public let minimumInterval: TimeInterval
    public private(set) var lastEmissionTime: TimeInterval?

    public init(minimumInterval: TimeInterval) {
        self.minimumInterval = max(0, minimumInterval)
    }

    public mutating func shouldEmit(at time: TimeInterval, materialChange: Bool = false) -> Bool {
        guard time.isFinite else { return false }
        if materialChange
            || lastEmissionTime == nil
            || time - (lastEmissionTime ?? time) >= minimumInterval {
            lastEmissionTime = time
            return true
        }
        return false
    }

    public mutating func reset() {
        lastEmissionTime = nil
    }
}

public struct MPVSampleTimeline: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case enqueue(pts: Double, epoch: UInt64, flush: Bool, rate: Double)
        case dropDuplicate
        case dropInvalid
    }

    public private(set) var epoch: UInt64 = 0
    public private(set) var lastEnqueuedPTS: Double?
    public private(set) var playbackRate: Double = 1
    public private(set) var isPaused = true
    public private(set) var isBuffering = false
    public private(set) var needsFlush = true

    public init() {}

    public var effectiveRate: Double {
        isPaused || isBuffering ? 0 : playbackRate
    }

    public mutating func updatePlayback(paused: Bool? = nil, buffering: Bool? = nil, rate: Double? = nil) {
        if let paused { isPaused = paused }
        if let buffering { isBuffering = buffering }
        if let rate, rate.isFinite { playbackRate = max(0.1, rate) }
    }

    public mutating func beginDiscontinuity() {
        epoch &+= 1
        lastEnqueuedPTS = nil
        needsFlush = true
    }

    public mutating func evaluate(
        pts: Double?,
        fallbackPTS: Double,
        allowsPausedRefresh: Bool = false
    ) -> Decision {
        var value = pts.flatMap { $0.isFinite ? $0 : nil }
            ?? (fallbackPTS.isFinite ? fallbackPTS : .nan)
        guard value.isFinite else { return .dropInvalid }
        value = max(0, value)

        if let lastEnqueuedPTS, value <= lastEnqueuedPTS + 0.0005 {
            if allowsPausedRefresh && effectiveRate == 0 {
                beginDiscontinuity()
            } else if value < lastEnqueuedPTS - 0.25 {
                beginDiscontinuity()
            } else {
                return .dropDuplicate
            }
        }
        return .enqueue(pts: value, epoch: epoch, flush: needsFlush, rate: effectiveRate)
    }

    public mutating func didEnqueue(pts: Double, epoch: UInt64) {
        guard epoch == self.epoch else { return }
        lastEnqueuedPTS = pts
        needsFlush = false
    }

    /// Records a physical flush without claiming that a frame was presented. This is used by
    /// failed-renderer recovery so the one replacement probe does not immediately request a
    /// redundant second flush. An old completion cannot satisfy a newer discontinuity.
    public mutating func didFlush(epoch: UInt64) {
        guard epoch == self.epoch else { return }
        needsFlush = false
    }
}

public struct MPVBoundedFramePool: Equatable, Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var exhaustionCount = 0
    public let capacity: Int
    private var inFlightByGeneration: [UInt64: Int] = [:]
    private var retiredGenerations: Set<UInt64> = []

    public init(capacity: Int = 3) {
        self.capacity = max(1, capacity)
    }

    @discardableResult
    public mutating func beginGeneration() -> UInt64 {
        if generation != 0 {
            if (inFlightByGeneration[generation] ?? 0) > 0 {
                retiredGenerations.insert(generation)
            } else {
                inFlightByGeneration.removeValue(forKey: generation)
            }
        }
        generation &+= 1
        inFlightByGeneration[generation] = 0
        return generation
    }

    public var inFlightCount: Int { inFlightByGeneration[generation] ?? 0 }
    public var retiredInFlightCount: Int {
        retiredGenerations.reduce(0) { $0 + (inFlightByGeneration[$1] ?? 0) }
    }
    public var trackedGenerationCount: Int { inFlightByGeneration.count }

    public func isRetired(_ generation: UInt64) -> Bool {
        retiredGenerations.contains(generation)
    }

    public mutating func acquire(generation: UInt64) -> Bool {
        guard generation == self.generation, inFlightCount < capacity else {
            exhaustionCount += 1
            return false
        }
        inFlightByGeneration[generation, default: 0] += 1
        return true
    }

    public mutating func release(generation: UInt64) {
        guard let count = inFlightByGeneration[generation], count > 0 else { return }
        let remaining = count - 1
        inFlightByGeneration[generation] = remaining
        if remaining == 0, retiredGenerations.remove(generation) != nil {
            inFlightByGeneration.removeValue(forKey: generation)
        }
    }
}

/// Invalidates asynchronous flush completions when a seek/load/format epoch supersedes them.
public struct MPVFlushEpochCoordinator: Equatable, Sendable {
    public struct Token: Equatable, Sendable {
        public let id: UInt64
        public let epoch: UInt64
    }

    public private(set) var epoch: UInt64 = 0
    private var nextID: UInt64 = 0
    private var activeToken: Token?

    public init() {}

    @discardableResult
    public mutating func beginEpoch() -> UInt64 {
        epoch &+= 1
        activeToken = nil
        return epoch
    }

    public mutating func beginFlush() -> Token {
        nextID &+= 1
        let token = Token(id: nextID, epoch: epoch)
        activeToken = token
        return token
    }

    /// Returns true exactly once for the current epoch's latest flush.
    public mutating func complete(_ token: Token) -> Bool {
        guard activeToken == token, token.epoch == epoch else { return false }
        activeToken = nil
        return true
    }
}

public struct MPVPixelSize: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct MPVResizePolicy: Equatable, Sendable {
    public let maximumPixelCount: Double
    public let maximumDimension: Double
    public let hysteresis: Double

    public init(maximumPixelCount: Double, maximumDimension: Double, hysteresis: Double = 2) {
        self.maximumPixelCount = max(1, maximumPixelCount)
        self.maximumDimension = max(1, maximumDimension)
        self.hysteresis = max(0, hysteresis)
    }

    public func resolve(_ requested: MPVPixelSize, previous: MPVPixelSize?) -> MPVPixelSize? {
        guard requested.width.isFinite, requested.height.isFinite,
              requested.width > 0, requested.height > 0 else { return nil }
        let dimensionScale = min(1, maximumDimension / requested.width, maximumDimension / requested.height)
        guard dimensionScale.isFinite, dimensionScale > 0 else { return nil }
        var scaledWidth = requested.width * dimensionScale
        var scaledHeight = requested.height * dimensionScale
        guard scaledWidth.isFinite, scaledHeight.isFinite,
              scaledWidth > 0, scaledHeight > 0 else { return nil }

        // Compare and derive the pixel-area scale in log space. Direct width*height can overflow
        // for otherwise valid finite host input before the maximum-dimension cap takes effect.
        let logPixelCount = log(scaledWidth) + log(scaledHeight)
        let logMaximumPixelCount = log(maximumPixelCount)
        if logPixelCount > logMaximumPixelCount {
            let pixelScale = exp((logMaximumPixelCount - logPixelCount) / 2)
            guard pixelScale.isFinite, pixelScale > 0 else { return nil }
            scaledWidth *= pixelScale
            scaledHeight *= pixelScale
        }
        guard scaledWidth.isFinite, scaledHeight.isFinite,
              scaledWidth > 0, scaledHeight > 0 else { return nil }
        let resolved = MPVPixelSize(
            width: max(1, floor(scaledWidth)),
            height: max(1, floor(scaledHeight))
        )
        if let previous,
           abs(previous.width - resolved.width) < hysteresis,
           abs(previous.height - resolved.height) < hysteresis {
            return previous
        }
        return resolved
    }
}

public enum MPVRendererLifecycleState: Equatable, Sendable {
    case idle
    case running(generation: UInt64)
    case stopping(generation: UInt64)
    case stopped
}

public struct MPVRendererLifecycle: Equatable, Sendable {
    public private(set) var state: MPVRendererLifecycleState = .idle
    public private(set) var generation: UInt64 = 0

    public init() {}

    public mutating func start() -> UInt64? {
        guard state != .stopping(generation: generation) else { return nil }
        if case .running = state { return generation }
        generation &+= 1
        state = .running(generation: generation)
        return generation
    }

    public mutating func beginStopping() -> UInt64? {
        guard case .running(let generation) = state else { return nil }
        state = .stopping(generation: generation)
        return generation
    }

    public mutating func finishStopping(generation: UInt64) {
        guard state == .stopping(generation: generation) else { return }
        state = .stopped
    }
}
