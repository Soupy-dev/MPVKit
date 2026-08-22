import XCTest
@testable import MPVKitSampleBufferCore

private struct FakeRendererHarness {
    struct GPUWork: Equatable {
        let generation: UInt64
        let poolGeneration: UInt64
        let frameID: Int
    }

    var now: TimeInterval = 0
    var displayIsReady = true
    var scheduler = MPVFrameDemandScheduler(minimumFrameInterval: 0)
    var pool = MPVBoundedFramePool(capacity: 3)
    var generation: UInt64 = 0
    var latestFrameID: Int?
    var gpuWork: [GPUWork] = []
    var enqueuedFrameIDs: [Int] = []
    var isRunning = true

    mutating func load() {
        generation = scheduler.beginGeneration()
        _ = pool.beginGeneration()
        latestFrameID = nil
    }

    mutating func request(frameID: Int) {
        latestFrameID = frameID
        _ = scheduler.request(generation: generation)
    }

    mutating func advance(by interval: TimeInterval) {
        now += interval
    }

    mutating func pump() {
        guard isRunning else { return }
        if scheduler.isWaitingForReadiness {
            guard displayIsReady else { return }
            _ = scheduler.becomeReady(generation: generation)
        }
        if scheduler.canSchedule {
            _ = scheduler.markWorkScheduled(generation: generation)
        }
        guard scheduler.isWorkScheduled else { return }
        guard displayIsReady else {
            scheduler.waitForReadiness(generation: generation)
            return
        }
        guard scheduler.consume(at: now, generation: generation) != nil,
              let latestFrameID,
              pool.acquire(generation: pool.generation),
              scheduler.beginInFlight(generation: generation) else { return }
        gpuWork.append(
            GPUWork(
                generation: generation,
                poolGeneration: pool.generation,
                frameID: latestFrameID
            )
        )
    }

    mutating func completeGPUWork(at index: Int = 0) {
        let work = gpuWork.remove(at: index)
        pool.release(generation: work.poolGeneration)
        let shouldSchedule = scheduler.finishInFlight(generation: work.generation)
        if isRunning, work.generation == generation {
            enqueuedFrameIDs.append(work.frameID)
        }
        if shouldSchedule { pump() }
    }

    mutating func stop() {
        isRunning = false
        generation = scheduler.beginGeneration()
        _ = pool.beginGeneration()
    }
}

final class MPVSampleBufferCoreTests: XCTestCase {
    func testMoltenVKArgumentBufferWorkaroundCoversPinnedArtifactAndGuardsUnsafeTextureImport() {
        XCTAssertTrue(
            MPVMoltenVKDevicePolicy.shouldDisableMetalArgumentBuffers(
                supportsApple5: false,
                supportsApple6: false
            )
        )
        XCTAssertTrue(
            MPVMoltenVKDevicePolicy.shouldDisableMetalArgumentBuffers(
                supportsApple5: true,
                supportsApple6: false
            )
        )
        XCTAssertFalse(
            MPVMoltenVKDevicePolicy.shouldDisableMetalArgumentBuffers(
                supportsApple5: true,
                supportsApple6: true,
                hasImportedMetalTextureResidencyFix: true
            )
        )
        XCTAssertTrue(
            MPVMoltenVKDevicePolicy.shouldDisableMetalArgumentBuffers(
                supportsApple5: true,
                supportsApple6: false,
                hasImportedMetalTextureResidencyFix: true
            )
        )
        XCTAssertFalse(
            MPVMoltenVKDevicePolicy.allowsAsynchronousMetalTextureImport(
                metalArgumentBuffersEnabled: true
            )
        )
        XCTAssertTrue(
            MPVMoltenVKDevicePolicy.allowsAsynchronousMetalTextureImport(
                metalArgumentBuffersEnabled: false
            )
        )
        XCTAssertTrue(
            MPVMoltenVKDevicePolicy.allowsAsynchronousMetalTextureImport(
                metalArgumentBuffersEnabled: true,
                hasImportedMetalTextureResidencyFix: true
            )
        )
        XCTAssertTrue(
            MPVMoltenVKDevicePolicy.shouldAvoidInlineGPUOnIPad(
                isPad: true,
                supportsApple5: true,
                supportsApple6: false
            )
        )
        XCTAssertFalse(
            MPVMoltenVKDevicePolicy.shouldAvoidInlineGPUOnIPad(
                isPad: false,
                supportsApple5: true,
                supportsApple6: false
            )
        )
        XCTAssertFalse(
            MPVMoltenVKDevicePolicy.shouldAvoidInlineGPUOnIPad(
                isPad: true,
                supportsApple5: true,
                supportsApple6: true
            )
        )
    }

    func testNativePiPProbeWaitsForMatchingFileAndVideoReadinessAndRunsOnce() {
        var gate = MPVNativePiPProbeGate()
        gate.beginLoad(sequence: 7)

        XCTAssertNil(gate.requestProbe(loadSequence: 7, preparationGeneration: 11))
        XCTAssertNil(gate.markVideoReconfigured(loadSequence: 7))
        XCTAssertEqual(gate.markFileLoaded(loadSequence: 7), 11)
        XCTAssertTrue(gate.didConsumeProbe)

        XCTAssertNil(gate.requestProbe(loadSequence: 7, preparationGeneration: 12))
        XCTAssertNil(gate.markVideoReconfigured(loadSequence: 7))
        XCTAssertNil(gate.markFileLoaded(loadSequence: 7))
    }

    func testNativePiPProbeRejectsStaleLoadEventsAndPreservesLatestLoadCancellation() {
        var gate = MPVNativePiPProbeGate()
        gate.beginLoad(sequence: 21)
        XCTAssertNil(gate.requestProbe(loadSequence: 21, preparationGeneration: 31))

        gate.beginLoad(sequence: 22)
        XCTAssertNil(gate.markFileLoaded(loadSequence: 21))
        XCTAssertNil(gate.markVideoReconfigured(loadSequence: 21))
        XCTAssertNil(gate.requestProbe(loadSequence: 22, preparationGeneration: 32))
        XCTAssertNil(gate.markFileLoaded(loadSequence: 22))
        gate.cancelPreparation(generation: 32)
        XCTAssertNil(gate.markVideoReconfigured(loadSequence: 22))
        XCTAssertFalse(gate.didConsumeProbe)

        XCTAssertEqual(gate.requestProbe(loadSequence: 22, preparationGeneration: 33), 33)
        XCTAssertTrue(gate.didConsumeProbe)
    }

