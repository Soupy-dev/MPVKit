import Foundation

package struct MPVExternalSubtitleRequest: Hashable, Sendable {
    package struct Header: Hashable, Sendable {
        let name: String
        let value: String
    }

    package let url: String
    package let headers: [Header]
    package let permitsPreparation: Bool

    package init(url: String, headers: [String: String] = [:], permitsPreparation: Bool = true) {
        self.url = url
        self.headers = headers.map { Header(name: $0.key.lowercased(), value: $0.value) }
            .sorted { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
        self.permitsPreparation = permitsPreparation
    }

    package static func make(
        url: String,
        headersByURL: [String: [String: String]]?,
        mediaURL: URL?,
        mediaHeaders: [String: String]?,
        userAgent: String?,
        referrer: String?,
        permitsPreparation: Bool
    ) -> Self {
        let supplied = headersByURL?[url]
        let target = URL(string: url)
        let sameOrigin = target.flatMap { target in
            mediaURL.map { media in
                target.scheme?.lowercased() == media.scheme?.lowercased()
                    && target.host?.lowercased() == media.host?.lowercased()
                    && (target.port ?? (target.scheme?.lowercased() == "https" ? 443 : 80))
                        == (media.port ?? (media.scheme?.lowercased() == "https" ? 443 : 80))
            }
        } ?? false
        var headers = supplied ?? (sameOrigin ? mediaHeaders ?? [:] : [:])
        if let userAgent, !userAgent.isEmpty,
           !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            headers["User-Agent"] = userAgent
        }
        if let referrer, !referrer.isEmpty,
           !headers.keys.contains(where: { $0.caseInsensitiveCompare("Referer") == .orderedSame }) {
            headers["Referer"] = referrer
        }
        let ambiguousLegacyHeaders = supplied == nil && !sameOrigin && !(mediaHeaders ?? [:]).isEmpty
        return Self(url: url, headers: headers, permitsPreparation: permitsPreparation && !ambiguousLegacyHeaders)
    }

    package var canPrepare: Bool {
        guard permitsPreparation, let parsed = URL(string: url),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              parsed.host != nil, parsed.user == nil, parsed.password == nil,
              !["idx", "sub", "sup", "m3u", "m3u8", "mpd", "ttml", "dfxp", "xml"].contains(parsed.pathExtension.lowercased()),
              Set(headers.map(\.name)).count == headers.count else { return false }
        let tokenCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")
        return headers.allSatisfy {
            !$0.name.isEmpty && $0.name.unicodeScalars.allSatisfy(tokenCharacters.contains)
                && !$0.value.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 9) || $0.value == 127 })
        }
    }
}

package final class MPVPreparedExternalSubtitle: @unchecked Sendable {
    package let nativeURL: String
    package let byteCount: Int
    private let temporaryFile: URL?

    package init(nativeURL: String, byteCount: Int = 0, temporaryFile: URL? = nil) {
        self.nativeURL = nativeURL
        self.byteCount = byteCount
        self.temporaryFile = temporaryFile
    }

    deinit {
        guard let temporaryFile else { return }
        try? FileManager.default.removeItem(at: temporaryFile)
    }
}

package enum MPVExternalSubtitlePreparationResult: Sendable {
    case prepared(MPVPreparedExternalSubtitle)
    case failed
}

