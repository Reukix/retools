import XCTest
import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import CoreVideo
@testable import LiveContainerSwiftUI

final class AIChatTests: XCTestCase {
    private var root: URL!
    private var repository: AIChatRepository!
    private var credentials: [(AIProvider, String)] = []
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repository = AIChatRepository(paths: WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support")), keyNamespace: "test.ai." + UUID().uuidString + ".")
    }
    override func tearDownWithError() throws {
        for (provider, address) in credentials { try? repository.saveKey("", provider: provider, address: address) }
        try? FileManager.default.removeItem(at: root)
    }
    private func configuration(provider: AIProvider = .openAI) -> AIChatConfiguration {
        var value = AIChatConfiguration(); value.provider = provider
        value.openAI.address = "https://unit-api.example/v1"; value.openAI.model = "test-openai"
        value.anthropic.address = "https://unit-api.example/anthropic/v1"; value.anthropic.model = "test-anthropic"
        credentials += AIProvider.allCases.map { ($0, value.endpoint(for: $0).address) }
        return value
    }
    func testEndpointCompletionIsIdempotentAndPreservesPrefixes() throws {
        let values: [(String, String)] = [
            ("https://example.com", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1/", "https://example.com/v1/chat/completions"),
            ("example.com/api/v1", "https://example.com/api/v1/chat/completions"),
            ("https://example.com/api", "https://example.com/api/v1/chat/completions"),
            ("https://example.com/v1/chat", "https://example.com/v1/chat/completions"),
            ("https://example.com/chat/completions", "https://example.com/chat/completions"),
            ("https://example.com/v1/messages", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1beta/openai", "https://example.com/v1beta/openai/chat/completions"),
            ("https://example.com/gateway%20one/v1?api-version=test", "https://example.com/gateway%20one/v1/chat/completions?api-version=test")
        ]
        for (input, expected) in values {
            let result = try AIEndpoint.resolve(input, provider: .openAI)
            XCTAssertEqual(result.absoluteString, expected)
            XCTAssertEqual(try AIEndpoint.resolve(result.absoluteString, provider: .openAI), result)
        }
        XCTAssertEqual(try AIEndpoint.resolve("https://example.com/v1", provider: .anthropic).absoluteString, "https://example.com/v1/messages")
        XCTAssertEqual(try AIEndpoint.resolve("https://example.com", provider: .anthropic).absoluteString, "https://example.com/v1/messages")
        XCTAssertEqual(try AIEndpoint.resolve("https://example.com/proxy/v1/chat/completions/", provider: .anthropic).absoluteString, "https://example.com/proxy/v1/messages")
    }
    func testEndpointRejectsCredentialsWhitespaceAndNonHTTPS() {
        for value in ["", "http://example.com/v1", "https://user:password@example.com", "https://example.com/a b", "https://"] { XCTAssertThrowsError(try AIEndpoint.resolve(value, provider: .openAI)) }
    }
    func testRequestsUseSeparateHeadersAndSystemFormats() throws {
        var value = configuration(); value.openAI.systemPrompt = "test system"; value.anthropic.systemPrompt = "test system"
        let messages = [AIChatMessage(role: .user, content: "你好"), AIChatMessage(role: .assistant, content: "failed", status: .failed)]
        let openAI = try AIChatClient.request(connection: value.connection(), key: "test-only-key", messages: messages)
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
        XCTAssertNil(openAI.value(forHTTPHeaderField: "x-api-key"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(openAI.httpBody)) as? [String: Any])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"] }, ["system", "user"])
        value.provider = .anthropic
        let anthropic = try AIChatClient.request(connection: value.connection(), key: "test-only-key", messages: messages)
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "test-only-key")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(anthropic.value(forHTTPHeaderField: "Authorization"))
        let other = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(anthropic.httpBody)) as? [String: Any])
        XCTAssertEqual(other["system"] as? String, "test system")
        XCTAssertEqual(other["max_tokens"] as? Int, 4096)
        XCTAssertEqual((other["messages"] as? [[String: String]])?.count, 1)
        XCTAssertThrowsError(try AIChatClient.request(connection: value.connection(), key: "key\nheader", messages: messages))
    }
    func testSSEDecodersReadTextAndFinishWithoutExposingThinking() throws {
        var openAI = AISSEDecoder(provider: .openAI)
        XCTAssertEqual(try openAI.feed(": ping"), [])
        _ = try openAI.feed("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"你好\"},\"finish_reason\":null}]}")
        XCTAssertEqual(try openAI.feed(""), [.text("你好")])
        _ = try openAI.feed("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}")
        XCTAssertEqual(try openAI.flush(), [.finished(limited: true)]); XCTAssertTrue(openAI.ended)
        var anthropic = AISSEDecoder(provider: .anthropic)
        _ = try anthropic.feed("event: content_block_delta")
        _ = try anthropic.feed("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"not display text\"}}")
        XCTAssertEqual(try anthropic.feed(""), [])
        _ = try anthropic.feed("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"回答\"}}")
        XCTAssertEqual(try anthropic.feed(""), [.text("回答")])
        _ = try anthropic.feed("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}")
        _ = try anthropic.feed("")
        _ = try anthropic.feed("data: {\"type\":\"message_stop\"}")
        XCTAssertEqual(try anthropic.flush(), [.finished(limited: true)]); XCTAssertTrue(anthropic.ended)
    }
    func testStreamErrorsAndOversizedEventsAreRejected() throws {
        var decoder = AISSEDecoder(provider: .anthropic)
        _ = try decoder.feed("data: {\"type\":\"error\",\"error\":{\"message\":\"test failure\"}}")
        XCTAssertThrowsError(try decoder.flush()) { XCTAssertTrue($0.localizedDescription.contains("test failure")) }
        var oversized = AISSEDecoder(provider: .openAI)
        XCTAssertThrowsError(try oversized.feed("data: " + String(repeating: "x", count: 1_000_001)))
    }
    private func mockSession(status: Int = 200, type: String = "text/event-stream", body: String) -> URLSession {
        AIURLProtocol.install(status: status, type: type, body: Data(body.utf8))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AIURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    func testURLSessionStreamsBothProtocolsAndDetectsIncompleteResponses() async throws {
        let connection = try configuration().connection()
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"中文回复\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\n"
        let session = mockSession(body: body); defer { session.invalidateAndCancel() }
        var events: [AIStreamEvent] = []
        for try await event in AIChatClient(session: session).stream(connection: connection, key: "test-only-key", messages: [AIChatMessage(role: .user, content: "hi")]) { events.append(event) }
        XCTAssertEqual(events, [.text("中文回复"), .finished(limited: false)])
        AIURLProtocol.install(status: 200, type: "text/event-stream", body: Data(body.components(separatedBy: "data: [DONE]")[0].utf8))
        do {
            for try await _ in AIChatClient(session: session).stream(connection: connection, key: "", messages: [AIChatMessage(role: .user, content: "hi")]) { }
            XCTFail("Incomplete response accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("中断")) }
        let anthropic = "event: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Claude 回复\"}}\r\n\r\nevent: message_stop\r\ndata: {\"type\":\"message_stop\"}\r\n\r\n"
        AIURLProtocol.install(status: 200, type: "text/event-stream", body: Data(anthropic.utf8))
        events = []
        for try await event in AIChatClient(session: session).stream(connection: try configuration(provider: .anthropic).connection(), key: "", messages: [AIChatMessage(role: .user, content: "hi")]) { events.append(event) }
        XCTAssertEqual(events, [.text("Claude 回复"), .finished(limited: false)])
    }
    func testJSONFallbackAndHTTPFailureDoNotExposeKey() async throws {
        let value = configuration(provider: .anthropic)
        let session = mockSession(type: "application/json", body: "{\"content\":[{\"type\":\"text\",\"text\":\"非流式回复\"}],\"stop_reason\":\"end_turn\"}")
        defer { session.invalidateAndCancel() }
        var events: [AIStreamEvent] = []
        for try await event in AIChatClient(session: session).stream(connection: try value.connection(), key: "test-only-key", messages: [AIChatMessage(role: .user, content: "hi")]) { events.append(event) }
        XCTAssertEqual(events, [.text("非流式回复"), .finished(limited: false)])
        AIURLProtocol.install(status: 401, type: "application/json", body: Data("{\"error\":{\"message\":\"Invalid test-only-key\"}}".utf8))
        do {
            for try await _ in AIChatClient(session: session).stream(connection: try value.connection(), key: "test-only-key", messages: [AIChatMessage(role: .user, content: "hi")]) { }
            XCTFail("HTTP failure accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("401")); XCTAssertFalse(error.localizedDescription.contains("test-only-key")) }
    }
    func testRepositoryScopesCredentialsToProviderAndAddress() throws {
        let value = configuration()
        try repository.saveConfiguration(value)
        try repository.saveKey("test-only-key", provider: .openAI, address: value.openAI.address)
        XCTAssertEqual(try repository.key(provider: .openAI, address: value.openAI.address + "/chat/completions"), "test-only-key")
        XCTAssertEqual(try repository.key(provider: .anthropic, address: value.openAI.address), "")
        XCTAssertEqual(try repository.key(provider: .openAI, address: "https://another.example/v1"), "")
        XCTAssertFalse(try String(contentsOf: repository.directory.appendingPathComponent("configuration.json")).contains("test-only-key"))
    }
    @MainActor func testFailedConfigurationSaveRestoresExistingKey() throws {
        let store = AIChatStore(repository: repository, enabled: { true }), original = configuration()
        try store.saveConfiguration(original, keys: [.openAI: "test-old-key"])
        let file = repository.directory.appendingPathComponent("configuration.json")
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var updated = original; updated.openAI.model = "different-model"
        XCTAssertThrowsError(try store.saveConfiguration(updated, keys: [.openAI: "test-new-key"]))
        XCTAssertEqual(store.configuration, original)
        XCTAssertEqual(try repository.key(provider: .openAI, address: original.openAI.address), "test-old-key")
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("AI request did not reach expected state")
    }
    @MainActor func testFailedReplyRetriesWithoutDuplicatingQuestionAndPersistsHistory() async throws {
        let client = AITransportFixture(plans: [.failure, .reply])
        let store = AIChatStore(repository: repository, client: client, enabled: { true })
        try store.saveConfiguration(configuration(), keys: [:])
        XCTAssertTrue(store.send("测试问题")); try await waitUntil { !store.isGenerating }
        XCTAssertEqual(store.current?.messages.last?.status, .failed)
        store.retry(); try await waitUntil { !store.isGenerating }
        XCTAssertEqual(store.current?.messages.count, 2)
        XCTAssertEqual(store.current?.messages.last?.content, "测试回答")
        let reloaded = AIChatStore(repository: repository, client: client, enabled: { true })
        XCTAssertEqual(reloaded.current, store.current)
        XCTAssertEqual(client.calls.count, 2)
    }
    /// 后台完成的图像请求：结果写回回复（GIF 保持原格式），没有后台任务的旧回复标记为中断，临时文件被清理。
    @MainActor func testBackgroundImageResultsAreWrittenBackAfterRelaunch() async throws {
        var value = configuration(); value.openAI.model = "gpt-image-2.6-sunburst"
        let connection = try value.connection()
        let pendingReply = AIChatMessage(role: .assistant, content: "", status: .streaming, modelLabel: connection.model)
        let staleReply = AIChatMessage(role: .assistant, content: "", status: .streaming, modelLabel: connection.model)
        let conversation = AIConversation(title: "动图", connection: connection, messages: [AIChatMessage(role: .user, content: "做成动图"), pendingReply])
        let other = AIConversation(title: "旧", connection: connection, messages: [AIChatMessage(role: .user, content: "旧问题"), staleReply])
        var history = AIChatHistory(); history.conversations = [conversation, other]; history.currentID = conversation.id
        try repository.saveHistory(history)
        let transfer = AIBackgroundImageTransfer(directory: root.appendingPathComponent("Pending"))
        try FileManager.default.createDirectory(at: transfer.directory, withIntermediateDirectories: true)
        let job = AIPendingImageJob(conversationID: conversation.id, replyID: pendingReply.id, baseURL: connection.url, createdAt: Date())
        try JSONEncoder().encode(job).write(to: transfer.directory.appendingPathComponent(pendingReply.id.uuidString + ".job"))
        let gif = "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
        try JSONSerialization.data(withJSONObject: ["data": [["b64_json": gif]]]).write(to: transfer.directory.appendingPathComponent(pendingReply.id.uuidString + ".result"))
        try "200".write(to: transfer.directory.appendingPathComponent(pendingReply.id.uuidString + ".status"), atomically: true, encoding: .utf8)

        let store = AIChatStore(repository: repository, transfer: transfer, enabled: { true })
        await store.processBackgroundResults()
        let reply = try XCTUnwrap(store.history.conversations.first { $0.id == conversation.id }?.messages.last)
        XCTAssertEqual(reply.status, .complete)
        XCTAssertEqual(reply.attachments?.first?.mediaType, "image/gif")
        XCTAssertTrue(reply.attachments?.first?.name.hasSuffix(".gif") == true)
        XCTAssertEqual(store.history.conversations.first { $0.id == other.id }?.messages.last?.status, .stopped)
        XCTAssertFalse(store.isGenerating)
        XCTAssertTrue(transfer.jobs().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: transfer.directory.path).isEmpty)

        // 失败结果给出接口说明。
        let failing = AIChatMessage(role: .assistant, content: "", status: .streaming, modelLabel: connection.model)
        var next = store.history; next.conversations[0].messages.append(contentsOf: [AIChatMessage(role: .user, content: "再来"), failing])
        try repository.saveHistory(next)
        let failedJob = AIPendingImageJob(conversationID: conversation.id, replyID: failing.id, baseURL: connection.url, createdAt: Date())
        try JSONEncoder().encode(failedJob).write(to: transfer.directory.appendingPathComponent(failing.id.uuidString + ".job"))
        try JSONSerialization.data(withJSONObject: ["error": ["message": "frame_count too large"]]).write(to: transfer.directory.appendingPathComponent(failing.id.uuidString + ".result"))
        try "400".write(to: transfer.directory.appendingPathComponent(failing.id.uuidString + ".status"), atomically: true, encoding: .utf8)
        let reloaded = AIChatStore(repository: repository, transfer: transfer, enabled: { true })
        await reloaded.processBackgroundResults()
        let failed = try XCTUnwrap(reloaded.history.conversations.first { $0.id == conversation.id }?.messages.last)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.note, "API 返回 HTTP 400：frame_count too large")
    }
    @MainActor func testChangingEndpointDoesNotSendPreviousConversationToNewServer() async throws {
        let client = AITransportFixture(plans: [.reply, .reply])
        let store = AIChatStore(repository: repository, client: client, enabled: { true })
        var value = configuration(); try store.saveConfiguration(value, keys: [:])
        XCTAssertTrue(store.send("原地址的问题")); try await waitUntil { !store.isGenerating }
        value.openAI.address = "https://another.example/v1"; credentials.append((.openAI, value.openAI.address))
        try store.saveConfiguration(value, keys: [:])
        XCTAssertFalse(store.canContinue); XCTAssertFalse(store.send("不应发送")); XCTAssertEqual(client.calls.count, 1)
        store.newConversation(); XCTAssertTrue(store.send("新地址的问题")); try await waitUntil { !store.isGenerating }
        XCTAssertEqual(client.calls.last?.map(\.content), ["新地址的问题"])
        XCTAssertEqual(store.history.conversations.count, 2)
    }
    @MainActor func testDisabledFeatureDoesNotSendAndStoppingPreservesPartialReply() async throws {
        var enabled = false
        let client = AITransportFixture(plans: [.waiting])
        let store = AIChatStore(repository: repository, client: client, enabled: { enabled })
        try store.saveConfiguration(configuration(), keys: [:])
        XCTAssertFalse(store.send("关闭时")); XCTAssertTrue(client.calls.isEmpty)
        enabled = true; XCTAssertTrue(store.send("打开后")); try await waitUntil { store.current?.messages.last?.content == "部分回答" }
        enabled = false; store.stop()
        XCTAssertFalse(store.isGenerating); XCTAssertFalse(store.send("不应发送"))
        XCTAssertEqual(store.current?.messages.last?.status, .stopped)
        XCTAssertEqual(store.current?.messages.last?.content, "部分回答")
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(try repository.history().conversations.first?.messages.last?.status, .stopped)
    }
    @MainActor func testStoppingCancelsUnderlyingHTTPStream() async throws {
        let session = mockSession(body: "data: {\"choices\":[{\"delta\":{\"content\":\"部分回答\"},\"finish_reason\":null}]}\n\n")
        AIURLProtocol.keepOpen()
        defer { session.invalidateAndCancel() }
        let store = AIChatStore(repository: repository, client: AIChatClient(session: session), enabled: { true })
        try store.saveConfiguration(configuration(), keys: [:])
        XCTAssertTrue(store.send("hi"))
        try await waitUntil { store.current?.messages.last?.content == "部分回答" }
        store.stop()
        try await waitUntil { AIURLProtocol.stoppedCount > 0 }
        XCTAssertFalse(store.isGenerating)
        XCTAssertEqual(store.current?.messages.last?.status, .stopped)
    }
    @MainActor func testCorruptHistoryIsPreservedInsteadOfOverwritten() throws {
        try FileManager.default.createDirectory(at: repository.directory, withIntermediateDirectories: true)
        let file = repository.directory.appendingPathComponent("conversations.json"), data = Data("invalid history".utf8)
        try data.write(to: file)
        let store = AIChatStore(repository: repository, enabled: { true })
        XCTAssertNotNil(store.issue); XCTAssertFalse(store.send("message")); store.newConversation()
        XCTAssertThrowsError(try store.saveConfiguration(configuration(), keys: [:]))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    private func testPNG() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.95, green: 0.35, blue: 0.15, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let data = NSMutableData(), destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    func testImageAndTextAttachmentsAreCopiedAndEncodedForBothProtocols() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = try testPNG(), image = root.appendingPathComponent("Fixture.png"), text = root.appendingPathComponent("notes.txt")
        try original.write(to: image); try Data("test notes".utf8).write(to: text)
        let files = AIChatFiles(repository: repository)
        let photo = try await files.importFile(image), document = try await files.importFile(text)
        XCTAssertEqual(photo.kind, .image); XCTAssertNotNil(photo.thumbnailName)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(files.url(photo))), original)
        let messages = [AIChatMessage(role: .user, content: "查看附件", attachments: [photo, document])]
        for provider in AIProvider.allCases {
            let request = try AIChatClient.request(connection: configuration(provider: provider).connection(), key: "", messages: messages, attachmentsDirectory: files.directory)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            let parts = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
            XCTAssertEqual(parts.count, 3)
            XCTAssertEqual(parts[1]["type"] as? String, provider == .openAI ? "image_url" : "image")
            XCTAssertTrue((parts[2]["text"] as? String)?.contains("test notes") == true)
        }
        let invalid = AIChatAttachment(id: UUID(), fileName: "../escape", name: "bad", kind: .file, mediaType: "text/plain", byteCount: 0)
        XCTAssertThrowsError(try AIChatFiles.fileURL(invalid, directory: files.directory))
        await files.remove([photo, document]); XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(files.url(photo)).path))
    }
    func testOversizedAttachmentAndInvalidImageAreRejectedWithoutPartialFiles() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oversized = root.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized); try handle.truncate(atOffset: UInt64(AIChatFiles.maximumFileBytes + 1)); try handle.close()
        let files = AIChatFiles(repository: repository)
        do { _ = try await files.importFile(oversized); XCTFail("Oversized attachment accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("32 MB")) }
        let invalid = root.appendingPathComponent("invalid.png"); try Data("not an image".utf8).write(to: invalid)
        do { _ = try await files.importFile(invalid); XCTFail("Invalid image accepted") } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: files.directory.path).isEmpty)
    }
    private func makeVideo() async throws -> URL {
        let file = root.appendingPathComponent("clip.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer); CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 100, CVPixelBufferGetDataSize(pixels)); CVPixelBufferUnlockBaseAddress(pixels, [])
        for _ in 0..<100 { if input.isReadyForMoreMediaData { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(adapter.append(pixels, withPresentationTime: .zero))
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return file
    }
    func testVideoImportPreviewsAndUsesVideoPayloadForCompatibleInterface() async throws {
        let video = try await makeVideo(), files = AIChatFiles(repository: repository)
        let attachment = try await files.importFile(video)
        XCTAssertEqual(attachment.kind, .video); XCTAssertNotNil(attachment.thumbnailName)
        let messages = [AIChatMessage(role: .user, content: "查看视频", attachments: [attachment])]
        let request = try AIChatClient.request(connection: configuration().connection(), key: "", messages: messages, attachmentsDirectory: files.directory)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        let parts = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.last?["type"] as? String, "video_url")
        XCTAssertThrowsError(try AIChatClient.request(connection: configuration(provider: .anthropic).connection(), key: "", messages: messages, attachmentsDirectory: files.directory)) { XCTAssertTrue($0.localizedDescription.contains("视频")) }
    }
    @MainActor func testImageRepliesPersistInSameConversationAndCanBeReused() async throws {
        let png = try testPNG(), client = AITransportFixture(plans: [.image(png), .reply])
        let store = AIChatStore(repository: repository, client: client, enabled: { true })
        try store.saveConfiguration(configuration(), keys: [:])
        XCTAssertTrue(store.send("画一张图")); try await waitUntil { !store.isGenerating }
        let reply = try XCTUnwrap(store.current?.messages.last), attachment = try XCTUnwrap(reply.attachments?.first)
        XCTAssertEqual(reply.status, .complete); XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.attachmentURL(attachment))), png)
        let currentID = store.history.currentID
        store.reuseAttachment(attachment); XCTAssertTrue(store.send("结合图片继续")); try await waitUntil { !store.isGenerating }
        XCTAssertEqual(store.history.currentID, currentID); XCTAssertEqual(store.current?.messages.count, 4)
        XCTAssertEqual(client.calls.last?.last?.attachments?.first?.id, attachment.id)
        let reloaded = AIChatStore(repository: repository, client: client, enabled: { true })
        XCTAssertEqual(reloaded.current, store.current)
        let file = try XCTUnwrap(reloaded.attachmentURL(attachment))
        reloaded.delete(try XCTUnwrap(currentID)); try await waitUntil { !FileManager.default.fileExists(atPath: file.path) }
    }
    func testImageAPIAndChatImageRepliesAreDecodedAutomatically() async throws {
        let png = try testPNG(), base64 = png.base64EncodedString()
        let body = "{\"choices\":[{\"message\":{\"images\":[{\"image_url\":{\"url\":\"data:image/png;base64,\(base64)\"}}]},\"finish_reason\":\"stop\"}]}"
        let session = mockSession(type: "application/json", body: body); defer { session.invalidateAndCancel() }
        var events: [AIStreamEvent] = []
        for try await event in AIChatClient(session: session).stream(connection: try configuration().connection(), key: "test-only-key", messages: [AIChatMessage(role: .user, content: "draw")]) { events.append(event) }
        XCTAssertEqual(events, [.image(png), .finished(limited: false)])
        AIURLProtocol.install(status: 200, type: "application/json", body: Data("{\"data\":[{\"b64_json\":\"\(base64)\"}]}".utf8))
        var value = configuration(); value.openAI.model = "gpt-image-2.6-sunburst"
        let connection = try value.connection(); XCTAssertEqual(connection.url.path, "/v1/images/generations")
        let request = try AIChatClient.request(connection: connection, key: "", messages: [AIChatMessage(role: .user, content: "draw")])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(payload["prompt"] as? String, "draw"); XCTAssertNil(payload["messages"])
        events = []
        for try await event in AIChatClient(session: session).stream(connection: connection, key: "", messages: [AIChatMessage(role: .user, content: "draw")]) { events.append(event) }
        XCTAssertEqual(events, [.image(png), .finished(limited: false)])
    }
    func testNativeImageReferencesUseEditEndpointWithoutModeSelection() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("reference.png"); try testPNG().write(to: source)
        let files = AIChatFiles(repository: repository), attachment = try await files.importFile(source)
        var value = configuration(); value.openAI.model = "gpt-image-2.6-sunburst"
        let request = try AIChatClient.request(connection: value.connection(), key: "", messages: [AIChatMessage(role: .user, content: "修改背景", attachments: [attachment])], attachmentsDirectory: files.directory)
        XCTAssertEqual(request.url?.path, "/v1/images/edits")
        // 编辑接口用 multipart 上传参考图文件。
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let form = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(form.contains("name=\"model\"\r\n\r\ngpt-image-2.6-sunburst\r\n"))
        XCTAssertTrue(form.contains("name=\"prompt\"\r\n\r\n修改背景\r\n"))
        XCTAssertTrue(form.contains("name=\"image\"; filename=\"reference-1.jpg\"\r\nContent-Type: image/jpeg"))
        value.openAI.address = "https://openrouter.ai/api/v1"
        let compatible = try AIChatClient.request(connection: value.connection(), key: "", messages: [AIChatMessage(role: .user, content: "修改背景", attachments: [attachment])], attachmentsDirectory: files.directory)
        XCTAssertEqual(compatible.url?.path, "/api/v1/images")
        let compatibleBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(compatible.httpBody)) as? [String: Any])
        let reference = try XCTUnwrap((compatibleBody["input_references"] as? [[String: Any]])?.first)
        XCTAssertEqual(reference["type"] as? String, "image_url")
        XCTAssertTrue(((reference["image_url"] as? [String: String])?["url"] ?? "").hasPrefix("data:image/jpeg;base64,"))
    }
    func testAnimatedRequestsAskGptImage26ForGIF() async throws {
        XCTAssertTrue(AIImageAnimation.supports("gpt-image-2.6-sunburst")); XCTAssertTrue(AIImageAnimation.supports("gpt-image-3.0"))
        XCTAssertFalse(AIImageAnimation.supports("gpt-image-2.5")); XCTAssertFalse(AIImageAnimation.supports("gpt-image-1"))
        XCTAssertEqual(AIImageAnimation.parameters(model: "gpt-image-2.6-flare", prompt: "画一只猫").count, 0)
        XCTAssertEqual(AIImageAnimation.parameters(model: "gpt-image-2.5", prompt: "做成gif").count, 0)
        let defaults = AIImageAnimation.parameters(model: "gpt-image-2.6-flare", prompt: "做成动图")
        XCTAssertEqual(defaults["output_format"] as? String, "gif"); XCTAssertEqual(defaults["frame_count"] as? Int, 9); XCTAssertEqual(defaults["frame_duration_ms"] as? Int, 200)
        XCTAssertEqual(AIImageAnimation.parameters(model: "gpt-image-2.6-flare", prompt: "12 帧的 GIF")["frame_count"] as? Int, 12)
        XCTAssertEqual(AIImageAnimation.parameters(model: "gpt-image-2.6-flare", prompt: "40帧动画")["frame_count"] as? Int, 16)
        var value = configuration(); value.openAI.model = "gpt-image-2.6-sunburst"
        let generation = try AIChatClient.request(connection: value.connection(), key: "", messages: [AIChatMessage(role: .user, content: "小猫钓鱼的动图")])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(generation.httpBody)) as? [String: Any])
        XCTAssertEqual(body["output_format"] as? String, "gif"); XCTAssertEqual(body["frame_count"] as? Int, 9)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("gif-reference.png"); try testPNG().write(to: source)
        let files = AIChatFiles(repository: repository), attachment = try await files.importFile(source)
        let edit = try AIChatClient.request(connection: value.connection(), key: "", messages: [AIChatMessage(role: .user, content: "做成gif", attachments: [attachment])], attachmentsDirectory: files.directory)
        let form = String(decoding: try XCTUnwrap(edit.httpBody), as: UTF8.self)
        XCTAssertTrue(form.contains("name=\"output_format\"\r\n\r\ngif\r\n")); XCTAssertTrue(form.contains("name=\"frame_count\"\r\n\r\n9\r\n"))
    }
    func testImageLinksInReplyTextAreRecognised() {
        let text = "已生成：![动图](https://cdn.example.com/out/a.gif \"预览\")\n备用 https://cdn.example.com/b.webp?x=1。说明页 https://example.com/page ![](data:image/gif;base64,R0lGOD)"
        XCTAssertEqual(AIChatClient.imageLinks(in: text), ["https://cdn.example.com/out/a.gif", "data:image/gif;base64,R0lGOD", "https://cdn.example.com/b.webp?x=1"])
        XCTAssertEqual(AIChatClient.imageLinks(in: "没有图片 https://example.com/a"), [])
    }
    func testStreamingImageChunksKeepIndexesAndDecodeWithText() async throws {
        let png = try testPNG(), encoded = png.base64EncodedString(), split = encoded.index(encoded.startIndex, offsetBy: encoded.count / 2)
        let chunks: [[String: Any]] = [
            ["choices": [["delta": ["content": "图片说明", "images": [["index": 1, "image_url": ["url": "data:image/png;base64," + String(encoded[..<split])]]]]]]],
            ["choices": [["delta": ["images": [["index": 1, "image_url": ["url": String(encoded[split...])]]]]]]],
            ["choices": [["delta": [:], "finish_reason": "stop"]]]
        ]
        let body = try chunks.map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\r\n\r\n" }.joined()
        let session = mockSession(type: "text/event-stream", body: body); defer { session.invalidateAndCancel() }
        var events: [AIStreamEvent] = []
        for try await event in AIChatClient(session: session).stream(connection: try configuration().connection(), key: "", messages: [AIChatMessage(role: .user, content: "图片")]) { events.append(event) }
        XCTAssertEqual(events, [.text("图片说明"), .image(png), .finished(limited: false)])
        let complete: [String: Any] = ["choices": [["message": ["content": [["type": "text", "text": "说明"], ["type": "image_url", "image_url": ["url": "data:image/png;base64," + encoded]]]], "finish_reason": "stop"]]]
        XCTAssertEqual(try AIChatClient.completeResponse(JSONSerialization.data(withJSONObject: complete), provider: .openAI), [.text("说明"), .imageSource("data:image/png;base64," + encoded), .finished(limited: false)])
    }
    @MainActor func testModelCanChangeWithinSameInterfaceWithoutSplittingConversation() async throws {
        let client = AITransportFixture(plans: [.reply, .reply]), store = AIChatStore(repository: repository, client: client, enabled: { true })
        var value = configuration(); try store.saveConfiguration(value, keys: [:])
        XCTAssertTrue(store.send("第一问")); try await waitUntil { !store.isGenerating }
        let id = store.history.currentID
        value.openAI.model = "different-model"; try store.saveConfiguration(value, keys: [:])
        XCTAssertTrue(store.canContinue); XCTAssertTrue(store.send("继续")); try await waitUntil { !store.isGenerating }
        XCTAssertEqual(store.history.currentID, id); XCTAssertEqual(client.calls.last?.count, 3)
    }
}

