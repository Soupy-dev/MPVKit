import XCTest
@testable import MPVKitSampleBufferCore

@MainActor
private final class PreparedSubtitleHarness {
    var started: [MPVExternalSubtitlePreparation.Candidate] = []
    var pending: [String: CheckedContinuation<MPVExternalSubtitlePreparationResult, Never>] = [:]
    var commands: [[String]] = []
    var replies: [MPVAsyncCommandReply] = []
    var ids = [1, 2]
    var selected = 2
    lazy var preparation = MPVExternalSubtitlePreparation { [weak self] candidate in
        await withCheckedContinuation { continuation in
            self?.started.append(candidate)
            self?.pending[candidate.request.url] = continuation
        }
    }
    lazy var queue = MPVExternalSubtitleQueue(
        submit: { [weak self] arguments in
            let reply = MPVAsyncCommandReply()
            self?.commands.append(arguments)
            self?.replies.append(reply)
            return reply
        },
        trackIDs: { [weak self] in self?.ids ?? [] },
        selectedTrackID: { [weak self] in self?.selected ?? -1 },
        applySelection: { [weak self] in self?.selected = $0 },
        didChange: {}, preparation: preparation
    )

    func prepared(_ url: String, bytes: Int = 100) {
        pending.removeValue(forKey: url)?.resume(returning: .prepared(.init(nativeURL: "/tmp/" + url, byteCount: bytes)))
    }

    func clear() {
        queue.beginGeneration()
        for continuation in pending.values { continuation.resume(returning: .failed) }
        pending.removeAll()
        for reply in replies { reply.complete(-1) }
    }
}

