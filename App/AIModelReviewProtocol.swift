#if DEBUG
import Foundation

/// Non-network fixture, enabled only by the dedicated UI test launch argument.
final class AIModelReviewProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "ai-review.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let native = request.url?.path.contains("/anthropic/") == true
        let accepted = request.httpMethod == "GET" && request.url?.path.hasSuffix("/models") == true && (!native || request.value(forHTTPHeaderField: "x-api-key") == "review-only-key")
        let values: [[String: Any]] = native ? [["id": "review-claude", "type": "model", "display_name": "示例 Claude", "created_at": "2026-01-01T00:00:00Z"]] : [["id": "review-chat", "name": "示例对话模型", "architecture": ["output_modalities": ["text"]]], ["id": "review-image", "name": "示例图片模型", "architecture": ["output_modalities": ["image"]]]]
        let body: [String: Any] = accepted ? ["data": values, "has_more": false] : ["error": ["message": "Fixture authentication required"]]
        let response = HTTPURLResponse(url: request.url!, statusCode: accepted ? 200 : 401, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
