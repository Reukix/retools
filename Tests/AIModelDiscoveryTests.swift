import XCTest
@testable import LiveContainerSwiftUI

final class AIModelDiscoveryTests: XCTestCase {
    private var root: URL!
    private var repository: AIChatRepository!
    private var session: URLSession!
    private let address = "https://unit-models.example/gateway/v1"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repository = AIChatRepository(paths: WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support")), keyNamespace: "test.models." + UUID().uuidString + ".")
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ModelsURLProtocol.self]
        session = URLSession(configuration: configuration)
        ModelsURLProtocol.install { _ in (200, ["data": [["id": "available-chat"]]]) }
    }
    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        for provider in AIProvider.allCases { try? repository.saveKey("", provider: provider, address: address) }
        try? FileManager.default.removeItem(at: root)
    }
    func testModelsEndpointAcceptsBaseAndCompleteRoutesWithoutDuplication() throws {
        for suffix in ["", "/", "/models", "/chat/completions", "/messages", "/images/generations", "/images/edits"] {
            XCTAssertEqual(try AIEndpoint.models(address + suffix, provider: .openAI).absoluteString, address + "/models")
        }
        XCTAssertEqual(try AIEndpoint.models("https://unit-models.example", provider: .anthropic).path, "/v1/models")
        XCTAssertEqual(try AIEndpoint.models(address + "?api-version=test", provider: .openAI).query, "api-version=test")
        XCTAssertEqual(try AIEndpoint.resolve(address + "/models", provider: .openAI).path, "/gateway/v1/chat/completions")
    }
    func testDiscoveryOnlyUsesGETAndSeparateAuthenticationHeaders() throws {
        let compatible = try AIModelDiscovery.request(address: address, key: "test-model-key", provider: .openAI)
        XCTAssertEqual(compatible.httpMethod, "GET"); XCTAssertNil(compatible.httpBody)
        XCTAssertEqual(compatible.value(forHTTPHeaderField: "Authorization"), "Bearer test-model-key")
        XCTAssertNil(compatible.value(forHTTPHeaderField: "x-api-key"))
        let native = try AIModelDiscovery.request(address: address, key: "test-model-key", provider: .anthropic, after: "cursor/one")
        XCTAssertEqual(native.value(forHTTPHeaderField: "x-api-key"), "test-model-key"); XCTAssertNil(native.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(native.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(URLComponents(url: native.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "after_id" })?.value, "cursor/one")
        XCTAssertThrowsError(try AIModelDiscovery.request(address: address, key: "bad\nheader", provider: .openAI))
    }
    func testCatalogDeduplicatesAndSelectsAUsableInitialModel() throws {
        let body: [String: Any] = ["data": [["id": "text-embedding-test"], ["id": "image-alias", "name": "Image", "architecture": ["output_modalities": ["image"]]], ["id": "chat-alias", "name": "Chat", "architecture": ["output_modalities": ["text", "image"]]], ["id": "chat-alias"], ["id": "retired-chat", "lifecycle": "retired"], ["id": ""]]]
        let models = try AIModelDiscovery.parse(JSONSerialization.data(withJSONObject: body)).models
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(AIAvailableModel.initial(in: models, preserving: "")?.id, "chat-alias")
        XCTAssertEqual(AIAvailableModel.initial(in: models, preserving: "image-alias")?.id, "image-alias")
        var configuration = AIChatConfiguration(); configuration.openAI.address = address; configuration.openAI.availableModels = models
        configuration.openAI.model = "image-alias"
        XCTAssertEqual(try configuration.connection().url.path, "/gateway/v1/images/generations")
        configuration.openAI.model = "chat-alias"
        let request = try AIChatClient.request(connection: configuration.connection(), key: "", messages: [AIChatMessage(role: .user, content: "test")])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(payload["modalities"] as? [String], ["text", "image"])
    }
    func testAutomaticNativeDetectionAndPaginationReuseOnlyTheSameHost() async throws {
        ModelsURLProtocol.install { request in
            guard request.value(forHTTPHeaderField: "x-api-key") == "test-model-key" else { return (401, ["error": ["message": "native header required"]]) }
            let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "after_id" }?.value
            let row: [String: Any] = ["id": after == nil ? "claude-a" : "claude-b", "type": "model", "display_name": "Claude", "created_at": "2026-01-01T00:00:00Z"]
            return (200, ["data": [row], "has_more": after == nil, "last_id": after == nil ? "claude-a" : "claude-b"])
        }
        let catalog = try await AIModelDiscovery(session: session).discover(address: address, key: "test-model-key")
        XCTAssertEqual(catalog.provider, .anthropic); XCTAssertEqual(catalog.models.map(\.id), ["claude-a", "claude-b"])
        XCTAssertEqual(ModelsURLProtocol.requests.count, 3)
        XCTAssertTrue(ModelsURLProtocol.requests.allSatisfy { $0.url?.host == "unit-models.example" && $0.httpMethod == "GET" })
    }
    @MainActor func testTwoFieldConnectionCachesModelsAndKeyWithoutManualModelInput() async throws {
        ModelsURLProtocol.install { _ in (200, ["data": [["id": "available-chat"], ["id": "available-image", "output_modalities": ["image"]]]]) }
        let store = AIChatStore(repository: repository, enabled: { true })
        try await store.connectInterface(address: address, key: "test-model-key", discovery: AIModelDiscovery(session: session))
        XCTAssertEqual(store.configuration.openAI.model, "available-chat"); XCTAssertEqual(store.models.count, 2)
        XCTAssertEqual(try repository.key(provider: .openAI, address: address), "test-model-key")
        let data = try Data(contentsOf: repository.directory.appendingPathComponent("configuration.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("test-model-key"))
        store.selectModel("available-image")
        XCTAssertEqual(try repository.configuration().connection().url.path, "/gateway/v1/images/generations")
        let reloaded = AIChatStore(repository: repository, enabled: { true }); XCTAssertEqual(reloaded.models, store.models)
    }
    @MainActor func testFailedConnectionPreservesPreviousConfigurationAndKeyAndRedactsError() async throws {
        let store = AIChatStore(repository: repository, enabled: { true }), discovery = AIModelDiscovery(session: session)
        try await store.connectInterface(address: address, key: "previous-test-key", discovery: discovery)
        let before = try Data(contentsOf: repository.directory.appendingPathComponent("configuration.json"))
        ModelsURLProtocol.install { _ in (401, ["error": ["message": "rejected secret-test-key"]]) }
        do { try await store.connectInterface(address: address, key: "secret-test-key", discovery: discovery); XCTFail("Unauthorized connection saved") }
        catch { XCTAssertFalse(error.localizedDescription.contains("secret-test-key")); XCTAssertTrue(error.localizedDescription.contains("401")) }
        XCTAssertEqual(try Data(contentsOf: repository.directory.appendingPathComponent("configuration.json")), before)
        XCTAssertEqual(try repository.key(provider: .openAI, address: address), "previous-test-key")
    }
    @MainActor func testDisabledFeatureDoesNotFetchModels() async {
        let store = AIChatStore(repository: repository, enabled: { false })
        do { try await store.connectInterface(address: address, key: "", discovery: AIModelDiscovery(session: session)); XCTFail("Connected while disabled") } catch { }
        XCTAssertTrue(ModelsURLProtocol.requests.isEmpty)
    }
    func testMalformedAndUnsupportedModelListsFailWithoutGuessing() async throws {
        XCTAssertThrowsError(try AIModelDiscovery.parse(Data("invalid json".utf8)))
        ModelsURLProtocol.install { _ in (200, ["data": [["id": "text-embedding-only"]]]) }
        do { _ = try await AIModelDiscovery(session: session).discover(address: address, key: ""); XCTFail("Selected an embedding model") }
        catch { XCTAssertTrue(error.localizedDescription.contains("没有可用于")) }
    }
    func testDiscoveryCancellationStopsTheUnderlyingRequest() async throws {
        ModelsURLProtocol.keepOpen = true
        let session = session!, address = address
        let task = Task { try await AIModelDiscovery(session: session).discover(address: address, key: "") }
        for _ in 0..<100 { if !ModelsURLProtocol.requests.isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled discovery completed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertGreaterThan(ModelsURLProtocol.stopped, 0)
    }
}

private final class ModelsURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (Int, [String: Any]))!
    private static var observed: [URLRequest] = []
    private static var stops = 0
    private static var open = false
    static var keepOpen: Bool { get { lock.withLock { open } } set { lock.withLock { open = newValue } } }
    static var requests: [URLRequest] { lock.withLock { observed } }
    static var stopped: Int { lock.withLock { stops } }
    static func install(_ handler: @escaping (URLRequest) throws -> (Int, [String: Any])) { lock.withLock { Self.handler = handler; observed = []; stops = 0; open = false } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "unit-models.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (handler, open) = Self.lock.withLock { Self.observed.append(request); return (Self.handler!, Self.open) }
            let (status, object) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            if !open { client?.urlProtocolDidFinishLoading(self) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { Self.lock.withLock { Self.stops += 1 } }
}