    func testRenderLifecycleFenceRejectsOldWorkAcrossLoadAndStop() {
        let fence = MPVRenderLifecycleFence()
        fence.update(engineGeneration: 3, loadGeneration: 7, isRunning: true, isStopping: false)
        XCTAssertTrue(fence.accepts(engineGeneration: 3, loadGeneration: 7))
        XCTAssertFalse(fence.accepts(engineGeneration: 3, loadGeneration: 6))

        fence.update(engineGeneration: 3, loadGeneration: 8, isRunning: true, isStopping: false)
        XCTAssertFalse(fence.accepts(engineGeneration: 3, loadGeneration: 7))
        XCTAssertTrue(fence.accepts(engineGeneration: 3, loadGeneration: 8))

        fence.update(engineGeneration: 4, loadGeneration: 8, isRunning: false, isStopping: true)
        XCTAssertFalse(fence.accepts(engineGeneration: 3, loadGeneration: 8))
        XCTAssertFalse(fence.accepts(engineGeneration: 4, loadGeneration: 8))
    }

    func testDrawablePixelLimitAlwaysHonorsPlatformMaximum() {
        XCTAssertEqual(
            MPVDrawablePixelLimit.resolved(configured: 0, platformMaximum: 8_294_400),
            8_294_400
        )
        XCTAssertEqual(
            MPVDrawablePixelLimit.resolved(configured: 20_000_000, platformMaximum: 8_294_400),
            8_294_400
        )
        XCTAssertEqual(
            MPVDrawablePixelLimit.resolved(configured: 4_000_000, platformMaximum: 8_294_400),
            4_000_000
        )
        XCTAssertEqual(MPVDrawablePixelLimit.resolved(configured: 4, platformMaximum: 3), 3)
    }

    func testPictureInPictureRenderSizeUsesWindowAspectAtConfiguredQuality() {
        let maximum = CGSize(width: 1280, height: 720)
        let common = { (requested: CGSize) in
            MPVPictureInPictureRenderSizePolicy.resolved(
                requested: requested,
                maximum: maximum,
                textureDimensionLimit: 16_384,
                pixelLimit: 8_294_400
            )
        }

        XCTAssertEqual(common(CGSize(width: 251, height: 141)), CGSize(width: 1280, height: 719))
        XCTAssertEqual(common(CGSize(width: 4, height: 3)), CGSize(width: 960, height: 720))
        XCTAssertEqual(common(CGSize(width: 9, height: 16)), CGSize(width: 405, height: 720))
        XCTAssertEqual(common(maximum), maximum)
        XCTAssertEqual(common(.zero), maximum)
    }

    func testPictureInPictureRenderSizeHonorsTextureAndPixelCeilings() {
        let result = MPVPictureInPictureRenderSizePolicy.resolved(
            requested: CGSize(width: 16, height: 9),
            maximum: CGSize(width: 4000, height: 4000),
            textureDimensionLimit: 2048,
            pixelLimit: 1_000_000
        )

        XCTAssertLessThanOrEqual(result.width, 2048)
        XCTAssertLessThanOrEqual(result.height, 2048)
        XCTAssertLessThanOrEqual(result.width * result.height, 1_000_000)
        XCTAssertEqual(result, CGSize(width: 1333, height: 750))
    }

    func testPictureInPicturePoolHysteresisRejectsJitterButAcceptsRealChanges() {
        let landscape = CGSize(width: 1280, height: 720)
        XCTAssertFalse(
            MPVPictureInPictureRenderSizePolicy.shouldReplacePool(
                current: landscape,
                proposed: CGSize(width: 1280, height: 719)
            )
        )
        XCTAssertFalse(
            MPVPictureInPictureRenderSizePolicy.shouldReplacePool(
                current: landscape,
                proposed: CGSize(width: 1275, height: 720)
            )
        )
        XCTAssertTrue(
            MPVPictureInPictureRenderSizePolicy.shouldReplacePool(
                current: landscape,
                proposed: CGSize(width: 960, height: 720)
            )
        )
        XCTAssertTrue(
            MPVPictureInPictureRenderSizePolicy.shouldReplacePool(
                current: landscape,
                proposed: CGSize(width: 405, height: 720)
            )
        )
        XCTAssertTrue(
            MPVPictureInPictureRenderSizePolicy.shouldReplacePool(
                current: landscape,
                proposed: CGSize(width: 640, height: 360)
            )
        )
    }

    func testVideoToolboxDecodePolicyRecognizesDirectAndCopyPaths() {
        XCTAssertTrue(MPVVideoToolboxDecodePolicy.isConfigured("videotoolbox"))
        XCTAssertTrue(MPVVideoToolboxDecodePolicy.isConfigured(" videotoolbox , videotoolbox-copy "))
        XCTAssertTrue(MPVVideoToolboxDecodePolicy.isConfigured("auto,videotoolbox-copy"))
        XCTAssertFalse(MPVVideoToolboxDecodePolicy.isConfigured("no"))
        XCTAssertFalse(MPVVideoToolboxDecodePolicy.isConfigured("auto"))

        XCTAssertTrue(MPVVideoToolboxDecodePolicy.isEngaged("videotoolbox"))
        XCTAssertTrue(MPVVideoToolboxDecodePolicy.isEngaged(" VideoToolbox-Copy "))
        XCTAssertFalse(MPVVideoToolboxDecodePolicy.isEngaged(""))
        XCTAssertFalse(MPVVideoToolboxDecodePolicy.isEngaged("no"))

        XCTAssertEqual(
            MPVVideoToolboxDecodePolicy.recoverySetting(
                configuredDecoders: "videotoolbox,videotoolbox-copy",
                strategy: .configuredOrder
            ),
            "videotoolbox,videotoolbox-copy"
        )
        XCTAssertEqual(
            MPVVideoToolboxDecodePolicy.recoverySetting(
                configuredDecoders: "videotoolbox,videotoolbox-copy",
                strategy: .copyOnly
            ),
            "videotoolbox-copy"
        )
        XCTAssertEqual(
            MPVVideoToolboxDecodePolicy.recoverySetting(
                configuredDecoders: "no, VideoToolbox, auto, videotoolbox-copy, videotoolbox",
                strategy: .configuredOrder
            ),
            "videotoolbox,videotoolbox-copy"
        )
        XCTAssertEqual(
            MPVVideoToolboxDecodePolicy.recoverySetting(
                configuredDecoders: "auto,videotoolbox-copy,no",
                strategy: .configuredOrder
            ),
            "videotoolbox-copy"
        )
        XCTAssertNil(
            MPVVideoToolboxDecodePolicy.recoverySetting(
                configuredDecoders: "no",
                strategy: .copyOnly
            )
        )
        XCTAssertNil(
            MPVVideoToolboxDecodePolicy.recoverySetting(
                configuredDecoders: "videotoolbox",
                strategy: .copyOnly
            )
        )
    }

