import Foundation
import CryptoKit

enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, anthropic
    var id: String { rawValue }
    var title: String { self == .openAI ? "OpenAI 兼容" : "Anthropic" }
    var defaultAddress: String { self == .openAI ? "https://api.openai.com/v1" : "https://api.anthropic.com" }
}

enum AIEndpoint {
    static func resolve(_ address: String, provider: AIProvider, model: String = "", imageOnly: Bool = false) throws -> URL {
        var input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw WorkspaceFailure("请输入有效的 API 地址。") }
        if !input.contains("://") { input = "https://" + input }
        guard var parts = URLComponents(string: input), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.scheme?.lowercased() == "https" else { throw WorkspaceFailure("API 地址需要使用 HTTPS，且不能包含用户名或密码。") }
        parts.scheme = "https"; parts.host = host.lowercased(); parts.fragment = nil
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/models") { path = String(path.dropLast("/models".count)) }
        let nativeImage = provider == .openAI && (imageOnly || AIModelRouting.usesImagesAPI(model))
        let suffix = provider == .anthropic ? "/messages" : nativeImage ? (host.lowercased() == "openrouter.ai" ? "/images" : "/images/generations") : "/chat/completions"
        if provider == .openAI, ["/images/generations", "/images/edits", "/images"].contains(where: path.hasSuffix) { }
        else if path.hasSuffix("/chat/completions") { path = String(path.dropLast("/chat/completions".count)) + suffix }
        else if path.hasSuffix("/messages") { path = String(path.dropLast("/messages".count)) + suffix }
        else if provider == .openAI, path.hasSuffix("/chat") { path += "/completions" }
        else {
            let versioned = path.split(separator: "/").contains { $0.range(of: #"^v[0-9]+(?:[a-z][a-z0-9]*)?$"#, options: .regularExpression) != nil }
            path += (versioned ? "" : "/v1") + suffix
        }
        parts.percentEncodedPath = path
        guard let url = parts.url else { throw WorkspaceFailure("无法补全 API 请求地址，请检查输入。") }
        return url
    }
    static func models(_ address: String, provider: AIProvider) throws -> URL {
        let url = try resolve(address, provider: provider)
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        for suffix in ["/chat/completions", "/images/generations", "/images/edits", "/messages", "/images"] where parts.percentEncodedPath.hasSuffix(suffix) {
            parts.percentEncodedPath = String(parts.percentEncodedPath.dropLast(suffix.count)); break
        }
        parts.percentEncodedPath += "/models"
        return parts.url!
    }
}

struct AIAvailableModel: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String?
    var inputModalities: [String]?
    var outputModalities: [String]?
    var maxOutputTokens: Int?
    var title: String { name?.isEmpty == false ? name! : id }
    var imageOnly: Bool { outputModalities?.contains("image") == true && outputModalities?.contains("text") != true }
    var usable: Bool {
        if let outputModalities { return outputModalities.contains("text") || outputModalities.contains("image") }
        let name = id.lowercased()
        return !["embedding", "rerank", "moderation", "whisper", "transcrib", "tts-", "realtime", "audio", "sora", "text-davinci", "babbage"].contains(where: name.contains)
    }
    static func initial(in values: [AIAvailableModel], preserving previous: String) -> AIAvailableModel? {
        values.first { $0.id == previous && $0.usable } ?? values.first { $0.usable && !$0.imageOnly && !AIModelRouting.usesImagesAPI($0.id) } ?? values.first { $0.usable }
    }
}

enum AIModelRouting {
    static func usesImagesAPI(_ model: String) -> Bool {
        let name = model.lowercased().split(separator: "/").last.map(String.init) ?? ""
        return name.hasPrefix("gpt-image-") || name.hasPrefix("dall-e-") || name == "chatgpt-image-latest"
    }
    static func requestsImageOutput(_ model: String) -> Bool {
        let name = model.lowercased()
        return (name.contains("gemini") && name.contains("image")) || (name.contains("gpt-") && name.contains("-image"))
    }
}

struct AIEndpointSettings: Codable, Equatable, Sendable {
    var address: String
    var model = ""
    var systemPrompt = ""
    var maxTokens = 4096
    var anthropicVersion = "2023-06-01"
    var availableModels: [AIAvailableModel]?
    var modelsUpdatedAt: Date?
}

