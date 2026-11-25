import AccessKit
import CryptoKit
import Foundation

/// Only the latest release metadata and its two canonical, tag-bound assets
/// can enter admission. A fresh session has no browser or account state.
struct AccessGeoSiteUpdateTransport: Sendable {
    enum Result: Sendable {
        case candidate(AccessGeoSiteAdmission.Candidate, etag: String?)
        case notModified(etag: String?)
    }

    enum Failure: Error, Equatable {
        case invalidURL, redirect, response, encoding, length, digest, deadline
        case status(Int), network(Int)
    }

    typealias Authentication = @Sendable (URLAuthenticationChallenge)
        -> (URLSession.AuthChallengeDisposition, URLCredential?)

    private struct Source: Sendable {
        let metadataURL: URL
        var requestAssetURL: @Sendable (URL) -> URL = { $0 }
        var allowsCDN: @Sendable (URL) -> Bool
        var canonicalMetadata: @Sendable (Data) throws -> Data = { $0 }
        var authenticate: Authentication = { challenge in
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                ? (.performDefaultHandling, nil) : (.cancelAuthenticationChallenge, nil)
        }
    }

    private let source: Source
    private let budget: Duration

    init() {
        source = Source(metadataURL: AccessGeoSiteAdmission.metadataURL, allowsCDN: { url in
            url.host(percentEncoded: true) == "release-assets.githubusercontent.com" && url.port == nil
        })
        budget = .seconds(30)
    }

#if DEBUG && targetEnvironment(simulator)
    init(metadataURL: URL, assetURL: @escaping @Sendable (URL) -> URL, cdnOrigin: URL,
         canonicalMetadata: @escaping @Sendable (Data) throws -> Data, authenticate: @escaping Authentication,
         budget: Duration = .seconds(30)) {
        source = Source(metadataURL: metadataURL, requestAssetURL: assetURL, allowsCDN: {
            $0.host(percentEncoded: true) == cdnOrigin.host(percentEncoded: true) && $0.port == cdnOrigin.port
        }, canonicalMetadata: canonicalMetadata, authenticate: authenticate)
        self.budget = budget
    }
#endif