    func testHardwareDecoderRecoveryProofRequiresFreshSignalsInEitherOrder() {
        var reconfigureFirst = MPVHardwareDecoderRecoveryProof()
        XCTAssertFalse(reconfigureFirst.observeVideoReconfiguration())
        XCTAssertTrue(reconfigureFirst.observeHardwareDecoder("videotoolbox"))
        XCTAssertFalse(reconfigureFirst.observeHardwareDecoder("videotoolbox-copy"))

        var decoderFirst = MPVHardwareDecoderRecoveryProof()
        XCTAssertFalse(decoderFirst.observeHardwareDecoder(" VideoToolbox-Copy "))
        XCTAssertTrue(decoderFirst.observeVideoReconfiguration())
        XCTAssertFalse(decoderFirst.observeVideoReconfiguration())
    }

    func testHardwareDecoderRecoveryProofRejectsStaleOrDisengagedDecoderState() {
        var proof = MPVHardwareDecoderRecoveryProof()

        // A value cached before the recovery epoch is deliberately absent from a fresh proof.
        XCTAssertFalse(proof.observeVideoReconfiguration())
        XCTAssertFalse(proof.observeHardwareDecoder("no"))
        XCTAssertTrue(proof.observeHardwareDecoder("videotoolbox"))

        proof.reset()
        XCTAssertFalse(proof.observeHardwareDecoder("videotoolbox"))
        XCTAssertFalse(proof.observeHardwareDecoder(nil))
        XCTAssertFalse(proof.observeVideoReconfiguration())
        XCTAssertTrue(proof.observeHardwareDecoder("videotoolbox-copy"))
    }

    func testHardwareDecoderRecoveryProofPublishesCausalNegativeObservation() {
        var proof = MPVHardwareDecoderRecoveryProof()

        XCTAssertNil(proof.completedDecoderObservation)
        XCTAssertFalse(proof.observeHardwareDecoder("no"))
        XCTAssertNil(proof.completedDecoderObservation)
        XCTAssertFalse(proof.observeVideoReconfiguration())
        XCTAssertEqual(proof.completedDecoderObservation, .decoder("no"))

        XCTAssertTrue(proof.observeHardwareDecoder("videotoolbox-copy"))
        XCTAssertEqual(proof.completedDecoderObservation, .decoder("videotoolbox-copy"))

        proof.reset()
        XCTAssertNil(proof.completedDecoderObservation)
    }

    func testPlaylistEntryIdentityMakesRapidReplacementLatestWins() throws {
        var tracker = MPVLoadIdentityTracker()
        let loadA = tracker.submit(clientGeneration: 41)
        tracker.bind(playlistEntryID: 7001, to: loadA)
        let loadB = tracker.submit(clientGeneration: 42)
        tracker.bind(playlistEntryID: 7002, to: loadB)

        // START_FILE for A may already be copied but not delivered to the main actor when B is
        // submitted. Exact playlist IDs keep the two callbacks independent of delivery latency.
        XCTAssertEqual(tracker.didStart(playlistEntryID: 7001), loadA)
        let staleLoaded = try XCTUnwrap(tracker.identity(forPlaylistEntryID: 7001))
        XCTAssertFalse(tracker.isLatest(staleLoaded))

        XCTAssertEqual(tracker.didStart(playlistEntryID: 7002), loadB)
        let currentLoaded = try XCTUnwrap(tracker.identity(forPlaylistEntryID: 7002))
        XCTAssertTrue(tracker.isLatest(currentLoaded))
        XCTAssertEqual(currentLoaded.clientGeneration, 42)
    }

    func testLoadIdentityFallsBackToSubmissionOrderAndSupportsRedirect() {
        var tracker = MPVLoadIdentityTracker()
        let load = tracker.submit(clientGeneration: 8)
        XCTAssertEqual(tracker.didStart(playlistEntryID: 101), load)
        XCTAssertEqual(tracker.didEnd(playlistEntryID: 101), load)
        XCTAssertEqual(
            tracker.didStart(playlistEntryID: 102),
            load,
            "a redirect start without a second host load retains the original identity"
        )
    }

    func testRepeatedDefaultClientGenerationStillHasDistinctLoadIdentity() {
        var tracker = MPVLoadIdentityTracker()
        let loadA = tracker.submit(clientGeneration: 0)
        tracker.bind(playlistEntryID: 1, to: loadA)
        let loadB = tracker.submit(clientGeneration: 0)
        tracker.bind(playlistEntryID: 2, to: loadB)

        XCTAssertNotEqual(loadA.sequence, loadB.sequence)
        XCTAssertEqual(loadA.clientGeneration, loadB.clientGeneration)
        XCTAssertFalse(tracker.isLatest(loadA))
        XCTAssertTrue(tracker.isLatest(loadB))
    }

    func testCancelledDelayedLoadCannotConsumeReplacementStartEvent() {
        var tracker = MPVLoadIdentityTracker()
        let delayedA = tracker.submit(clientGeneration: 1)
        tracker.cancel(delayedA)
        let loadB = tracker.submit(clientGeneration: 2)

        XCTAssertEqual(tracker.didStart(playlistEntryID: 77), loadB)
        XCTAssertTrue(tracker.isLatest(loadB))
    }

    func testReservedLoadCannotConsumeStartBeforePhysicalSubmission() {
        var tracker = MPVLoadIdentityTracker()
        let loadA = tracker.submit(clientGeneration: 1)
        tracker.bind(playlistEntryID: 70, to: loadA)
        XCTAssertEqual(tracker.didStart(playlistEntryID: 70), loadA)

        let reservedB = tracker.reserve(clientGeneration: 2)
        XCTAssertEqual(
            tracker.didStart(playlistEntryID: 71),
            loadA,
            "an old item's redirect cannot consume a merely logical replacement"
        )
        XCTAssertFalse(tracker.isLatest(loadA))

        XCTAssertTrue(tracker.submit(reservedB))
        XCTAssertEqual(tracker.didStart(playlistEntryID: 72), reservedB)
        XCTAssertTrue(tracker.isLatest(reservedB))
    }

