import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class Stub: URLProtocol {
    static var calls = 0
    static var responder: (URLRequest) -> (Int, [String: String], String) = { _ in (500, [:], "") }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(request.value(forHTTPHeaderField: "client-token") == nil)
        precondition(request.url!.path.hasPrefix("/provider/canvaslist/"))
        let (status, headers, body) = Self.responder(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct CanvasChecks {
    static func main() async throws {
        let id = "4Dvkj6JhhA12EX05fT7y2e"
        let mp4 = "https://canvaz.scdn.co/video/test.cnvs.mp4?x=1"
        func body(_ entry: String) -> String { "{\"data\":{\"\(id)\":\(entry)}}" }
        func parse(_ value: String) throws -> URL? {
            try SpotifyCanvasService.parse(Data(value.utf8), trackID: id)
        }
        let found = body("{\"url\":\"\(mp4)\"}")
        let parsed = try parse(found)
        precondition(parsed?.absoluteString == mp4)
        let none = try parse(body("null"))
        precondition(none == nil)
        for url in ["http://cdn.example/a.mp4", "https://cdn.example/a.jpg", "file:///a.mp4"] {
            let parsed = try parse(body("{\"url\":\"\(url)\"}"))
            precondition(parsed == nil)
        }
        for invalid in ["{}", "not json", "{\"data\":{\"other\":null}}", body("{\"error\":{\"status\":502}}") ] {
            do { _ = try parse(invalid); preconditionFailure("Failure cached as absence") } catch {}
        }
        precondition(SpotifyCanvasService.isTrackID(id))
        precondition(!SpotifyCanvasService.isTrackID("spotify:track:" + id))
        precondition(!SpotifyCanvasService.isTrackID(String(repeating: "/", count: 22)))

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let session = URLSession(configuration: config)
        func service() -> SpotifyCanvasService { SpotifyCanvasService(session: session, retryDelay: 0) }
        Stub.calls = 0
        Stub.responder = { _ in Stub.calls == 1 ? (503, [:], "error") : (200, [:], found) }
        let retried = service()
        let first = try await retried.find(trackID: id)
        let second = try await retried.find(trackID: id)
        precondition(first?.absoluteString == mp4 && first == second && Stub.calls == 2)

        Stub.calls = 0
        Stub.responder = { _ in (200, [:], body("null")) }
        let missing = service()
        _ = try await missing.find(trackID: id)
        _ = try await missing.find(trackID: id)
        precondition(Stub.calls == 1)

        Stub.calls = 0
        Stub.responder = { _ in (429, ["Retry-After": "600"], "") }
        let limited = service()
        for _ in 0..<2 {
            do { _ = try await limited.find(trackID: id); preconditionFailure("Expected cooldown") }
            catch SpotifyCanvasService.LookupError.retryLater { }
        }
        precondition(Stub.calls == 1)
        Stub.calls = 0
        _ = try await service().find(trackID: "invalid")
        precondition(Stub.calls == 0)
        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let live = try parseLive(data, id: id)
            precondition(live != nil)
        }
        print("Canvas checks passed: response parsing, no user credentials, retry, hit/miss caching, rate limit, invalid IDs")
    }

    static func parseLive(_ data: Data, id: String) throws -> URL? {
        try SpotifyCanvasService.parse(data, trackID: id)
    }
}
