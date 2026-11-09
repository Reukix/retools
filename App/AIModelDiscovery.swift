import Foundation

struct AIModelCatalog: Sendable {
    let provider: AIProvider
    let models: [AIAvailableModel]
}

private struct AIModelDiscoveryFailure: LocalizedError {
    let message: String
    var fallback = false
    var errorDescription: String? { message }
}

struct AIModelDiscovery: Sendable {
    let session: URLSession
    private let ownsSession: Bool
    init(session: URLSession? = nil) {
        ownsSession = session == nil
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 60
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ai-discovery-review") { configuration.protocolClasses = [AIModelReviewProtocol.self] }
            #endif
            self.session = URLSession(configuration: configuration, delegate: AIHTTPRedirectGuard(), delegateQueue: nil)
        }
    }
    static func request(address: String, key: String, provider: AIProvider, after: String? = nil) throws -> URLRequest {
        guard !key.contains(where: \.isNewline) else { throw WorkspaceFailure("API Key 含有换行，请重新填写。") }
        let base = try AIEndpoint.models(address, provider: provider)
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        if provider == .anthropic {
            var query = (parts.queryItems ?? []).filter { $0.name != "limit" && $0.name != "after_id" }
            query.append(URLQueryItem(name: "limit", value: "1000"))
            if let after { query.append(URLQueryItem(name: "after_id", value: after)) }
            parts.queryItems = query
        }
        var request = URLRequest(url: parts.url!); request.httpMethod = "GET"; request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider == .openAI { if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") } }
        else {
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }
    static func parse(_ data: Data) throws -> (models: [AIAvailableModel], more: Bool, last: String?, nativeAnthropic: Bool) {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw AIModelDiscoveryFailure(message: "接口没有返回有效的模型列表，请检查 API 地址。", fallback: true) }
        let root = object as? [String: Any]
        guard let values = root?["data"] as? [[String: Any]] ?? object as? [[String: Any]] else { throw AIModelDiscoveryFailure(message: "接口没有返回有效的模型列表，请检查 API 地址是否支持 /models。", fallback: true) }
        guard values.count <= 2000 else { throw WorkspaceFailure("服务返回的模型列表过大。") }
        var models: [AIAvailableModel] = [], seen = Set<String>()
        for value in values {
            guard let id = value["id"] as? String, !id.isEmpty, id.utf8.count <= 200, !id.contains(where: { $0.isNewline || $0 == "\0" }), seen.insert(id).inserted else { continue }
            if let lifecycle = value["lifecycle"] as? String, lifecycle == "retired" { continue }
            let architecture = value["architecture"] as? [String: Any]
            let output = architecture?["output_modalities"] as? [String] ?? value["output_modalities"] as? [String]
            let input = architecture?["input_modalities"] as? [String] ?? value["input_modalities"] as? [String]
            let limit = value["max_output_tokens"] as? Int ?? value["max_tokens"] as? Int ?? (value["top_provider"] as? [String: Any])?["max_completion_tokens"] as? Int
            let name = value["display_name"] as? String ?? value["name"] as? String
            models.append(AIAvailableModel(id: id, name: name.map { String($0.prefix(160)) }, inputModalities: input, outputModalities: output, maxOutputTokens: limit.flatMap { $0 > 0 ? $0 : nil }))
        }
        return (models, root?["has_more"] as? Bool == true, root?["last_id"] as? String, values.contains { $0["display_name"] is String && $0["created_at"] is String && $0["type"] as? String == "model" })
    }
    private func page(_ request: URLRequest, key: String) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        return try await withTaskCancellationHandler {
            guard let response = response as? HTTPURLResponse else { throw WorkspaceFailure("没有收到模型服务的有效响应。") }
            let success = (200..<300).contains(response.statusCode)
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < (success ? 4_000_000 : 65536) else { if success { throw WorkspaceFailure("服务返回的模型列表过大。") }; break }
                data.append(byte)
            }
            if !success {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let detail = object?["error"].map(AIChatClient.errorMessage) ?? object?["message"] as? String
                let message = "模型列表返回 HTTP \(response.statusCode)" + (detail.map { "：" + $0 } ?? "，请检查地址、密钥及模型列表访问权限。")
                throw AIModelDiscoveryFailure(message: AuthDiagnostics.sanitized(message, secrets: [key]), fallback: [400, 401, 403, 404, 405, 422].contains(response.statusCode))
            }
            return data
        } onCancel: { bytes.task.cancel() }
    }
    func discover(address: String, key: String, preferred: AIProvider? = nil) async throws -> AIModelCatalog {
        defer { if ownsSession { session.invalidateAndCancel() } }
        let url = try AIEndpoint.models(address, provider: .openAI)
        let host = url.host?.lowercased() ?? ""
        let providers: [AIProvider]
        if host == "api.anthropic.com" { providers = [.anthropic] }
        else if host == "api.openai.com" { providers = [.openAI] }
        else { let first = preferred ?? .openAI; providers = [first, first == .openAI ? .anthropic : .openAI] }
        var failure: Error?
        for provider in providers {
            do {
                var result: [AIAvailableModel] = [], cursor: String?, native = false
                for index in 0..<4 {
                    let request = try Self.request(address: address, key: key, provider: provider, after: cursor)
                    let parsed = try Self.parse(await page(request, key: key))
                    native = native || parsed.nativeAnthropic
                    let seen = Set(result.map(\.id)); result += parsed.models.filter { !seen.contains($0.id) }
                    guard result.count <= 2000 else { throw WorkspaceFailure("服务返回的模型列表过大。") }
                    if !parsed.more { break }
                    guard index < 3 else { throw WorkspaceFailure("服务返回的模型分页超过读取上限。") }
                    guard provider == .anthropic, let next = parsed.last, next != cursor else { throw WorkspaceFailure("服务返回的模型分页信息无效。") }
                    cursor = next
                }
                guard AIAvailableModel.initial(in: result, preserving: "") != nil else { throw WorkspaceFailure("当前密钥下没有可用于对话或图片的模型，请检查服务商授权。") }
                return AIModelCatalog(provider: native ? .anthropic : provider, models: result)
            } catch is CancellationError { throw CancellationError() }
            catch { if Task.isCancelled { throw CancellationError() }; failure = error; guard (error as? AIModelDiscoveryFailure)?.fallback == true else { throw error } }
        }
        throw failure ?? WorkspaceFailure("无法获取模型列表。")
    }
}