    func testSupersededReservationCannotBeSubmittedLater() {
        var tracker = MPVLoadIdentityTracker()
        let reservedA = tracker.reserve(clientGeneration: 1)
        let reservedB = tracker.reserve(clientGeneration: 2)

        XCTAssertFalse(tracker.submit(reservedA))
        XCTAssertTrue(tracker.submit(reservedB))
        XCTAssertEqual(tracker.didStart(playlistEntryID: 90), reservedB)
    }

    func testExactReplacementStartDiscardsOlderUnboundFallbackIdentity() {
        var tracker = MPVLoadIdentityTracker()
        _ = tracker.submit(clientGeneration: 1) // A never receives START_FILE.
        let loadB = tracker.submit(clientGeneration: 2)
        tracker.bind(playlistEntryID: 80, to: loadB)

        XCTAssertEqual(tracker.didStart(playlistEntryID: 80), loadB)
        XCTAssertEqual(tracker.didEnd(playlistEntryID: 80), loadB)
        XCTAssertEqual(
            tracker.didStart(playlistEntryID: 81),
            loadB,
            "B's redirect must not consume A's superseded fallback identity"
        )
    }

    func testDeferredLoadActionsAreClearedAndStaleFileLoadedCannotDrainReplacement() {
        var actions = MPVGenerationDeferredActions<String>()
        actions.beginGeneration(1)
        XCTAssertTrue(actions.append("A subtitle", generation: 1))

        actions.beginGeneration(2)
        XCTAssertTrue(actions.append("B style", generation: 2))
        XCTAssertEqual(actions.drain(generation: 1), [])
        XCTAssertEqual(actions.drain(generation: 2), ["B style"])
    }

    func testUnscopedOldFilePropertiesCannotEscapeReplacementFence() {
        let fileScoped = [
            "duration", "time-pos", "video-pts", "estimated-vf-fps", "track-list", "vid", "sid", "aid",
            "video-params/primaries", "video-params/gamma", "video-params/sig-peak", "seeking"
        ]
        for property in fileScoped {
            XCTAssertFalse(
                MPVLoadPropertyFence.shouldAccept(
                    property: property,
                    hasPlaylistEntryID: false,
                    awaitingFileLoaded: true
                ),
                property
            )
            XCTAssertTrue(
                MPVLoadPropertyFence.shouldAccept(
                    property: property,
                    hasPlaylistEntryID: true,
                    awaitingFileLoaded: true
                ),
                property
            )
        }
        for property in ["pause", "paused-for-cache", "speed"] {
            XCTAssertTrue(
                MPVLoadPropertyFence.shouldAccept(
                    property: property,
                    hasPlaylistEntryID: false,
                    awaitingFileLoaded: true
                ),
                property
            )
        }
    }

    func testCompatibilityVideoSelectionRestoresTrackChangedWhileInlineIsSuppressed() {
        var selection = MPVCompatibilityVideoSelectionState()
        selection.observePrimarySelection("4")

        XCTAssertEqual(selection.suppressInline(observedPrimarySelection: "4"), "no")
        XCTAssertTrue(selection.isInlineSuppressed)
        XCTAssertNil(selection.select("7"), "a PiP track change must not re-enable primary video")
        XCTAssertEqual(selection.desiredSelection, "7")
        XCTAssertEqual(selection.restoreInline(), "7")
        XCTAssertFalse(selection.isInlineSuppressed)
        XCTAssertNil(selection.restoreInline(), "duplicate exit/failure callbacks are idempotent")
    }

    func testCompatibilityVideoSelectionDoesNotRememberTemporaryNoAcrossLoads() {
        var selection = MPVCompatibilityVideoSelectionState()
        selection.observePrimarySelection("2")
        XCTAssertEqual(selection.suppressInline(observedPrimarySelection: "2"), "no")
        selection.observePrimarySelection("no")
        XCTAssertEqual(selection.desiredSelection, "2")

        XCTAssertEqual(selection.beginLoad(), "auto")
        XCTAssertEqual(selection.desiredSelection, "auto")
        XCTAssertFalse(selection.isInlineSuppressed)
    }

    func testTenThousandRequestsCoalesceToOneScheduledWorkItem() {
        var scheduler = MPVFrameDemandScheduler(minimumFrameInterval: 1.0 / 24.0)
        let generation = scheduler.beginGeneration()
        for _ in 0..<10_000 {
            _ = scheduler.request(generation: generation)
            if scheduler.canSchedule {
                XCTAssertTrue(scheduler.markWorkScheduled(generation: generation))
            }
        }
        XCTAssertTrue(scheduler.isWorkScheduled)
        XCTAssertEqual(scheduler.coalescedRequestCount, 9_999)
        XCTAssertEqual(scheduler.consume(at: 10, generation: generation)?.isForced, false)
    }

    func testForcedRequestsAreBoundedToImmediateAttemptAndOneRetry() {
        var scheduler = MPVFrameDemandScheduler(maximumForcedBudget: 2, minimumFrameInterval: 0)
        let generation = scheduler.beginGeneration()
        for _ in 0..<100 {
            _ = scheduler.request(forcedCount: 20, generation: generation)
        }
        XCTAssertEqual(scheduler.forcedBudget, 2)
        XCTAssertTrue(scheduler.markWorkScheduled(generation: generation))
        XCTAssertEqual(scheduler.consume(at: 0, generation: generation)?.isForced, true)
        XCTAssertTrue(scheduler.markWorkScheduled(generation: generation))
        XCTAssertEqual(scheduler.consume(at: 0, generation: generation)?.isForced, true)
        XCTAssertFalse(scheduler.canSchedule)
    }

    func testLegacyPrimeBudgetCannotBeReplenishedByAlternatingRequestsAndRenders() {
        var budget = MPVLegacyPrimeBudget(capacity: 2)
        var renderAttempts = 0
        for _ in 0..<100 {
            renderAttempts += budget.consume(requested: 20)
        }
        XCTAssertEqual(renderAttempts, 2)
        XCTAssertEqual(budget.remaining, 0)
        budget.reset()
        XCTAssertEqual(budget.consume(requested: 1), 1)
        XCTAssertEqual(budget.consume(requested: 1), 1)
        XCTAssertEqual(budget.consume(requested: 1), 0)
    }