final class MPVExternalSubtitlePreparationTests: XCTestCase {
    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<5_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Preparation did not reach expected state")
        throw NSError(domain: "SubtitlePreparationTests", code: 1)
    }

    func testIdentityPreservesExactURLAndCanonicalHeaderValues() {
        let first = MPVExternalSubtitleRequest(url: "https://example.test/A?sig=one", headers: ["Authorization": "first"])
        XCTAssertEqual(first, .init(url: first.url, headers: ["authorization": "first"]))
        XCTAssertNotEqual(first, .init(url: "https://example.test/a?sig=one", headers: ["Authorization": "first"]))
        XCTAssertNotEqual(first, .init(url: "https://example.test/A?sig=two", headers: ["Authorization": "first"]))
        XCTAssertNotEqual(first, .init(url: first.url, headers: ["Authorization": "second"]))
        XCTAssertFalse(MPVExternalSubtitleRequest(url: first.url, headers: ["Cookie": "a\r\nb"]).canPrepare)
        XCTAssertFalse(MPVExternalSubtitleRequest(url: "https://example.test/sub.idx").canPrepare)
    }

    func testExplicitEmptyHeadersAndCrossOriginDoNotInheritMediaCredentials() throws {
        let media = try XCTUnwrap(URL(string: "https://example.test/video"))
        let same = "https://example.test/sub.srt"
        func request(_ url: String, _ supplied: [String: [String: String]]?) -> MPVExternalSubtitleRequest {
            .make(url: url, headersByURL: supplied, mediaURL: media, mediaHeaders: ["Authorization": "secret"],
                  userAgent: "mpv-agent", referrer: "https://ref.test/", permitsPreparation: true)
        }
        XCTAssertTrue(request(same, nil).headers.contains { $0.name == "authorization" })
        XCTAssertFalse(request(same, [same: [:]]).headers.contains { $0.name == "authorization" })
        XCTAssertFalse(request("https://other.test/sub.srt", nil).headers.contains { $0.name == "authorization" })
        XCTAssertTrue(request(same, [same: [:]]).headers.contains { $0.name == "user-agent" && $0.value == "mpv-agent" })
        let crossOrigin = "https://other.test/sub.srt"
        XCTAssertFalse(request(crossOrigin, nil).canPrepare)
        XCTAssertTrue(request(crossOrigin, [crossOrigin: [:]]).canPrepare)
        XCTAssertTrue(request(crossOrigin, [crossOrigin: ["Authorization": "subtitle-specific"]]).canPrepare)
        XCTAssertFalse(MPVExternalSubtitleRequest(url: "https://example.test/caption.sup").canPrepare)
        XCTAssertFalse(MPVExternalSubtitleRequest(url: "https://example.test/caption.ttml").canPrepare)
    }

    func testCrossOriginRedirectNeverReintroducesCredentialsOnSubsequentHop() throws {
        let original = try XCTUnwrap(URL(string: "https://origin.test/sub.srt"))
        let target = try XCTUnwrap(URL(string: "https://cdn.test/sub.srt"))
        let headers = MPVExternalSubtitleRequest(url: original.absoluteString,
            headers: ["Authorization": "secret", "Cookie": "secret", "User-Agent": "agent"]).headers
        var proposed = URLRequest(url: target)
        proposed.setValue("secret", forHTTPHeaderField: "Authorization")
        let redirected = MPVExternalSubtitleDownload.redirectedRequest(proposed, from: original, headers: headers)
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "User-Agent"), "agent")
        let again = MPVExternalSubtitleDownload.redirectedRequest(redirected, from: original, headers: headers)
        XCTAssertNil(again.value(forHTTPHeaderField: "Authorization"))
        let same = MPVExternalSubtitleDownload.redirectedRequest(URLRequest(url: original), from: original, headers: headers)
        XCTAssertEqual(same.value(forHTTPHeaderField: "Authorization"), "secret")
    }

    func testTextValidationAndTemporaryFileLifetime() throws {
        let content = Data("1\n00:00:01,000 --> 00:00:03,000\nCaption\n".utf8)
        var result: MPVExternalSubtitlePreparationResult? = MPVExternalSubtitleDownload.prepare(content, originalURL: "https://example.test/get?id=1")
        let path: String
        if case .prepared(let asset) = result {
            path = asset.nativeURL
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), content)
            XCTAssertEqual(asset.byteCount, content.count)
        } else {
            XCTFail("Valid timed subtitle was rejected")
            return
        }
        result = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        for body in ["", "<html>Server unavailable</html>", "<!doctype html>failure", "{\"error\":true}"] {
            if case .failed = MPVExternalSubtitleDownload.prepare(Data(body.utf8), originalURL: "https://example.test/sub.srt") {} else {
                XCTFail("Invalid subtitle response accepted")
            }
        }
        if case .prepared(let asset) = MPVExternalSubtitleDownload.prepare(Data("#EXTM3U\npart.ts".utf8), originalURL: "https://example.test/sub") {
            XCTAssertEqual(asset.nativeURL, "https://example.test/sub")
            XCTAssertEqual(asset.byteCount, 0)
        } else { XCTFail("Unsupported native format did not retain fallback") }
    }

    @MainActor
    func testNewestExplicitBypassesUnpreparedBackgroundAndNativeReplyRemainsBarrier() async throws {
        let h = PreparedSubtitleHarness()
        defer { h.clear() }
        h.queue.setReady()
        h.queue.enqueue(.init(urls: ["slow", "next"], names: nil, selectFirst: false))
        try await waitUntil { h.pending["slow"] != nil }
        h.queue.enqueue(.init(urls: ["chosen"], names: ["Chosen"], selectFirst: true))
        try await waitUntil { h.pending["chosen"] != nil }
        h.prepared("chosen")
        try await waitUntil { h.commands.count == 1 }
        XCTAssertEqual(h.commands[0], ["sub-add", "/tmp/chosen", "auto", "Chosen"])
        XCTAssertEqual(h.selected, 2)
        h.prepared("slow")
        try await waitUntil { h.pending["next"] != nil }
        h.prepared("next")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(h.commands.count, 1)
        h.ids.append(7)
        h.replies[0].complete(0)
        try await waitUntil { h.commands.count == 2 }
        XCTAssertEqual(h.selected, 7)
        XCTAssertEqual(h.queue.currentExternalSubtitleURL(), "chosen")
        XCTAssertEqual(h.commands[1][1], "/tmp/slow")
        h.replies[1].complete(0)
        try await waitUntil { h.commands.count == 3 }
        XCTAssertEqual(h.commands[2][1], "/tmp/next")
        h.queue.select(.track(-1))
        XCTAssertNil(h.queue.currentExternalSubtitleURL())
    }

    @MainActor
    func testGenerationCancelsPreparationAndLateResultCannotAdmitOldTrack() async throws {
        let h = PreparedSubtitleHarness()
        defer { h.clear() }
        h.queue.setReady()
        h.queue.enqueue(.init(urls: ["old"], names: nil, selectFirst: true))
        try await waitUntil { h.pending["old"] != nil }
        h.queue.beginGeneration()
        h.queue.enqueue(.init(urls: ["new"], names: nil, selectFirst: true))
        h.queue.setReady()
        h.prepared("old")
        try await waitUntil { h.pending["new"] != nil }
        XCTAssertTrue(h.commands.isEmpty)
        h.prepared("new")
        try await waitUntil { h.commands.count == 1 }
        XCTAssertEqual(h.commands[0][1], "/tmp/new")
    }

    @MainActor
    func testWishlistCancellationPreservesExplicitLoadAndLowDataPolicy() async throws {
        let h = PreparedSubtitleHarness()
        defer { h.clear() }
        h.queue.prefetch([.init(request: .init(url: "warm"), allowsCellularAccess: true)])
        try await waitUntil { h.pending["warm"] != nil }
        XCTAssertTrue(h.started[0].allowsCellularAccess)
        XCTAssertFalse(h.started[0].allowsConstrainedNetworkAccess)
        h.queue.enqueue(.init(urls: ["user"], names: nil, selectFirst: true))
        try await waitUntil { h.pending["user"] != nil }
        XCTAssertTrue(h.started[1].allowsConstrainedNetworkAccess)
        h.queue.prefetch([])
        h.prepared("warm")
        h.prepared("user")
        h.queue.setReady()
        try await waitUntil { h.commands.count == 1 }
        XCTAssertEqual(h.commands[0][1], "/tmp/user")
        XCTAssertNil(h.preparation.prepared(.init(url: "warm")))
    }

    @MainActor
    func testLookaheadRemainsBoundedWhileNativeAdmissionWaits() async throws {
        let h = PreparedSubtitleHarness()
        defer { h.clear() }
        h.queue.enqueue(.init(urls: (0..<25).map { "sub\($0)" }, names: nil, selectFirst: false))
        for index in 0..<4 {
            try await waitUntil { h.pending["sub\(index)"] != nil }
            h.prepared("sub\(index)", bytes: 8 * 1024 * 1024)
        }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(h.started.count, 4)
        XCTAssertTrue(h.pending.isEmpty)
        h.queue.setReady()
        try await waitUntil { h.commands.count == 1 && h.pending["sub4"] != nil }
        XCTAssertEqual(h.commands[0][1], "/tmp/sub0")
    }

    @MainActor
    func testMatchingWarmTransferPromotesWithoutRestartAndPiPReusesOriginalIdentity() async throws {
        let h = PreparedSubtitleHarness()
        defer { h.clear() }
        let request = MPVExternalSubtitleRequest(url: "same", headers: ["Authorization": "first"])
        h.queue.prefetch([.init(request: request, allowsCellularAccess: false)])
        try await waitUntil { h.pending["same"] != nil }
        h.queue.enqueue(.init(urls: ["same"], names: nil, selectFirst: true, requests: [request]))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(h.started.count, 1)
        h.prepared("same")
        h.queue.setReady()
        try await waitUntil { h.commands.count == 1 }
        h.ids.append(5)
        h.replies[0].complete(0)
        try await waitUntil { h.selected == 5 }
        let replay = PreparedSubtitleHarness()
        defer { replay.clear() }
        for batch in h.queue.batches { replay.queue.enqueue(batch) }
        replay.queue.restoreSelectionIntent(h.queue.selectionIntent)
        replay.queue.setReady()
        try await waitUntil { replay.commands.count == 1 }
        XCTAssertTrue(replay.started.isEmpty)
        XCTAssertEqual(replay.commands[0][1], "/tmp/same")
        replay.ids.append(17)
        replay.replies[0].complete(0)
        try await waitUntil { replay.selected == 17 }
        XCTAssertEqual(replay.queue.currentExternalSubtitleURL(), "same")
    }
    @MainActor
    func testFailedColdDownloadKeepsActualSelectionAndNextClickRetries() async throws {
        let h = PreparedSubtitleHarness()
        defer { h.clear() }
        h.queue.setReady()
        h.queue.enqueue(.init(urls: ["failed"], names: nil, selectFirst: true))
        try await waitUntil { h.pending["failed"] != nil }
        h.pending.removeValue(forKey: "failed")?.resume(returning: .failed)
        try await waitUntil { h.preparation.failed(.init(url: "failed")) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(h.selected, 2)
        XCTAssertNil(h.queue.currentExternalSubtitleURL())
        XCTAssertTrue(h.commands.isEmpty)
        h.queue.enqueue(.init(urls: ["failed"], names: nil, selectFirst: true))
        try await waitUntil { h.pending["failed"] != nil }
        h.prepared("failed")
        try await waitUntil { h.commands.count == 1 }
        XCTAssertEqual(h.started.count, 2)
    }

    @MainActor
    func testDifferentEffectiveCredentialsDoNotReuseNativeTrack() async throws {
        let h = PreparedSubtitleHarness()
        defer { h.clear() }
        h.queue.setReady()
        let first = MPVExternalSubtitleRequest(url: "protected", headers: ["Authorization": "first"])
        let second = MPVExternalSubtitleRequest(url: "protected", headers: ["Authorization": "second"])
        h.queue.enqueue(.init(urls: ["protected"], names: nil, selectFirst: true, requests: [first]))
        try await waitUntil { h.pending["protected"] != nil }
        h.prepared("protected")
        try await waitUntil { h.commands.count == 1 }
        h.ids.append(3)
        h.replies[0].complete(0)
        try await waitUntil { h.selected == 3 }
        h.queue.enqueue(.init(urls: ["protected"], names: nil, selectFirst: true, requests: [second]))
        try await waitUntil { h.pending["protected"] != nil }
        h.prepared("protected")
        try await waitUntil { h.commands.count == 2 }
        XCTAssertEqual(h.started.count, 2)
    }

    @MainActor
    func testSupersededForegroundKeepsTransferSlotUntilCancellationCompletes() async throws {
        let h = PreparedSubtitleHarness()
        defer { h.clear() }
        h.queue.enqueue(.init(urls: ["background"], names: nil, selectFirst: false))
        h.queue.enqueue(.init(urls: ["old"], names: nil, selectFirst: true))
        try await waitUntil { h.pending.count == 2 }
        h.queue.enqueue(.init(urls: ["latest"], names: nil, selectFirst: true))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(h.started.count, 2)
        XCTAssertNil(h.pending["latest"])
        h.prepared("old")
        try await waitUntil { h.pending["latest"] != nil }
        XCTAssertEqual(h.pending.count, 2)
        XCTAssertNil(h.preparation.prepared(.init(url: "old")))
        h.queue.setReady()
        h.prepared("latest")
        try await waitUntil { h.commands.count == 1 }
        XCTAssertEqual(h.commands[0][1], "/tmp/latest")
    }

    @MainActor
    func testPromotedRestrictedTransferRetriesUnderExplicitNetworkPolicy() async throws {
        let h = PreparedSubtitleHarness()
        defer { h.clear() }
        let request = MPVExternalSubtitleRequest(url: "restricted")
        h.queue.prefetch([.init(request: request, allowsCellularAccess: false)])
        try await waitUntil { h.pending["restricted"] != nil }
        h.queue.enqueue(.init(urls: ["restricted"], names: nil, selectFirst: true))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(h.started.count, 1)
        h.pending.removeValue(forKey: "restricted")?.resume(returning: .failed)
        try await waitUntil { h.started.count == 2 }
        XCTAssertTrue(h.started[1].allowsCellularAccess)
        XCTAssertTrue(h.started[1].allowsConstrainedNetworkAccess)
        XCTAssertFalse(h.preparation.failed(request))
        h.prepared("restricted")
        h.queue.setReady()
        try await waitUntil { h.commands.count == 1 }
    }

    @MainActor
    func testColdCompatibilityReplaySharesPreparationBeforeEitherNativeReply() async throws {
        let primary = PreparedSubtitleHarness()
        let compatibility = PreparedSubtitleHarness()
        defer { primary.clear(); compatibility.clear() }
        primary.queue.setReady()
        primary.queue.enqueue(.init(urls: ["one-use"], names: ["External"], selectFirst: true))
        try await waitUntil { primary.pending["one-use"] != nil }
        for batch in primary.queue.batches { compatibility.queue.enqueue(batch) }
        compatibility.queue.restoreSelectionIntent(primary.queue.selectionIntent)
        compatibility.queue.setReady()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(compatibility.started.isEmpty)
        XCTAssertTrue(compatibility.commands.isEmpty)
        primary.prepared("one-use")
        try await waitUntil { primary.commands.count == 1 && compatibility.commands.count == 1 }
        XCTAssertEqual(primary.commands[0], compatibility.commands[0])
        XCTAssertEqual(primary.started.count, 1)
        XCTAssertTrue(compatibility.started.isEmpty)
        compatibility.ids.append(8)
        compatibility.replies[0].complete(0)
        try await waitUntil { compatibility.selected == 8 }
        XCTAssertEqual(compatibility.queue.currentExternalSubtitleURL(), "one-use")
    }

    @MainActor
    func testPrimaryGenerationResetFailsWaitingCompatibilityImportWithoutAnotherDownload() async throws {
        let primary = PreparedSubtitleHarness()
        let compatibility = PreparedSubtitleHarness()
        defer { primary.clear(); compatibility.clear() }
        primary.queue.enqueue(.init(urls: ["old"], names: nil, selectFirst: true))
        try await waitUntil { primary.pending["old"] != nil }
        for batch in primary.queue.batches { compatibility.queue.enqueue(batch) }
        compatibility.queue.setReady()
        for _ in 0..<50 { await Task.yield() }
        primary.queue.beginGeneration()
        primary.prepared("old")
        try await waitUntil { compatibility.preparation.failed(.init(url: "old")) }
        XCTAssertTrue(compatibility.started.isEmpty)
        XCTAssertTrue(compatibility.commands.isEmpty)
        XCTAssertEqual(compatibility.selected, 2)
    }

    @MainActor
    func testCompatibilityImportAfterCacheEvictionAndNativeReuseDoesNotWaitForever() async throws {
        let primary = PreparedSubtitleHarness()
        let compatibility = PreparedSubtitleHarness()
        defer { primary.clear(); compatibility.clear() }
        primary.queue.setReady()
        primary.queue.enqueue(.init(urls: ["evicted"], names: nil, selectFirst: true))
        try await waitUntil { primary.pending["evicted"] != nil }
        primary.prepared("evicted")
        try await waitUntil { primary.commands.count == 1 }
        primary.ids.append(8)
        primary.replies[0].complete(0)
        try await waitUntil { primary.selected == 8 }
        for index in 0..<17 {
            primary.preparation.seed([.init(url: "filler\(index)"): .init(nativeURL: "/tmp/filler\(index)")])
        }
        XCTAssertNil(primary.preparation.prepared(.init(url: "evicted")))
        primary.queue.enqueue(.init(urls: ["evicted"], names: nil, selectFirst: true))
        if let batch = primary.queue.batches.last { compatibility.queue.enqueue(batch) }
        compatibility.queue.setReady()
        try await waitUntil { compatibility.pending["evicted"] != nil }
        compatibility.prepared("evicted")
        try await waitUntil { compatibility.commands.count == 1 }
        XCTAssertEqual(primary.commands.count, 1)
        XCTAssertEqual(primary.started.count, 1)
        XCTAssertEqual(primary.selected, 8)
    }

}
