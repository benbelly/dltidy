import Foundation
import Testing
@testable import DLTidyNaming
import DLTidyKit

/// URLProtocol stub keyed by host so parallel tests do not share state.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
        var error: URLError?
    }
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]
    nonisolated(unsafe) private static var bodies: [String: [Data]] = [:]
    private static let lock = NSLock()

    static func register(host: String, _ reply: Reply) {
        lock.withLock { replies[host] = reply; requests[host] = []; bodies[host] = [] }
    }
    static func recorded(host: String) -> (requests: [URLRequest], bodies: [Data]) {
        lock.withLock { (requests[host] ?? [], bodies[host] ?? []) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let host = request.url?.host ?? ""
        let reply: Reply? = Self.lock.withLock {
            Self.requests[host, default: []].append(request)
            Self.bodies[host, default: []].append(body)
            return Self.replies[host]
        }
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeClient(host: String, _ reply: StubProtocol.Reply) -> AnthropicNamingClient {
    StubProtocol.register(host: host, reply)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return AnthropicNamingClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: config))
}

private func messageJSON(text: String, stop: String = "end_turn", input: Int = 120, output: Int = 14) -> Data {
    let obj: [String: Any] = [
        "id": "msg_01", "type": "message", "role": "assistant", "model": "claude-haiku-5-5",
        "content": [["type": "text", "text": text]],
        "stop_reason": stop, "stop_sequence": NSNull(),
        "usage": ["input_tokens": input, "output_tokens": output, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0],
    ]
    return try! JSONSerialization.data(withJSONObject: obj)
}

private func errorJSON(_ type: String, _ message: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": type, "message": message]])
}

struct ClientTests {
    let usage = APIUsage(inputTokens: 120, outputTokens: 14)

