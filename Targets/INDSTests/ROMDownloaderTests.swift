import XCTest
@testable import eNDS

/// The "Try a Free Demo Game" download: retries, clear errors, no HTML saved as a ROM.
final class ROMDownloaderTests: XCTestCase {
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var hits = 0
        nonisolated(unsafe) static var plan: [(Int, String, Data)] = []   // status, mime, body
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let step = Stub.plan[min(Stub.hits, Stub.plan.count - 1)]
            Stub.hits += 1
            if step.0 == 0 {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: step.0, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": step.1])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: step.2)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func session(_ plan: [(Int, String, Data)]) -> URLSession {
        Stub.hits = 0; Stub.plan = plan
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Stub.self]
        return URLSession(configuration: c)
    }
    private let url = URL(string: "https://example.com/jamclown.nds")!

    func testRetriesAfterNetworkErrorsThenSucceeds() async throws {
        let s = session([(0, "", Data()), (0, "", Data()), (200, "application/octet-stream", Data(count: 600))])
        let file = try await ROMDownloader.download(url, session: s)
        XCTAssertEqual(Stub.hits, 3)
        XCTAssertEqual(file.lastPathComponent, "jamclown.nds")
    }

    func testOfflineGivesClearMessageAfterThreeTries() async {
        let s = session([(0, "", Data())])
        do { _ = try await ROMDownloader.download(url, session: s); XCTFail() } catch {
            XCTAssertEqual(Stub.hits, 3)
            XCTAssertTrue(error.localizedDescription.contains("Import from Files"), error.localizedDescription)
        }
    }

    func testHtmlAnswerIsRejectedAndNotRetried() async {
        let s = session([(200, "text/html", Data("<html>login</html>".utf8))])
        do { _ = try await ROMDownloader.download(url, session: s); XCTFail() } catch {
            XCTAssertEqual(Stub.hits, 1)
            XCTAssertTrue(error.localizedDescription.contains("Import from Files"))
        }
    }

    func test404IsNotRetried() async {
        let s = session([(404, "text/plain", Data())])
        do { _ = try await ROMDownloader.download(url, session: s); XCTFail() } catch {
            XCTAssertEqual(Stub.hits, 1)
        }
    }
}