    func load(etag: String?, highWater: AccessGeoSiteAdmission.Receipt?, now: Date,
              includeOverseas: Bool = false,
              onLateAdmission: @Sendable (AccessGeoSiteAdmission.Candidate) async -> Void = { _ in }) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { work in
            work.addTask { try await loadRelease(etag: etag, highWater: highWater, now: now, includeOverseas: includeOverseas) }
            work.addTask {
                try await Task.sleep(for: budget)
                throw Failure.deadline
            }
            defer { work.cancelAll() }
            do {
                guard let result = try await work.next() else { throw CancellationError() }
                return result
            } catch {
                work.cancelAll()
                // A worker already in admission can finish after the timer.
                // Its verified result may narrow authorization without publishing.
                while let remaining = await work.nextResult() {
                    if case .success(.candidate(let candidate, _)) = remaining { await onLateAdmission(candidate) }
                }
                throw error
            }
        }
    }

    private func loadRelease(etag: String?, highWater: AccessGeoSiteAdmission.Receipt?, now: Date,
                             includeOverseas: Bool) async throws -> Result {
        let metadata = try await get(source.metadataURL, etag: etag, limit: AccessGeoSiteAdmission.maximumMetadataBytes)
        if metadata.status == 304 { return .notModified(etag: metadata.etag) }
        let receipt = try AccessGeoSiteAdmission.metadata(source.canonicalMetadata(metadata.bytes), now: now, highWater: highWater)
        let pair = try await get(source.requestAssetURL(receipt.checksumURL), asset: receipt.checksum,
                                 limit: AccessGeoSiteAdmission.maximumChecksumBytes)
        let database = try await get(source.requestAssetURL(receipt.databaseURL), asset: receipt.database,
                                     limit: AccessGeoSiteAdmission.maximumDatabaseBytes)
        let candidate = try AccessGeoSiteAdmission.admit(receipt: receipt, database: database.bytes,
                                                         checksum: pair.bytes, now: now, highWater: highWater,
                                                         includeOverseas: includeOverseas)
        return .candidate(candidate, etag: Self.validETag(metadata.etag))
    }

    static func validETag(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let opaque = value.hasPrefix("W/") ? value.utf8.dropFirst(2) : value.utf8[...]
        guard opaque.count >= 2, opaque.first == 34, opaque.last == 34,
              opaque.dropFirst().dropLast().allSatisfy({ $0 == 33 || (35...126).contains($0) || $0 >= 128 })
        else { return nil }
        return value
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && url.host(percentEncoded: true) != nil
            && url.user == nil && url.password == nil && url.fragment == nil
    }

    private static func request(_ url: URL, etag: String? = nil) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Aegis-GeoSite", forHTTPHeaderField: "User-Agent")
        if let etag = validETag(etag) { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    private struct Response: Sendable {
        let status: Int
        let bytes: Data
        let etag: String?
    }

    private func get(_ url: URL, etag: String? = nil, asset: AccessGeoSiteAdmission.Asset? = nil,
                     limit: Int) async throws -> Response {
        guard Self.isHTTPS(url) else { throw Failure.invalidURL }
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30

        let (stream, result) = AsyncThrowingStream<Response, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let receiver = Receiver(url: url, asset: asset, limit: limit, source: source, result: result)
        let session = URLSession(configuration: config, delegate: receiver, delegateQueue: nil)
        let task = session.dataTask(with: Self.request(url, etag: etag))
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            task.resume()
            for try await response in stream {
                try Task.checkCancellation()
                return response
            }
            throw CancellationError()
        } onCancel: {
            task.cancel()
        }
    }

    /// Foundation delivers callbacks on the session's serial delegate queue.
    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let initialURL: URL
        private let asset: AccessGeoSiteAdmission.Asset?
        private let limit: Int
        private let source: Source
        private let result: AsyncThrowingStream<Response, Error>.Continuation
        private var finalURL: URL
        private var failure: Failure?
        private var status: Int?
        private var etag: String?
        private var contentLength: Int?
        private var body = Data()
        private var sha = SHA256()

        init(url: URL, asset: AccessGeoSiteAdmission.Asset?, limit: Int, source: Source,
             result: AsyncThrowingStream<Response, Error>.Continuation) {
            initialURL = url
            finalURL = url
            self.asset = asset
            self.limit = min(limit, asset?.byteCount ?? limit)
            self.source = source
            self.result = result
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let (disposition, credential) = source.authenticate(challenge)
            completionHandler(disposition, credential)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let (disposition, credential) = source.authenticate(challenge)
            completionHandler(disposition, credential)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard asset != nil, finalURL == initialURL, response.url?.absoluteString == initialURL.absoluteString,
                  task.originalRequest?.url?.absoluteString == initialURL.absoluteString,
                  task.originalRequest?.httpMethod == "GET", newRequest.httpMethod == "GET",
                  let target = newRequest.url, AccessGeoSiteUpdateTransport.isHTTPS(target), source.allowsCDN(target)
            else {
                failure = .redirect
                completionHandler(nil)
                return
            }
            finalURL = target
            completionHandler(AccessGeoSiteUpdateTransport.request(target))
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            if let rejection = validate(response, task: dataTask) {
                failure = failure ?? rejection
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }

        private func validate(_ response: URLResponse, task: URLSessionTask) -> Failure? {
            guard let http = response as? HTTPURLResponse,
                  response.url?.absoluteString == finalURL.absoluteString,
                  task.currentRequest?.url?.absoluteString == finalURL.absoluteString,
                  task.currentRequest?.httpMethod == "GET" else { return .response }
            let code = http.statusCode
            guard code == 200 || (asset == nil && code == 304) else { return .status(code) }
            guard http.value(forHTTPHeaderField: "Content-Range") == nil else { return .response }
            if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"),
               encoding.caseInsensitiveCompare("identity") != .orderedSame { return .encoding }
            // CFNetwork removes transfer framing before delivering the body.
            // Count the delivered bytes even when there is no Content-Length.
            if code == 200, let rawLength = http.value(forHTTPHeaderField: "Content-Length") {
                guard rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
                      let length = Int(rawLength), (1...limit).contains(length),
                      asset.map({ $0.byteCount == length }) != false,
                      http.value(forHTTPHeaderField: "Transfer-Encoding") == nil else { return .length }
                contentLength = length
            }
            status = code
            etag = http.value(forHTTPHeaderField: "ETag")
            return nil
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil, status == 200, data.count <= limit - body.count,
                  contentLength.map({ data.count <= $0 - body.count }) != false else {
                failure = failure ?? .length
                dataTask.cancel()
                return
            }
            body.append(data)
            if asset != nil { sha.update(data: data) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            do {
                if let failure { throw failure }
                if let error {
                    let code = (error as NSError).code
                    if code == URLError.cannotDecodeRawData.rawValue { throw Failure.encoding }
                    throw Failure.network(code)
                }
                guard let status else { throw Failure.response }
                if status == 200 {
                    guard !body.isEmpty, contentLength.map({ $0 == body.count }) != false else { throw Failure.length }
                    if let asset {
                        guard body.count == asset.byteCount else { throw Failure.length }
                        let digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
                        guard digest == asset.sha256 else { throw Failure.digest }
                    }
                } else if !body.isEmpty {
                    throw Failure.length
                }
                result.yield(Response(status: status, bytes: body, etag: etag))
                result.finish()
            } catch {
                result.finish(throwing: error)
            }
        }
    }
}