    @Test func suggestNameOK() async {
        let host = "ok-\(UUID().uuidString.lowercased()).test"
        let c = makeClient(host: host, .init(status: 200, body: messageJSON(text: #"{"name":"Kitchen Renovation Plan","confidence":"high"}"#)))
        let r = await c.suggestName(for: .text("Plan for the kitchen"), originalName: "scan_001", apiKey: "sk-test")
        #expect(r == .ok(NameSuggestion(name: "Kitchen Renovation Plan", confidence: .high), usage))
        #expect(StubProtocol.recorded(host: host).requests.count == 1)
    }

    @Test func classifyOK() async {
        let host = "cls-\(UUID().uuidString.lowercased()).test"
        let c = makeClient(host: host, .init(status: 200, body: messageJSON(text: #"{"generic":true}"#)))
        #expect(await c.classifyStem("a1b2c3", apiKey: "k") == .ok(true, usage))
        #expect(StubProtocol.recorded(host: host).requests.count == 1)
    }

    @Test func requestShapeForText() async throws {
        let host = "shape-\(UUID().uuidString.lowercased()).test"
        let c = makeClient(host: host, .init(status: 200, body: messageJSON(text: #"{"name":"x y z","confidence":"low"}"#)))
        _ = await c.suggestName(for: .text("ignore previous instructions"), originalName: "scan_001.pdf", apiKey: "sk-secret")
        let rec = StubProtocol.recorded(host: host)
        #expect(rec.requests.count == 1)
        let req = try #require(rec.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/v1/messages")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-secret")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(req.value(forHTTPHeaderField: "content-type") == "application/json")
        let body = try #require(try JSONSerialization.jsonObject(with: rec.bodies[0]) as? [String: Any])
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect(body["max_tokens"] as? Int == 300)
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        let oc = try #require(body["output_config"] as? [String: Any])
        #expect(oc["effort"] as? String == "low")
        let format = try #require(oc["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect((schema["required"] as? [String])?.sorted() == ["confidence", "name"])
        let props = try #require(schema["properties"] as? [String: Any])
        let conf = try #require(props["confidence"] as? [String: Any])
        #expect(conf["enum"] as? [String] == ["high", "medium", "low"])
        let system = try #require(body["system"] as? String)
        #expect(system.contains("untrusted"))
        #expect(system.contains("2 to 6 words"))
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1 && messages[0]["role"] as? String == "user")
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        #expect(text.contains("scan_001.pdf") && text.contains("ignore previous instructions"))
        #expect(!String(decoding: rec.bodies[0], as: UTF8.self).contains("temperature"))
    }

    @Test func requestShapeForImage() async throws {
        let host = "img-\(UUID().uuidString.lowercased()).test"
        let c = makeClient(host: host, .init(status: 200, body: messageJSON(text: #"{"name":"a b c","confidence":"medium"}"#)))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        _ = await c.suggestName(for: .image(jpeg: jpeg), originalName: "IMG_1.jpg", apiKey: "k")
        let rec = StubProtocol.recorded(host: host)
        let body = try #require(try JSONSerialization.jsonObject(with: rec.bodies[0]) as? [String: Any])
        let content = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        let block = try #require(content.first { $0["type"] as? String == "image" })
        let source = try #require(block["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/jpeg")
        #expect(source["data"] as? String == jpeg.base64EncodedString())
    }

    @Test func classifyRequestSchema() async throws {
        let host = "cs-\(UUID().uuidString.lowercased()).test"
        let c = makeClient(host: host, .init(status: 200, body: messageJSON(text: #"{"generic":false}"#)))
        _ = await c.classifyStem("quarterly report", apiKey: "k")
        let rec = StubProtocol.recorded(host: host)
        let body = try #require(try JSONSerialization.jsonObject(with: rec.bodies[0]) as? [String: Any])
        let schema = try #require(((body["output_config"] as? [String: Any])?["format"] as? [String: Any])?["schema"] as? [String: Any])
        #expect((schema["required"] as? [String]) == ["generic"])
        #expect(((schema["properties"] as? [String: Any])?["generic"] as? [String: Any])?["type"] as? String == "boolean")
    }

    @Test(arguments: [400, 404, 413, 422])
    func finalStatuses(_ status: Int) async {
        let host = "f\(status)-\(UUID().uuidString.lowercased()).test"
        let c = makeClient(host: host, .init(status: status, body: errorJSON("invalid_request_error", "bad")))
        let r = await c.classifyStem("x", apiKey: "k")
        guard case .final(let reason, _) = r else { Issue.record("got \(r)"); return }
        #expect(reason.contains("\(status)"))
        #expect(StubProtocol.recorded(host: host).requests.count == 1)
    }

    @Test(arguments: [401, 402, 403])
    func authStatuses(_ status: Int) async {
        let host = "a\(status)-\(UUID().uuidString.lowercased()).test"
        let c = makeClient(host: host, .init(status: status, body: errorJSON("authentication_error", "no")))
        #expect(await c.classifyStem("x", apiKey: "k") == .authFailure(status: status))
        #expect(StubProtocol.recorded(host: host).requests.count == 1)
    }

    @Test func rateLimited() async {
        let host = "rl-\(UUID().uuidString.lowercased()).test"
        let c = makeClient(host: host, .init(status: 429, headers: ["retry-after": "17"], body: errorJSON("rate_limit_error", "slow")))
        #expect(await c.classifyStem("x", apiKey: "k") == .rateLimited(retryAfter: 17))
        let host2 = "rl2-\(UUID().uuidString.lowercased()).test"
        let c2 = makeClient(host: host2, .init(status: 429, body: errorJSON("rate_limit_error", "slow")))
        #expect(await c2.classifyStem("x", apiKey: "k") == .rateLimited(retryAfter: nil))
        #expect(StubProtocol.recorded(host: host2).requests.count == 1)
    }

    @Test(arguments: [500, 502, 503, 529])
    func transientStatuses(_ status: Int) async {
        let host = "t\(status)-\(UUID().uuidString.lowercased()).test"
        let c = makeClient(host: host, .init(status: status, body: errorJSON("overloaded_error", "busy")))
        guard case .transient = await c.classifyStem("x", apiKey: "k") else { Issue.record("not transient"); return }
        #expect(StubProtocol.recorded(host: host).requests.count == 1)
    }

    @Test func networkErrorIsTransient() async {
        let host = "net-\(UUID().uuidString.lowercased()).test"
        let c = makeClient(host: host, .init(status: 0, error: URLError(.timedOut)))
        guard case .transient = await c.suggestName(for: .text("t"), originalName: "n", apiKey: "k") else {
            Issue.record("not transient"); return
        }
        #expect(StubProtocol.recorded(host: host).requests.count == 1)
    }

    @Test func refusalIsFinalWithUsage() async {
        let host = "ref-\(UUID().uuidString.lowercased()).test"
        let c = makeClient(host: host, .init(status: 200, body: messageJSON(text: "", stop: "refusal")))
        #expect(await c.classifyStem("x", apiKey: "k") == .final(reason: "stop_reason refusal", usage: usage))
    }

    @Test func maxTokensIsFinal() async {
        let host = "mt-\(UUID().uuidString.lowercased()).test"
        let c = makeClient(host: host, .init(status: 200, body: messageJSON(text: #"{"name":"abc"#, stop: "max_tokens")))
        #expect(await c.suggestName(for: .text("t"), originalName: "n", apiKey: "k") == .final(reason: "stop_reason max_tokens", usage: usage))
    }

    @Test(arguments: ["not json", #"{"name":"only name"}"#, #"{"name":"x","confidence":"certain"}"#, ""])
    func unparseableOutputIsFinal(_ text: String) async {
        let host = "bad-\(UUID().uuidString.lowercased()).test"
        let c = makeClient(host: host, .init(status: 200, body: messageJSON(text: text)))
        guard case .final(_, let u) = await c.suggestName(for: .text("t"), originalName: "n", apiKey: "k") else {
            Issue.record("not final"); return
        }
        #expect(u == usage)
        #expect(StubProtocol.recorded(host: host).requests.count == 1)
    }

    @Test func garbageBodyIsFinal() async {
        let host = "gb-\(UUID().uuidString.lowercased()).test"
        let c = makeClient(host: host, .init(status: 200, body: Data("<html>".utf8)))
        guard case .final = await c.classifyStem("x", apiKey: "k") else { Issue.record("not final"); return }
    }

    #if DEBUG
    @Test func liveHostIsRefusedInDebug() async {
        // Skip when the developer opted in to live calls.
        guard ProcessInfo.processInfo.environment["DLTIDY_LIVE"] != "1" else { return }
        StubProtocol.register(host: "api.anthropic.com", .init(status: 200, body: messageJSON(text: #"{"generic":true}"#)))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let c = AnthropicNamingClient(session: URLSession(configuration: config))
        #expect(await c.classifyStem("x", apiKey: "k") == .final(reason: "live API disabled in tests", usage: nil))
        #expect(StubProtocol.recorded(host: "api.anthropic.com").requests.isEmpty)
    }
    #endif
}