    func testInternalForcedDemandCanBeRequestedAgainAfterPriorWorkCompletes() {
        var scheduler = MPVFrameDemandScheduler(maximumForcedBudget: 2, minimumFrameInterval: 0)
        let generation = scheduler.beginGeneration()
        var renderAttempts = 0
        for step in 0..<10 {
            _ = scheduler.request(forcedCount: 1, generation: generation)
            if scheduler.markWorkScheduled(generation: generation),
               scheduler.consume(at: TimeInterval(step), generation: generation) != nil {
                renderAttempts += 1
            }
        }
        XCTAssertEqual(renderAttempts, 10)
        XCTAssertEqual(scheduler.forcedBudget, 0)
    }

    func testBackpressureRetainsOnlyLatestDemand() {
        var scheduler = MPVFrameDemandScheduler(minimumFrameInterval: 0)
        let generation = scheduler.beginGeneration()
        _ = scheduler.request(generation: generation)
        scheduler.waitForReadiness(generation: generation)
        for _ in 0..<1_000 { _ = scheduler.request(generation: generation) }
        XCTAssertFalse(scheduler.canSchedule)
        XCTAssertTrue(scheduler.becomeReady(generation: generation))
        XCTAssertEqual(scheduler.backpressureCount, 1)
    }

    func testStaleGenerationCannotProduceWork() {
        var scheduler = MPVFrameDemandScheduler(minimumFrameInterval: 0)
        let old = scheduler.beginGeneration()
        let current = scheduler.beginGeneration()
        XCTAssertFalse(scheduler.request(generation: old))
        XCTAssertTrue(scheduler.request(generation: current))
        XCTAssertEqual(scheduler.staleGenerationCount, 1)
    }

    func testTimelineRatesAndDiscontinuities() {
        var timeline = MPVSampleTimeline()
        timeline.updatePlayback(paused: false, rate: 1.5)
        XCTAssertEqual(timeline.evaluate(pts: 10, fallbackPTS: 0), .enqueue(pts: 10, epoch: 0, flush: true, rate: 1.5))
        timeline.didEnqueue(pts: 10, epoch: 0)
        XCTAssertEqual(timeline.evaluate(pts: 10, fallbackPTS: 0), .dropDuplicate)
        XCTAssertEqual(timeline.evaluate(pts: 4, fallbackPTS: 0), .enqueue(pts: 4, epoch: 1, flush: true, rate: 1.5))
        timeline.updatePlayback(buffering: true)
        XCTAssertEqual(timeline.effectiveRate, 0)
    }

    func testPausedRefreshCreatesNewEpoch() {
        var timeline = MPVSampleTimeline()
        XCTAssertEqual(timeline.evaluate(pts: 5, fallbackPTS: 0), .enqueue(pts: 5, epoch: 0, flush: true, rate: 0))
        timeline.didEnqueue(pts: 5, epoch: 0)
        XCTAssertEqual(
            timeline.evaluate(pts: 5, fallbackPTS: 0, allowsPausedRefresh: true),
            .enqueue(pts: 5, epoch: 1, flush: true, rate: 0)
        )
    }

    func testBoundedPoolNeverExceedsThree() {
        var pool = MPVBoundedFramePool(capacity: 3)
        let generation = pool.beginGeneration()
        XCTAssertTrue(pool.acquire(generation: generation))
        XCTAssertTrue(pool.acquire(generation: generation))
        XCTAssertTrue(pool.acquire(generation: generation))
        XCTAssertFalse(pool.acquire(generation: generation))
        XCTAssertEqual(pool.inFlightCount, 3)
        XCTAssertEqual(pool.exhaustionCount, 1)
    }

    func testResizeRejectsNonFiniteAndCapsPixels() throws {
        let policy = MPVResizePolicy(maximumPixelCount: 8_294_400, maximumDimension: 4_096)
        XCTAssertNil(policy.resolve(MPVPixelSize(width: .nan, height: 100), previous: nil))
        XCTAssertNil(policy.resolve(MPVPixelSize(width: 0, height: 100), previous: nil))
        let resolved = try XCTUnwrap(policy.resolve(MPVPixelSize(width: 20_000, height: 10_000), previous: nil))
        XCTAssertLessThanOrEqual(resolved.width * resolved.height, 8_294_400)
        XCTAssertLessThanOrEqual(resolved.width, 4_096)
    }

    func testLifecycleRejectsStartDuringTeardown() throws {
        var lifecycle = MPVRendererLifecycle()
        let generation = try XCTUnwrap(lifecycle.start())
        XCTAssertEqual(lifecycle.beginStopping(), generation)
        XCTAssertNil(lifecycle.start())
        lifecycle.finishStopping(generation: generation)
        XCTAssertNotNil(lifecycle.start())
    }

    func testPauseBufferingSpeedAndSeekMatrix() {
        let cases: [(paused: Bool, buffering: Bool, speed: Double, expectedRate: Double)] = [
            (true, false, 0.5, 0),
            (true, true, 2, 0),
            (false, true, 1.5, 0),
            (false, false, 0.5, 0.5),
            (false, false, 1, 1),
            (false, false, 1.5, 1.5),
            (false, false, 2, 2),
        ]
        for item in cases {
            var timeline = MPVSampleTimeline()
            timeline.updatePlayback(paused: item.paused, buffering: item.buffering, rate: item.speed)
            guard case .enqueue(_, let epoch, _, let rate) = timeline.evaluate(pts: 100, fallbackPTS: 0) else {
                return XCTFail("expected an initial frame")
            }
            XCTAssertEqual(rate, item.expectedRate)
            timeline.didEnqueue(pts: 100, epoch: epoch)
            timeline.beginDiscontinuity()
            XCTAssertEqual(
                timeline.evaluate(pts: 10, fallbackPTS: 0),
                .enqueue(pts: 10, epoch: epoch + 1, flush: true, rate: item.expectedRate)
            )
        }
    }

    func testStaleFlushCompletionCannotEraseNewEpoch() {
        var flushes = MPVFlushEpochCoordinator()
        let old = flushes.beginFlush()
        XCTAssertEqual(flushes.beginEpoch(), 1)
        let current = flushes.beginFlush()
        XCTAssertFalse(flushes.complete(old))
        XCTAssertTrue(flushes.complete(current))
        XCTAssertFalse(flushes.complete(current), "a completion is single-use")
    }

    func testLatestGenerationWinsAcrossRapidReplacement() {
        var scheduler = MPVFrameDemandScheduler(minimumFrameInterval: 0)
        let first = scheduler.beginGeneration()
        let second = scheduler.beginGeneration()
        let third = scheduler.beginGeneration()
        XCTAssertFalse(scheduler.request(forcedCount: 2, generation: first))
        XCTAssertFalse(scheduler.request(forcedCount: 2, generation: second))
        XCTAssertTrue(scheduler.request(forcedCount: 2, generation: third))
        XCTAssertEqual(scheduler.staleGenerationCount, 2)
    }