private final class AIURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var response = (200, "text/event-stream", Data(), true)
    private static var stopped = 0
    static var stoppedCount: Int { lock.withLock { stopped } }
    static func install(status: Int, type: String, body: Data) { lock.withLock { response = (status, type, body, true); stopped = 0 } }
    static func keepOpen() { lock.withLock { response.3 = false } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "unit-api.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, type, data, finish) = Self.lock.withLock { Self.response }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: data.count, by: 5) { client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 5, data.count))) }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.lock.withLock { Self.stopped += 1 } }
}

private final class AITransportFixture: AIChatStreaming, @unchecked Sendable {
    enum Plan { case failure, reply, waiting, image(Data) }
    private let lock = NSLock()
    private var plans: [Plan]
    private var requests: [[AIChatMessage]] = []
    var calls: [[AIChatMessage]] { lock.withLock { requests } }
    init(plans: [Plan]) { self.plans = plans }
    func stream(connection: AIChatConnection, key: String, messages: [AIChatMessage], attachmentsDirectory: URL?) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let plan = lock.withLock { requests.append(messages); return plans.isEmpty ? Plan.reply : plans.removeFirst() }
        return AsyncThrowingStream { continuation in
            switch plan {
            case .failure: continuation.finish(throwing: WorkspaceFailure("test-only failure"))
            case .reply: continuation.yield(.text("测试回答")); continuation.yield(.finished(limited: false)); continuation.finish()
            case .waiting: continuation.yield(.text("部分回答"))
            case .image(let data): continuation.yield(.image(data)); continuation.yield(.finished(limited: false)); continuation.finish()
            }
        }
    }
}