package final class MPVExternalSubtitleDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: MPVExternalSubtitleRequest
    private let allowsCellularAccess: Bool
    private let allowsConstrainedNetworkAccess: Bool
    private let maximumBytes: Int
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<MPVExternalSubtitlePreparationResult, Never>?
    private var data = Data()
    private var finished = false
    private var redirectCount = 0

    package init(request: MPVExternalSubtitleRequest, allowsCellularAccess: Bool, maximumBytes: Int, allowsConstrainedNetworkAccess: Bool = false) {
        self.request = request
        self.allowsCellularAccess = allowsCellularAccess
        self.maximumBytes = maximumBytes
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
    }

    package func value() async -> MPVExternalSubtitlePreparationResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !finished, let url = URL(string: request.url) else {
                    lock.unlock()
                    continuation.resume(returning: .failed)
                    return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.urlCredentialStorage = nil
                configuration.timeoutIntervalForRequest = 15
                configuration.timeoutIntervalForResource = 20
                configuration.allowsCellularAccess = allowsCellularAccess
                configuration.allowsExpensiveNetworkAccess = allowsCellularAccess
                configuration.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                urlRequest.allowsCellularAccess = allowsCellularAccess
                urlRequest.allowsExpensiveNetworkAccess = allowsCellularAccess
                urlRequest.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
                for header in request.headers { urlRequest.setValue(header.value, forHTTPHeaderField: header.name) }
                let task = session.dataTask(with: urlRequest)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.complete(.failed)
        }
    }

    private func complete(_ result: MPVExternalSubtitlePreparationResult) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        task = nil
        data.removeAll()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(returning: result)
    }

    package func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            completionHandler(.cancel)
            complete(.failed)
            return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            complete(.prepared(.init(nativeURL: request.url)))
            return
        }
        completionHandler(.allow)
    }

    package func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard chunk.count <= maximumBytes - data.count else {
            lock.unlock()
            complete(.prepared(.init(nativeURL: request.url)))
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    package func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirectCount += 1
        guard redirectCount <= 8, let url = newRequest.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !(response.url?.scheme?.lowercased() == "https" && url.scheme?.lowercased() == "http") else {
            completionHandler(nil)
            complete(.failed)
            return
        }
        completionHandler(Self.redirectedRequest(newRequest, from: URL(string: request.url), headers: request.headers))
    }

    package static func redirectedRequest(_ request: URLRequest, from previousURL: URL?,
                                          headers: [MPVExternalSubtitleRequest.Header]) -> URLRequest {
        var redirected = request
        let sameOrigin = previousURL?.scheme?.lowercased() == request.url?.scheme?.lowercased()
            && previousURL?.host?.lowercased() == request.url?.host?.lowercased()
            && previousURL?.port == request.url?.port
        let protectedNames = ["authorization", "cookie", "proxy-authorization", "host"]
        for name in protectedNames where !sameOrigin {
            redirected.setValue(nil, forHTTPHeaderField: name)
        }
        for header in headers where sameOrigin || !protectedNames.contains(header.name) {
            redirected.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return redirected
    }

    package static func prepare(_ content: Data, originalURL: String) -> MPVExternalSubtitlePreparationResult {
        guard !content.isEmpty else { return .failed }
        guard let text = String(data: content, encoding: .utf8)
                ?? String(data: content, encoding: .utf16)
                ?? String(data: content, encoding: .windowsCP1252),
              !text.contains("\0") else { return .prepared(.init(nativeURL: originalURL)) }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = normalized.prefix(512).lowercased()
        guard !prefix.hasPrefix("<!doctype html"), !prefix.hasPrefix("<html"),
              !prefix.hasPrefix("{\""), !prefix.hasPrefix("[{") else { return .failed }
        let fileExtension: String
        if prefix.hasPrefix("webvtt") {
            fileExtension = "vtt"
        } else if prefix.hasPrefix("[script info]") || prefix.hasPrefix("[v4+ styles]") {
            fileExtension = "ass"
        } else if normalized.range(of: #"(?m)^\s*\d{1,2}:\d{2}:\d{2}[,.]\d+\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d+"#,
                                    options: .regularExpression) != nil {
            fileExtension = "srt"
        } else if prefix.contains("<tt ") || prefix.contains("<tt>") || prefix.contains("<tt:") {
            return .prepared(.init(nativeURL: originalURL))
        } else {
            return .prepared(.init(nativeURL: originalURL))
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpv-subtitle-\(UUID().uuidString).\(fileExtension)")
        do {
            try content.write(to: file, options: .atomic)
            return .prepared(.init(nativeURL: file.path, byteCount: content.count, temporaryFile: file))
        } catch {
            try? FileManager.default.removeItem(at: file)
            return .failed
        }
    }

    package func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let content = data
        lock.unlock()
        if let error = error as? URLError,
           [.secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection].contains(error.code) {
            complete(.prepared(.init(nativeURL: request.url)))
            return
        }
        guard error == nil else { complete(.failed); return }
        complete(Self.prepare(content, originalURL: request.url))
    }
}