    func testResizeRejectsAllHostileInputs() throws {
        let policy = MPVResizePolicy(maximumPixelCount: 8_294_400, maximumDimension: 4_096)
        let invalid: [MPVPixelSize] = [
            .init(width: .nan, height: 100),
            .init(width: .infinity, height: 100),
            .init(width: -.infinity, height: 100),
            .init(width: -1, height: 100),
            .init(width: 100, height: -1),
            .init(width: 0, height: 100),
            .init(width: 100, height: 0),
        ]
        invalid.forEach { XCTAssertNil(policy.resolve($0, previous: nil)) }
        let huge = try XCTUnwrap(policy.resolve(.init(width: Double.greatestFiniteMagnitude, height: 9_000), previous: nil))
        XCTAssertTrue(huge.width.isFinite)
        XCTAssertTrue(huge.height.isFinite)
        XCTAssertLessThanOrEqual(huge.width, 4_096)
        XCTAssertLessThanOrEqual(huge.width * huge.height, 8_294_400)
        let hugeSquare = try XCTUnwrap(
            policy.resolve(
                .init(width: Double.greatestFiniteMagnitude, height: Double.greatestFiniteMagnitude),
                previous: nil
            )
        )
        XCTAssertTrue(hugeSquare.width.isFinite)
        XCTAssertTrue(hugeSquare.height.isFinite)
        XCTAssertLessThanOrEqual(hugeSquare.width * hugeSquare.height, 8_294_400)
    }

    func testResizeRetiresThreeInFlightBuffersWithoutReuse() {
        var pool = MPVBoundedFramePool(capacity: 3)
        let old = pool.beginGeneration()
        XCTAssertTrue(pool.acquire(generation: old))
        XCTAssertTrue(pool.acquire(generation: old))
        XCTAssertTrue(pool.acquire(generation: old))
        let current = pool.beginGeneration()
        XCTAssertTrue(pool.isRetired(old))
        XCTAssertEqual(pool.retiredInFlightCount, 3)
        XCTAssertFalse(pool.acquire(generation: old), "a retired generation must never be reused")
        XCTAssertTrue(pool.acquire(generation: current), "the replacement pool has independent capacity")
        pool.release(generation: old)
        pool.release(generation: old)
        XCTAssertTrue(pool.isRetired(old))
        pool.release(generation: old)
        XCTAssertFalse(pool.isRetired(old), "retired storage drains only after its final owner releases")
    }

    func testStopRacingCallbackRejectsStaleGeneration() {
        var scheduler = MPVFrameDemandScheduler(minimumFrameInterval: 0)
        let running = scheduler.beginGeneration()
        XCTAssertTrue(scheduler.request(generation: running))
        XCTAssertTrue(scheduler.markWorkScheduled(generation: running))
        _ = scheduler.beginGeneration() // stop invalidates callback userdata before queue drain
        XCTAssertNil(scheduler.consume(at: 1, generation: running))
        XCTAssertFalse(scheduler.request(generation: running))
        XCTAssertEqual(scheduler.staleGenerationCount, 2)
    }

    func testTenSecondsOfBackpressureProducesExactlyOneLatestFrame() {
        var harness = FakeRendererHarness()
        harness.load()
        harness.displayIsReady = false
        harness.request(frameID: 0)
        harness.pump()
        for frameID in 1...100 {
            harness.advance(by: 0.1)
            harness.request(frameID: frameID)
            harness.pump()
        }
        XCTAssertEqual(harness.now, 10, accuracy: 0.0001)
        XCTAssertTrue(harness.gpuWork.isEmpty)
        XCTAssertEqual(harness.pool.inFlightCount, 0)

        harness.displayIsReady = true
        harness.pump()
        XCTAssertEqual(harness.gpuWork.map(\.frameID), [100])
        harness.completeGPUWork()
        XCTAssertEqual(harness.enqueuedFrameIDs, [100])
        XCTAssertTrue(harness.gpuWork.isEmpty)
    }

    func testNativeReadinessDemandDropsStaleFramesAndCoalescesOneFreshRender() {
        var demand = MPVLatestReadinessDemand()
        for _ in 0..<10_000 {
            _ = demand.request()
        }

        XCTAssertTrue(demand.isPending)
        XCTAssertEqual(demand.coalescedRequestCount, 9_999)
        XCTAssertTrue(demand.consume(), "readiness should release exactly one fresh render")
        XCTAssertFalse(demand.consume(), "duplicate readiness callbacks cannot render again")
    }

    func testNativeTargetDemandStopsAfterWarmupAndWhilePaused() {
        XCTAssertTrue(MPVNativePiPTargetDemand.shouldSubmit(
            mode: .warmup,
            forced: false,
            preparationCompleted: false,
            timelineRate: 0,
            restoreFramePending: false
        ))
        XCTAssertFalse(MPVNativePiPTargetDemand.shouldSubmit(
            mode: .warmup,
            forced: false,
            preparationCompleted: true,
            timelineRate: 1,
            restoreFramePending: false
        ), "a valid prewarm frame must not start a foreground render loop")
        XCTAssertFalse(MPVNativePiPTargetDemand.shouldSubmit(
            mode: .offscreen,
            forced: false,
            preparationCompleted: true,
            timelineRate: 0,
            restoreFramePending: false
        ), "paused and buffering PiP must perform no continuous GPU work")
        XCTAssertTrue(MPVNativePiPTargetDemand.shouldSubmit(
            mode: .offscreen,
            forced: false,
            preparationCompleted: true,
            timelineRate: 1.5,
            restoreFramePending: false
        ))
        XCTAssertTrue(MPVNativePiPTargetDemand.shouldSubmit(
            mode: .offscreen,
            forced: true,
            preparationCompleted: true,
            timelineRate: 0,
            restoreFramePending: false
        ), "a paused subtitle, seek, resize, or readiness edge gets exactly one forced frame")
        XCTAssertTrue(MPVNativePiPTargetDemand.shouldSubmit(
            mode: .restore,
            forced: false,
            preparationCompleted: true,
            timelineRate: 0,
            restoreFramePending: true
        ))
        XCTAssertFalse(MPVNativePiPTargetDemand.shouldSubmit(
            mode: .inline,
            forced: false,
            preparationCompleted: false,
            timelineRate: 1,
            restoreFramePending: false
        ))
    }

