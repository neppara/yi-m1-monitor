// Regression tests for the URL-building bug found on-device 2026-07-08: an earlier version
// percent-encoded every character except RFC 3986 "unreserved" ones, turning "/" in file paths
// into "%2F" - which broke GetFile/DeleteFile while slash-free commands (GetFileList,
// GetCameraStatus) worked fine. See HTTPClient.swift's file header for the full story.
import XCTest
@testable import YiM1Core

final class HTTPClientTests: XCTestCase {
    func testBuildURLKeepsSlashesLiteralInFilePaths() async throws {
        let client = HTTPClient()
        let command = Commands.getFile(path: "/DCIM/100YICAM/P1.DNG", quality: .medium)
        let maybeURL = await client.buildURL(command)
        let url = try XCTUnwrap(maybeURL)

        XCTAssertTrue(url.query?.contains("/DCIM/100YICAM/P1.DNG") ?? false,
                       "path should appear literally in the query, not percent-encoded as %2F - got: \(url.query ?? "nil")")
        XCTAssertFalse(url.absoluteString.contains("%2F"),
                        "should not percent-encode forward slashes - got: \(url.absoluteString)")
    }

    func testBuildURLHandlesDeleteFileArrayOfPaths() async throws {
        let client = HTTPClient()
        let command = Commands.deleteFile(paths: ["/DCIM/100YICAM/P1.DNG", "/DCIM/100YICAM/P2.DNG"])
        let maybeURL = await client.buildURL(command)
        let url = try XCTUnwrap(maybeURL)

        XCTAssertTrue(url.query?.contains("/DCIM/100YICAM/P1.DNG") ?? false)
        XCTAssertTrue(url.query?.contains("/DCIM/100YICAM/P2.DNG") ?? false)
        XCTAssertFalse(url.absoluteString.contains("%2F"))
    }

    func testBuildURLStillProducesAValidURLForFlatCommands() async throws {
        let client = HTTPClient()
        let maybeURL = await client.buildURL(Commands.getCameraStatus())
        let url = try XCTUnwrap(maybeURL)
        XCTAssertEqual(url.host, "192.168.0.10")
        // Foundation's URL(string:) percent-encodes some of "{", "}", "\"" on its own even though
        // they're passed in raw (verified empirically) - round-trip decode instead of asserting
        // on its specific choice of escaped characters, which isn't the behavior under test here.
        let query = try XCTUnwrap(url.query)
        let decoded = try XCTUnwrap(query.removingPercentEncoding)
        XCTAssertEqual(decoded, "data={\"command\":\"GetCameraStatus\"}")
    }

    /// The camera signals failures as HTTP 200 + {"code":<err>} in the body (observed live:
    /// 1515 "rc only one", 1502 "get filelist err") - regression test for the on-device
    /// recording-state desync where a body-level failure was treated as success because only
    /// the transport status was checked.
    func testIsCameraSuccessChecksBodyCodeNotJustTransportStatus() {
        func response(_ status: Int, _ body: String) -> HTTPClient.Response {
            HTTPClient.Response(status: status, body: Data(body.utf8))
        }
        XCTAssertTrue(response(200, #"{"code":200,"data":{}}"#).isCameraSuccess)
        XCTAssertFalse(response(200, #"{"code":1515,"data":"rc only one"}"#).isCameraSuccess,
                        "HTTP 200 with a body error code is a FAILURE")
        XCTAssertFalse(response(200, #"{"code":1502,"data":"get filelist err"}"#).isCameraSuccess)
        XCTAssertFalse(response(404, #"{"code":200}"#).isCameraSuccess, "transport failure is failure")
        XCTAssertFalse(response(0, "").isCameraSuccess, "timeout (status 0) is failure")
        XCTAssertTrue(response(200, "not json at all").isCameraSuccess,
                       "non-JSON 200 bodies (e.g. raw file data) count as success")
        XCTAssertTrue(response(200, #"{"code":"200"}"#).isCameraSuccess, "string-typed code tolerated")
    }

    /// Regression test for the second on-device 1515 ("rc only one") cause: the camera can't
    /// handle concurrent HTTP requests, but the status poll / GetFileList / downloads all fire
    /// from independent Tasks. HTTPClient must serialize them - this fires 5 sends concurrently
    /// through a URLProtocol stub that records the max number of simultaneously-open requests,
    /// and asserts it never exceeded 1. Would fail against the pre-fix client (actor isolation
    /// alone releases during the network await, letting requests overlap).
    func testConcurrentSendsAreSerializedToOneInFlightRequest() async {
        ConcurrencyCountingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConcurrencyCountingProtocol.self]
        let client = HTTPClient(host: "192.168.0.10", session: URLSession(configuration: config))

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = await client.send(Commands.getCameraStatus()) }
            }
        }

        XCTAssertEqual(ConcurrencyCountingProtocol.totalStarted(), 5, "all requests should still complete")
        XCTAssertEqual(ConcurrencyCountingProtocol.maxInFlight(), 1,
                        "the camera only tolerates one request at a time - concurrent sends must be serialized")
    }
}

/// URLProtocol stub that answers every request with 200 after a short delay, tracking how many
/// requests were open simultaneously.
private final class ConcurrencyCountingProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var inFlight = 0
    private static var peak = 0
    private static var started = 0

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        inFlight = 0; peak = 0; started = 0
    }

    static func maxInFlight() -> Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    static func totalStarted() -> Int {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.inFlight += 1
        Self.started += 1
        Self.peak = max(Self.peak, Self.inFlight)
        Self.lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            Self.lock.lock()
            Self.inFlight -= 1
            Self.lock.unlock()

            guard let url = self.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data("{\"code\":200}".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