@MainActor
package final class MPVExternalSubtitlePreparation {
    package struct Source: Sendable {
        fileprivate let owner: MPVExternalSubtitlePreparation
        fileprivate let generation: UInt64
    }

    private struct Waiter {
        let request: MPVExternalSubtitleRequest
        let continuation: CheckedContinuation<MPVExternalSubtitlePreparationResult?, Never>
    }

    package struct Candidate: Equatable {
        package let request: MPVExternalSubtitleRequest
        package let allowsCellularAccess: Bool
        package let allowsConstrainedNetworkAccess: Bool
        package init(request: MPVExternalSubtitleRequest, allowsCellularAccess: Bool,
                     allowsConstrainedNetworkAccess: Bool = false) {
            self.request = request
            self.allowsCellularAccess = allowsCellularAccess
            self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        }
    }

    private struct Active {
        let id: UUID
        let candidate: Candidate
        let task: Task<Void, Never>
    }

    package var didPrepare: (() -> Void)?
    private var foreground: Candidate?
    private var background: [Candidate] = []
    private var demanded: Set<MPVExternalSubtitleRequest> = []
    private var activeForeground: Active?
    private var activeBackground: Active?
    private var cache: [MPVExternalSubtitleRequest: MPVPreparedExternalSubtitle] = [:]
    private var cacheOrder: [MPVExternalSubtitleRequest] = []
    private var failures: Set<MPVExternalSubtitleRequest> = []
    private var completed: Set<MPVExternalSubtitleRequest> = []
    private var generation: UInt64 = 0
    private var waiters: [UUID: Waiter] = [:]
    private var sources: [MPVExternalSubtitleRequest: Source] = [:]
    private let download: (Candidate) async -> MPVExternalSubtitlePreparationResult

    package init(download: ((Candidate) async -> MPVExternalSubtitlePreparationResult)? = nil) {
        self.download = download ?? { candidate in
            guard candidate.request.canPrepare else {
                return .prepared(.init(nativeURL: candidate.request.url))
            }
            return await MPVExternalSubtitleDownload(request: candidate.request,
                allowsCellularAccess: candidate.allowsCellularAccess, maximumBytes: 8 * 1024 * 1024,
                allowsConstrainedNetworkAccess: candidate.allowsConstrainedNetworkAccess).value()
        }
    }

    deinit {
        activeForeground?.task.cancel()
        activeBackground?.task.cancel()
    }

    package func reset() {
        generation &+= 1
        for waiter in waiters.values { waiter.continuation.resume(returning: .failed) }
        waiters.removeAll()
        sources.removeAll()
        completed.removeAll()
        activeForeground?.task.cancel()
        activeBackground?.task.cancel()
        foreground = nil
        background.removeAll()
        demanded.removeAll()
        cache.removeAll()
        cacheOrder.removeAll()
        failures.removeAll()
    }

    package func retry(_ requests: [MPVExternalSubtitleRequest]) {
        failures.subtract(requests)
        completed.subtract(requests)
    }

    package func prepared(_ request: MPVExternalSubtitleRequest) -> MPVPreparedExternalSubtitle? {
        cache[request]
    }

    package func failed(_ request: MPVExternalSubtitleRequest) -> Bool { failures.contains(request) }

    package func source() -> Source { Source(owner: self, generation: generation) }

    package func seed(_ assets: [MPVExternalSubtitleRequest: MPVPreparedExternalSubtitle],
                      source: Source? = nil, requests: [MPVExternalSubtitleRequest] = []) {
        if let source, source.owner !== self {
            for request in requests { sources[request] = source }
        }
        for (request, asset) in assets { store(asset, for: request) }
    }

    private func value(for request: MPVExternalSubtitleRequest, generation: UInt64) async
        -> MPVExternalSubtitlePreparationResult? {
        guard generation == self.generation else { return .failed }
        if let asset = cache[request] { return .prepared(asset) }
        if failures.contains(request) { return .failed }
        if completed.contains(request) || !demanded.contains(request) { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .failed); return }
                waiters[id] = Waiter(request: request, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.continuation.resume(returning: .failed)
            }
        }
    }

    private func finishWaiters(_ request: MPVExternalSubtitleRequest, result: MPVExternalSubtitlePreparationResult) {
        let matching = waiters.filter { $0.value.request == request }
        for (id, waiter) in matching {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: result)
        }
    }

    package func setPlan(foreground: Candidate?, background: [Candidate]) {
        demanded = Set(background.map(\.request) + [foreground?.request].compactMap { $0 })
        let abandoned = waiters.filter { !demanded.contains($0.value.request) }
        for (id, waiter) in abandoned {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: nil)
        }
        self.foreground = foreground
        var seen = Set<MPVExternalSubtitleRequest>()
        self.background = Array(background.filter { seen.insert($0.request).inserted && $0.request != foreground?.request }
            .prefix(foreground == nil ? 4 : 3))
        schedule()
    }

    private func schedule() {
        if let active = activeForeground, active.candidate.request != foreground?.request {
            active.task.cancel()
        }
        if activeForeground == nil, let active = activeBackground,
           active.candidate.request == foreground?.request {
            activeForeground = active
            activeBackground = nil
        }
        if let active = activeBackground,
           !background.contains(active.candidate) || active.candidate.request == foreground?.request {
            active.task.cancel()
        }
        if activeForeground == nil, let foreground, cache[foreground.request] == nil,
           !failures.contains(foreground.request) {
            activeForeground = start(foreground, isForeground: true)
        }
        if activeBackground == nil,
           let next = background.first(where: { cache[$0.request] == nil && !failures.contains($0.request) }) {
            let needed = Set(background.map(\.request) + [foreground?.request].compactMap { $0 })
            while cache.count >= 16 || cache.values.reduce(0, { $0 + $1.byteCount }) > 24 * 1024 * 1024 {
                guard let unused = cacheOrder.first(where: { !needed.contains($0) }) else { return }
                cacheOrder.removeAll { $0 == unused }
                cache.removeValue(forKey: unused)
            }
            activeBackground = start(next, isForeground: false)
        }
    }

    private func start(_ candidate: Candidate, isForeground: Bool) -> Active {
        let id = UUID()
        let download = download
        let source = sources[candidate.request]
        let task = Task { @MainActor [weak self] in
            let imported = await source?.owner.value(for: candidate.request, generation: source?.generation ?? 0)
            let result: MPVExternalSubtitlePreparationResult
            if let imported { result = imported } else { result = await download(candidate) }
            guard let self else { return }
            let completedForeground = self.activeForeground?.id == id
            guard completedForeground || self.activeBackground?.id == id else { return }
            if completedForeground { self.activeForeground = nil } else { self.activeBackground = nil }
            if !Task.isCancelled {
                switch result {
                case .prepared(let asset): self.store(asset, for: candidate.request)
                case .failed:
                    if !completedForeground || self.foreground == candidate {
                        self.failures.insert(candidate.request)
                        self.completed.insert(candidate.request)
                        self.finishWaiters(candidate.request, result: .failed)
                    }
                }
                self.didPrepare?()
            }
            self.schedule()
        }
        return Active(id: id, candidate: candidate, task: task)
    }

    private func store(_ asset: MPVPreparedExternalSubtitle, for request: MPVExternalSubtitleRequest) {
        cache[request] = asset
        completed.insert(request)
        finishWaiters(request, result: .prepared(asset))
        cacheOrder.removeAll { $0 == request }
        cacheOrder.append(request)
        while cache.count > 16 || cache.values.reduce(0, { $0 + $1.byteCount }) > 32 * 1024 * 1024 {
            let needed = Set(background.map(\.request) + [foreground?.request].compactMap { $0 })
            guard let first = cacheOrder.first(where: { !needed.contains($0) }) else { break }
            cacheOrder.removeAll { $0 == first }
            cache.removeValue(forKey: first)
        }
    }
}