    func testNativeDiagnosticsThrottleEmitsFirstTransitionAndAtMostTwicePerSecond() {
        var throttle = MPVDiagnosticsEmissionThrottle(minimumInterval: 0.5)
        var emissions: [TimeInterval] = []
        for tick in 0..<100 {
            let time = TimeInterval(tick) / 100
            if throttle.shouldEmit(at: time) {
                emissions.append(time)
            }
        }
        XCTAssertEqual(emissions, [0, 0.5])
        XCTAssertTrue(throttle.shouldEmit(at: 0.51, materialChange: true))
        XCTAssertFalse(throttle.shouldEmit(at: 0.52))
        throttle.reset()
        XCTAssertTrue(throttle.shouldEmit(at: 0.52), "a new PiP cycle emits its first frame")
    }

    func testOneHundredRapidLoadReplacementsKeepOneGPUWorkItemAndLatestWins() {
        var harness = FakeRendererHarness()
        for loadID in 0..<100 {
            harness.load()
            harness.request(frameID: loadID)
            harness.pump()
        }
        XCTAssertEqual(harness.gpuWork.count, 1, "an old GPU completion must gate every replacement generation")
        XCTAssertLessThanOrEqual(harness.pool.trackedGenerationCount, 2)
        harness.completeGPUWork()
        XCTAssertEqual(harness.gpuWork.map(\.frameID), [99])
        XCTAssertTrue(harness.enqueuedFrameIDs.isEmpty)
        harness.completeGPUWork()
        XCTAssertEqual(harness.enqueuedFrameIDs, [99])
        XCTAssertEqual(harness.scheduler.inFlightCount, 0)
    }

    func testAllOldPoolBuffersCanCompleteAfterResizeWithoutPrematureReuse() {
        var pool = MPVBoundedFramePool(capacity: 3)
        let old = pool.beginGeneration()
        XCTAssertTrue(pool.acquire(generation: old))
        XCTAssertTrue(pool.acquire(generation: old))
        XCTAssertTrue(pool.acquire(generation: old))
        let current = pool.beginGeneration()
        XCTAssertTrue(pool.acquire(generation: current))
        XCTAssertTrue(pool.acquire(generation: current))
        XCTAssertTrue(pool.acquire(generation: current))
        XCTAssertEqual(pool.retiredInFlightCount, 3)
        pool.release(generation: old)
        pool.release(generation: old)
        XCTAssertTrue(pool.isRetired(old))
        XCTAssertEqual(pool.inFlightCount, 3)
        pool.release(generation: old)
        XCTAssertFalse(pool.isRetired(old))
        XCTAssertEqual(pool.inFlightCount, 3)
    }

    func testStopRacingGPUCompletionReleasesButNeverEnqueues() {
        var harness = FakeRendererHarness()
        harness.load()
        harness.request(frameID: 7)
        harness.pump()
        XCTAssertEqual(harness.gpuWork.count, 1)
        harness.stop()
        harness.completeGPUWork()
        XCTAssertTrue(harness.enqueuedFrameIDs.isEmpty)
        XCTAssertEqual(harness.scheduler.inFlightCount, 0)
        XCTAssertEqual(harness.pool.retiredInFlightCount, 0)
    }

    func testNativeInlineRestoreCallbackDoesNotRequireAnInFlightSurface() {
        XCTAssertEqual(
            MPVNativePiPCallbackDisposition.classify(
                token: 0,
                generation: 42,
                currentGeneration: 42,
                status: 0,
                readyStatus: 0
            ),
            .inlineRestored
        )
        XCTAssertEqual(
            MPVNativePiPCallbackDisposition.classify(
                token: 9,
                generation: 42,
                currentGeneration: 42,
                status: 0,
                readyStatus: 0
            ),
            .surfaceFrame(token: 9)
        )
        XCTAssertEqual(
            MPVNativePiPCallbackDisposition.classify(
                token: 0,
                generation: 41,
                currentGeneration: 42,
                status: 0,
                readyStatus: 0
            ),
            .stale
        )
        XCTAssertEqual(
            MPVNativePiPCallbackDisposition.classify(
                token: 9,
                generation: 41,
                currentGeneration: 42,
                status: 0,
                readyStatus: 0
            ),
            .surfaceFrame(token: 9),
            "surface callbacks must still release their retained buffer before stale-generation rejection"
        )
    }

    func testCompatibilityPlaybackFollowsAuthoritativeBufferingClock() {
        XCTAssertEqual(
            MPVCompatibilityPlaybackDecision.resolve(
                isPaused: false,
                isBuffering: true,
                primaryPosition: 40,
                secondaryPosition: 43,
                shouldRealign: false
            ),
            .init(shouldPause: true, seekPosition: nil)
        )
        XCTAssertEqual(
            MPVCompatibilityPlaybackDecision.resolve(
                isPaused: false,
                isBuffering: false,
                primaryPosition: 40,
                secondaryPosition: 43,
                shouldRealign: true
            ),
            .init(shouldPause: false, seekPosition: 40)
        )
        XCTAssertEqual(
            MPVCompatibilityPlaybackDecision.resolve(
                isPaused: true,
                isBuffering: false,
                primaryPosition: 40,
                secondaryPosition: 40.1,
                shouldRealign: true
            ),
            .init(shouldPause: true, seekPosition: nil)
        )
        XCTAssertEqual(
            MPVCompatibilityPlaybackDecision.resolve(
                isPaused: false,
                isBuffering: false,
                primaryPosition: 40,
                secondaryPosition: 40,
                shouldRealign: false,
                allowsPlayback: false
            ),
            .init(shouldPause: true, seekPosition: nil),
            "the compatibility renderer stays paused while PiP is only prepared"
        )
    }

    func testPoolAllocationDemandHasOneBoundedRetry() {
        var gate = MPVLatestDemandRetryGate()
        gate.beginDemand()
        gate.beginDemand()
        XCTAssertTrue(gate.consumeRetry())
        gate.beginDemand()
        XCTAssertFalse(gate.consumeRetry(), "coalesced demand must not replenish its retry")
        gate.replaceDemand()
        XCTAssertTrue(gate.consumeRetry())
        gate.complete()
        XCTAssertFalse(gate.isPending)
    }