struct AIChatConfiguration: Codable, Equatable, Sendable {
    var provider: AIProvider = .openAI
    var openAI = AIEndpointSettings(address: AIProvider.openAI.defaultAddress)
    var anthropic = AIEndpointSettings(address: AIProvider.anthropic.defaultAddress)
    init() { }
    private enum CodingKeys: String, CodingKey { case provider, openAI, anthropic }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decodeIfPresent(AIProvider.self, forKey: .provider) ?? .openAI
        openAI = try values.decodeIfPresent(AIEndpointSettings.self, forKey: .openAI) ?? AIEndpointSettings(address: AIProvider.openAI.defaultAddress)
        anthropic = try values.decodeIfPresent(AIEndpointSettings.self, forKey: .anthropic) ?? AIEndpointSettings(address: AIProvider.anthropic.defaultAddress)
    }
    func endpoint(for provider: AIProvider) -> AIEndpointSettings { provider == .openAI ? openAI : anthropic }
    mutating func setEndpoint(_ value: AIEndpointSettings, for provider: AIProvider) { if provider == .openAI { openAI = value } else { anthropic = value } }
    func connection(for requestedProvider: AIProvider? = nil) throws -> AIChatConnection {
        let provider = requestedProvider ?? self.provider, value = endpoint(for: provider)
        let model = value.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.utf8.count <= 200 else { throw WorkspaceFailure("请在 AI 接口设置中填写模型名称。") }
        guard value.systemPrompt.utf8.count <= 32768 else { throw WorkspaceFailure("系统提示词过长。") }
        if provider == .anthropic {
            guard (1...131072).contains(value.maxTokens), value.anthropicVersion.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw WorkspaceFailure("请检查 Anthropic 的输出上限和 API 版本。") }
        }
        let metadata = value.availableModels?.first { $0.id == model }
        return AIChatConnection(provider: provider, url: try AIEndpoint.resolve(value.address, provider: provider, model: model, imageOnly: metadata?.imageOnly == true), model: model, systemPrompt: value.systemPrompt, maxTokens: value.maxTokens, anthropicVersion: value.anthropicVersion, outputModalities: metadata?.outputModalities)
    }
}

struct AIChatConnection: Codable, Equatable, Sendable {
    let provider: AIProvider
    let url: URL
    let model: String
    let systemPrompt: String
    let maxTokens: Int
    let anthropicVersion: String
    var outputModalities: [String]? = nil
    var serviceID: String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        for suffix in ["/chat/completions", "/images/generations", "/images/edits", "/messages", "/images"] where parts.percentEncodedPath.hasSuffix(suffix) {
            parts.percentEncodedPath = String(parts.percentEncodedPath.dropLast(suffix.count)); break
        }
        return provider.rawValue + ":" + (parts.string ?? url.absoluteString)
    }
    var credentialID: String { Self.credentialID(provider: provider, url: url) }
    static func credentialID(provider: AIProvider, url: URL) -> String {
        "ai." + provider.rawValue + "." + SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum AIMessageRole: String, Codable, Sendable { case user, assistant }
enum AIMessageStatus: String, Codable, Sendable { case complete, streaming, failed, stopped }
enum AIAttachmentKind: String, Codable, Sendable { case image, video, file }
struct AIChatAttachment: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let name: String
    let kind: AIAttachmentKind
    let mediaType: String
    let byteCount: Int
    var thumbnailName: String?
}
struct AIChatMessage: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let role: AIMessageRole
    var content: String
    var status: AIMessageStatus = .complete
    var note: String?
    var attachments: [AIChatAttachment]?
    var modelLabel: String?
}
struct AIConversation: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var connection: AIChatConnection
    var messages: [AIChatMessage] = []
    var updatedAt = Date()
}
struct AIChatHistory: Codable, Sendable {
    var currentID: UUID?
    var conversations: [AIConversation] = []
}

struct AIChatRepository {
    let directory: URL
    let keyNamespace: String
    init(paths: WorkspacePaths = WorkspacePaths(), keyNamespace: String = "") { directory = paths.support.appendingPathComponent("AI"); self.keyNamespace = keyNamespace }
    private func load<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let file = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000 else { throw WorkspaceFailure("本地 AI 数据过大，暂时无法读取。") }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }
    private func save<T: Encodable>(_ value: T, name: String) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 20_000_000 else { throw WorkspaceFailure("本地对话记录已满，请删除部分历史对话后重试。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(name)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func configuration() throws -> AIChatConfiguration { try load(AIChatConfiguration.self, name: "configuration.json") ?? AIChatConfiguration() }
    func history() throws -> AIChatHistory { try load(AIChatHistory.self, name: "conversations.json") ?? AIChatHistory() }
    func saveConfiguration(_ value: AIChatConfiguration) throws { try save(value, name: "configuration.json") }
    func saveHistory(_ value: AIChatHistory) throws { try save(value, name: "conversations.json") }
    func key(provider: AIProvider, address: String) throws -> String {
        let id = AIChatConnection.credentialID(provider: provider, url: try AIEndpoint.resolve(address, provider: provider))
        return try SecureStore.data(key: keyNamespace + id).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    func saveKey(_ value: String, provider: AIProvider, address: String) throws {
        let id = AIChatConnection.credentialID(provider: provider, url: try AIEndpoint.resolve(address, provider: provider))
        if value.isEmpty { try SecureStore.deleteData(key: keyNamespace + id) }
        else { try SecureStore.saveData(Data(value.utf8), key: keyNamespace + id) }
    }
}