    func testDisplayLayerRecoveryCoalescesOneContinuousFailureEpisode() {
        var gate = MPVDisplayLayerRecoveryGate()
        gate.beginGeneration(7)

        XCTAssertEqual(gate.observeFailure(generation: 7), .recover)
        for _ in 0..<10_000 {
            XCTAssertEqual(gate.observeFailure(generation: 7), .wait)
        }
        XCTAssertTrue(gate.blocksRendering(generation: 7))
        XCTAssertEqual(
            gate.complete(generation: 7, rendererRemainsFailed: false),
            .awaitingRendering
        )
        XCTAssertFalse(gate.blocksRendering(generation: 7))
        XCTAssertTrue(gate.isAwaitingRendering)
        XCTAssertTrue(gate.beginRenderingProbe(generation: 7))
        XCTAssertTrue(gate.blocksRendering(generation: 7))
        XCTAssertTrue(gate.finishRenderingProbeSubmission(generation: 7))
        XCTAssertTrue(gate.blocksRendering(generation: 7))
        XCTAssertTrue(gate.markRenderingSucceeded(generation: 7))
        XCTAssertEqual(
            gate.observeFailure(generation: 7),
            .recover,
            "a later failure after a successful reset is a new episode"
        )
    }

    func testDisplayLayerRecoveryReportsPersistentFailureOnceUntilNewGeneration() {
        var gate = MPVDisplayLayerRecoveryGate()
        gate.beginGeneration(11)
        XCTAssertEqual(gate.observeFailure(generation: 11), .recover)
        XCTAssertEqual(
            gate.complete(generation: 11, rendererRemainsFailed: true),
            .failed
        )
        for _ in 0..<10_000 {
            XCTAssertEqual(gate.observeFailure(generation: 11), .terminal)
        }
        XCTAssertTrue(gate.blocksRendering(generation: 11))

        gate.beginGeneration(12)
        XCTAssertFalse(gate.blocksRendering(generation: 12))
        XCTAssertEqual(gate.observeFailure(generation: 12), .recover)
        XCTAssertEqual(
            gate.complete(generation: 11, rendererRemainsFailed: false),
            .stale,
            "an old flush completion cannot reset the replacement generation"
        )
        gate.cancel()
        XCTAssertFalse(gate.blocksRendering(generation: 12))
        XCTAssertEqual(gate.observeFailure(generation: 12), .stale)
    }

    func testDisplayLayerRecoveryDoesNotFlushLoopBeforeReplacementSampleSucceeds() {
        var gate = MPVDisplayLayerRecoveryGate()
        gate.beginGeneration(21)
        XCTAssertEqual(gate.observeFailure(generation: 21), .recover)
        XCTAssertEqual(
            gate.complete(generation: 21, rendererRemainsFailed: false),
            .awaitingRendering
        )
        XCTAssertEqual(
            gate.observeFailure(generation: 21),
            .report,
            "failure before a replacement sample succeeds is the terminal result of this attempt"
        )
        XCTAssertEqual(gate.observeFailure(generation: 21), .terminal)
        XCTAssertTrue(gate.blocksRendering(generation: 21))
        XCTAssertFalse(gate.markRenderingSucceeded(generation: 20))
    }

    func testTimelineRecoveryFlushOnlySatisfiesItsExactEpoch() {
        var timeline = MPVSampleTimeline()
        timeline.beginDiscontinuity()
        let recoveryEpoch = timeline.epoch
        timeline.beginDiscontinuity()

        timeline.didFlush(epoch: recoveryEpoch)
        guard case .enqueue(_, let currentEpoch, let needsFlush, _) = timeline.evaluate(
            pts: 8,
            fallbackPTS: 0
        ) else {
            return XCTFail("expected a current-epoch frame")
        }
        XCTAssertEqual(currentEpoch, timeline.epoch)
        XCTAssertTrue(needsFlush, "an old recovery completion cannot clear a newer epoch")

        timeline.didFlush(epoch: currentEpoch)
        guard case .enqueue(_, _, let recoveredNeedsFlush, _) = timeline.evaluate(
            pts: 8,
            fallbackPTS: 0
        ) else {
            return XCTFail("expected the replacement frame")
        }
        XCTAssertFalse(recoveredNeedsFlush)
    }

    func testReleasePackageTemplatesAreFlavorSpecificAndResolved() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let lgpl = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/Package.template.swift"),
            encoding: .utf8
        )
        let gpl = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/Package.gpl.template.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(lgpl.contains("_url)"))
        XCTAssertFalse(lgpl.contains("_checksum)"))
        XCTAssertFalse(lgpl.contains("name: \"MPVKit-GPL\""))
        XCTAssertFalse(lgpl.contains("name: \"MPVKitSampleBuffer-GPL\""))
        XCTAssertFalse(gpl.contains("targets: [\"_MPVKit\", \"MPVKitSampleBuffer\"]"))
        XCTAssertFalse(gpl.contains("targets: [\"MPVKitSampleBuffer\"]"))
    }

    func testHDRSetupFailureFallsBackToTaggedSDRInBothFlavors() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for flavor in ["MPVKitSampleBufferGPL", "MPVKitSampleBuffer"] {
            let source = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources")
                    .appendingPathComponent(flavor)
                    .appendingPathComponent("MPVMetalSampleBufferRenderer.swift"),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.contains("forceSDR: hdrPresentationDisabled"),
                "\(flavor) must tag the BGRA fallback as SDR after HDR setup fails"
            )
        }
    }

    func testPiPPreparationRejectsAStoppedPrimaryRendererInBothFlavors() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runningGuard = "guard isRunning else { throw MPVGPUPlayerRendererError.rendererNotRunning }"

        for flavor in ["MPVKitSampleBufferGPL", "MPVKitSampleBuffer"] {
            let source = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Sources")
                    .appendingPathComponent(flavor)
                    .appendingPathComponent("MPVGPUPlayerRenderer.swift"),
                encoding: .utf8
            )
            let prepareStart = try XCTUnwrap(
                source.range(of: "public func preparePictureInPicture() async throws")
            )
            let prepareEnd = try XCTUnwrap(
                source.range(
                    of: "/// Compatibility entry point.",
                    range: prepareStart.upperBound..<source.endIndex
                )
            )
            let prepareImplementation = source[prepareStart.lowerBound..<prepareEnd.lowerBound]
            XCTAssertTrue(
                prepareImplementation.contains(runningGuard),
                "\(flavor) must not let a fallback mpv instance become authoritative before the primary renderer starts"
            )
            XCTAssertTrue(source.contains("case rendererNotRunning"))
        }
    }
}
