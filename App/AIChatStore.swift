import Foundation
import SwiftUI
import Photos

@MainActor
final class AIChatStore: ObservableObject {
    private static var loaded: AIChatStore?
    static var shared: AIChatStore {
        if let loaded { return loaded }
        let value = AIChatStore(); loaded = value; return value
    }
    static func stopIfLoaded() { loaded?.stop(); loaded?.draftID = UUID() }
    @Published private(set) var configuration = AIChatConfiguration()
    @Published private(set) var history = AIChatHistory()
    @Published private(set) var isGenerating = false
    @Published private(set) var isImporting = false
    @Published private(set) var draftAttachments: [AIChatAttachment] = []
    @Published var draftText = ""
    @Published var issue: String?
    @Published var notice: String?
    private let repository: AIChatRepository
    private let client: any AIChatStreaming
    private let enabled: () -> Bool
    private let files: AIChatFiles
    private var draftID = UUID()
    private var loadFailed = false
    private var generation: Task<Void, Never>?
    private var generationID: UUID?
    private var lastSavedAt = Date.distantPast
    /// 交给后台会话的图像请求对应的回复；重启后仍在进行时恢复。
    private var backgroundReplyID: UUID?
    private var processingBackground = false
    private let transfer: AIBackgroundImageTransfer
    private let imageClient = AIChatClient()
    var current: AIConversation? { history.conversations.first { $0.id == history.currentID } }
    var canContinue: Bool { current == nil || current?.connection.serviceID == (try? configuration.connection())?.serviceID }
    var configured: Bool { (try? configuration.connection()) != nil }
    var models: [AIAvailableModel] { configuration.endpoint(for: configuration.provider).availableModels?.filter(\.usable) ?? [] }
    func connectInterface(address: String, key: String, discovery: AIModelDiscovery = AIModelDiscovery()) async throws {
        guard enabled(), !isGenerating, !loadFailed else { throw WorkspaceFailure("请先开启 AI 功能，并停止正在生成的回答。") }
        let original = configuration, scope = try AIEndpoint.models(address, provider: .openAI)
        let active = configuration.endpoint(for: configuration.provider)
        let preferred = (try? AIEndpoint.models(active.address, provider: .openAI)) == scope ? configuration.provider : nil
        let catalog = try await discovery.discover(address: address, key: key, preferred: preferred)
        try Task.checkCancellation()
        guard enabled(), configuration == original else { throw WorkspaceFailure("接口配置已更改，本次连接未保存，请重试。") }
        var value = configuration
        let saved = value.endpoint(for: catalog.provider)
        let same = (try? AIEndpoint.models(saved.address, provider: .openAI)) == scope
        var endpoint = same ? saved : AIEndpointSettings(address: address)
        guard let model = AIAvailableModel.initial(in: catalog.models, preserving: same ? endpoint.model : "") else { throw WorkspaceFailure("没有可用模型。") }
        endpoint.address = address; endpoint.model = model.id; endpoint.availableModels = catalog.models; endpoint.modelsUpdatedAt = Date()
        endpoint.maxTokens = min(4096, model.maxOutputTokens ?? 4096)
        value.provider = catalog.provider; value.setEndpoint(endpoint, for: catalog.provider)
        try saveConfiguration(value, keys: [catalog.provider: key])
    }
    func selectModel(_ id: String) {
        guard !isGenerating, models.contains(where: { $0.id == id }) else { return }
        var value = configuration, endpoint = value.endpoint(for: value.provider)
        endpoint.model = id
        if value.provider == .anthropic, let maximum = models.first(where: { $0.id == id })?.maxOutputTokens { endpoint.maxTokens = min(4096, maximum) }
        value.setEndpoint(endpoint, for: value.provider)
        do { try saveConfiguration(value, keys: [:]) } catch { issue = error.localizedDescription }
    }

    init(repository: AIChatRepository = AIChatRepository(), client: any AIChatStreaming = AIChatClient(), transfer: AIBackgroundImageTransfer = .shared,
         enabled: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: "RetoolsAIEnabled") }) {
        self.repository = repository; self.client = client; self.enabled = enabled; self.transfer = transfer
        self.files = AIChatFiles(repository: repository)
        do {
            configuration = try repository.configuration()
            var value = try repository.history()
            let pending = Set(transfer.jobs().map(\.replyID))
            for index in value.conversations.indices {
                for message in value.conversations[index].messages.indices where value.conversations[index].messages[message].status == .streaming {
                    // 交给系统后台完成的图像请求仍在进行，不算中断。
                    let id = value.conversations[index].messages[message].id
                    if pending.contains(id) { backgroundReplyID = id; isGenerating = true; continue }
                    value.conversations[index].messages[message].status = .stopped
                    value.conversations[index].messages[message].note = "上次回答已中断"
                }
            }
            history = value
            // 对应回复已不存在的后台任务直接丢弃。
            let streaming = Set(value.conversations.flatMap(\.messages).filter { $0.status == .streaming }.map(\.id))
            for job in transfer.jobs() where !streaming.contains(job.replyID) { transfer.cancel(job.replyID) }
        } catch { loadFailed = true; issue = "无法读取本地 AI 数据：" + error.localizedDescription }
        transfer.onFinished = { [weak self] in Task { @MainActor in await self?.processBackgroundResults() } }
        Task { await processBackgroundResults() }
    }

    /// 把后台图像请求的结果写回对应回复：文字、图片（含 GIF）或失败原因。
    func processBackgroundResults() async {
        guard !processingBackground else { return }
        processingBackground = true; defer { processingBackground = false }
        func locate(_ job: AIPendingImageJob) -> (Int, Int)? {
            guard let conversation = history.conversations.firstIndex(where: { $0.id == job.conversationID }),
                  let message = history.conversations[conversation].messages.firstIndex(where: { $0.id == job.replyID }) else { return nil }
            return (conversation, message)
        }
        for job in transfer.jobs() {
            guard let result = transfer.result(for: job) else { continue }
            guard let (conversation, message) = locate(job), history.conversations[conversation].messages[message].status == .streaming else { transfer.discard(job.replyID); continue }
            var text = "", attachments: [AIChatAttachment] = [], failure: String?
            do {
                let parsed = try AIChatClient.backgroundResult(status: result.status, body: result.body)
                text = parsed.text
                for source in parsed.images.prefix(4) {
                    attachments.append(try await files.saveGeneratedImage(try await imageClient.imageData(source, relativeTo: job.baseURL)))
                }
            } catch { failure = error.localizedDescription }
            transfer.discard(job.replyID)
            if let (conversation, message) = locate(job), history.conversations[conversation].messages[message].status == .streaming {
                history.conversations[conversation].messages[message].content += text
                if !attachments.isEmpty { history.conversations[conversation].messages[message].attachments = (history.conversations[conversation].messages[message].attachments ?? []) + attachments }
                let empty = history.conversations[conversation].messages[message].content.isEmpty && history.conversations[conversation].messages[message].attachments?.isEmpty != false
                history.conversations[conversation].messages[message].status = failure != nil || empty ? .failed : .complete
                history.conversations[conversation].messages[message].note = failure ?? (empty ? "接口没有返回可显示的内容。" : nil)
                AIBackgroundImageTransfer.notifyIfInBackground(success: failure == nil && !empty)
            } else { await files.remove(attachments) }
            if backgroundReplyID == job.replyID { backgroundReplyID = nil; generationID = nil; generation = nil; isGenerating = false }
            saveHistory()
        }
    }
    func key(provider: AIProvider, address: String) throws -> String { try repository.key(provider: provider, address: address) }
    func attachmentURL(_ attachment: AIChatAttachment, thumbnail: Bool = false) -> URL? { files.url(attachment, thumbnail: thumbnail) }
    func importAttachment(_ source: URL) async {
        guard enabled(), !loadFailed, !isImporting else { return }
        guard draftAttachments.count < 8 else { issue = "每条消息最多添加 8 个附件。"; return }
        let token = draftID
        isImporting = true; defer { isImporting = false }
        do {
            let attachment = try await files.importFile(source)
            guard enabled(), token == draftID, !Task.isCancelled else { await files.remove([attachment]); return }
            guard draftAttachments.reduce(0, { $0 + $1.byteCount }) + attachment.byteCount <= 48_000_000 else { await files.remove([attachment]); throw WorkspaceFailure("一条消息的附件总量最多 48 MB，请减少附件。") }
            draftAttachments.append(attachment)
        } catch is CancellationError { }
        catch { issue = error.localizedDescription }
    }
    func removeDraftAttachment(_ id: UUID) {
        let removed = draftAttachments.filter { $0.id == id }; draftAttachments.removeAll { $0.id == id }
        releaseUnused(removed)
    }
    func reuseAttachment(_ attachment: AIChatAttachment) {
        guard draftAttachments.count < 8, !draftAttachments.contains(where: { $0.id == attachment.id }) else { return }
        guard draftAttachments.reduce(0, { $0 + $1.byteCount }) + attachment.byteCount <= 48_000_000 else { issue = "一条消息的附件总量最多 48 MB，请减少附件。"; return }
        draftAttachments.append(attachment)
    }
    @discardableResult
    func saveImageToPhotos(_ attachment: AIChatAttachment) async -> Bool {
        guard attachment.kind == .image, let file = files.url(attachment) else { return false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { issue = "尚未允许保存到相册。也可以通过分享将图片保存到「文件」。"; return false }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil) }
            notice = "已保存到相册"; return true
        } catch { issue = "保存图片失败：" + error.localizedDescription; return false }
    }
    private func releaseUnused(_ attachments: [AIChatAttachment]) {
        let retained = Set(history.conversations.flatMap(\.messages).flatMap { $0.attachments ?? [] }.map(\.id) + draftAttachments.map(\.id))
        let unused = attachments.filter { !retained.contains($0.id) }
        Task { await files.remove(unused) }
    }
    func saveConfiguration(_ value: AIChatConfiguration, keys: [AIProvider: String]) throws {
        guard !loadFailed else { throw WorkspaceFailure("本地 AI 数据读取失败，已暂停写入以保留原文件。") }
        guard !isGenerating else { throw WorkspaceFailure("请先停止正在生成的回答。") }
        _ = try value.connection()
        var previous: [AIProvider: String] = [:]
        for provider in AIProvider.allCases {
            let endpoint = value.endpoint(for: provider)
            _ = try AIEndpoint.resolve(endpoint.address, provider: provider)
            let key = keys[provider] ?? ""
            guard !key.contains(where: \.isNewline) else { throw WorkspaceFailure("API Key 含有换行，请重新填写。") }
            previous[provider] = try repository.key(provider: provider, address: endpoint.address)
        }
        do {
            for provider in AIProvider.allCases { try repository.saveKey(keys[provider] ?? previous[provider] ?? "", provider: provider, address: value.endpoint(for: provider).address) }
            try repository.saveConfiguration(value)
            configuration = value
        } catch {
            for provider in AIProvider.allCases { try? repository.saveKey(previous[provider] ?? "", provider: provider, address: value.endpoint(for: provider).address) }
            throw error
        }
    }
    private func saveHistory() {
        guard !loadFailed else { return }
        lastSavedAt = Date()
        do { try repository.saveHistory(history) }
        catch { issue = "对话记录保存失败：" + error.localizedDescription }
    }
    func newConversation() {
        guard !loadFailed else { issue = "本地 AI 数据读取失败，已保留原文件。"; return }
        stop(); draftID = UUID(); let pending = draftAttachments; draftAttachments = []; draftText = ""
        history.currentID = nil; issue = nil; saveHistory(); releaseUnused(pending)
    }
    func open(_ id: UUID) {
        guard let conversation = history.conversations.first(where: { $0.id == id }) else { return }
        stop()
        if conversation.connection.serviceID == (try? configuration.connection(for: conversation.connection.provider))?.serviceID {
            var value = configuration; value.provider = conversation.connection.provider
            do { try repository.saveConfiguration(value); configuration = value } catch { issue = error.localizedDescription }
        }
        draftID = UUID(); let pending = draftAttachments; draftAttachments = []; draftText = ""
        history.currentID = id; saveHistory(); releaseUnused(pending)
    }
    func delete(_ id: UUID) {
        if history.currentID == id { stop(); history.currentID = nil }
        let removed = history.conversations.first { $0.id == id }?.messages.flatMap { $0.attachments ?? [] } ?? []
        var next = history; next.conversations.removeAll { $0.id == id }
        do { try repository.saveHistory(next); history = next; releaseUnused(removed) }
        catch { issue = "无法删除对话：" + error.localizedDescription }
    }
    @discardableResult
    func send(_ text: String) -> Bool {
        guard enabled(), !isGenerating, !isImporting, !loadFailed else { return false }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftAttachments.isEmpty else { return false }
        do {
            guard text.utf8.count <= 65536 else { throw WorkspaceFailure("单条消息过长，请分段发送。") }
            let connection = try configuration.connection()
            guard canContinue else { throw WorkspaceFailure("接口配置已更改，请新建对话后继续，历史内容会保留。") }
            let key = try repository.key(provider: connection.provider, address: configuration.endpoint(for: connection.provider).address)
            var next = history
            if next.currentID == nil || !next.conversations.contains(where: { $0.id == next.currentID }) {
                guard next.conversations.count < 200 else { throw WorkspaceFailure("历史对话已满，请删除部分记录后新建。") }
                let conversation = AIConversation(title: text.isEmpty ? draftAttachments.first?.name ?? "附件对话" : String(text.prefix(36)), connection: connection)
                next.conversations.insert(conversation, at: 0); next.currentID = conversation.id
            }
            let index = next.conversations.firstIndex { $0.id == next.currentID }!
            guard next.conversations[index].messages.count < 200 else { throw WorkspaceFailure("这段对话较长，请新建对话后继续。") }
            next.conversations[index].connection = connection
            next.conversations[index].messages.append(AIChatMessage(role: .user, content: text, attachments: draftAttachments.isEmpty ? nil : draftAttachments))
            let messages = next.conversations[index].messages
            _ = try AIChatClient.request(connection: connection, key: key, messages: messages)
            let reply = AIChatMessage(role: .assistant, content: "", status: .streaming, modelLabel: connection.model)
            next.conversations[index].messages.append(reply); next.conversations[index].updatedAt = Date()
            try repository.saveHistory(next)
            history = next; issue = nil; isGenerating = true
            draftAttachments = []; draftText = ""; draftID = UUID()
            let token = UUID(), conversationID = next.conversations[index].id
            generationID = token
            // 图像接口不是流式的：交给系统后台会话，切走或被挂起后仍会完成。
            if AIChatClient.isNativeImage(connection) {
                do {
                    let request = try AIChatClient.request(connection: connection, key: key, messages: messages, attachmentsDirectory: files.directory)
                    try transfer.start(request, job: AIPendingImageJob(conversationID: conversationID, replyID: reply.id, baseURL: connection.url, createdAt: Date()))
                    backgroundReplyID = reply.id
                } catch {
                    finish(token: token, conversationID: conversationID, replyID: reply.id, status: .failed, note: AuthDiagnostics.sanitized(error.localizedDescription, secrets: [key]))
                }
                return true
            }
            generation = Task {
                var limited = false
                // 切到后台时向系统多申请一段运行时间（通常约 30 秒），让快完成的生成还能收尾。
                let lease = BackgroundLease("Retools AI 生成")
                defer { lease.end() }
                do {
                    for try await event in client.stream(connection: connection, key: key, messages: messages, attachmentsDirectory: files.directory) {
                        guard generationID == token else { return }
                        guard let conversation = history.conversations.firstIndex(where: { $0.id == conversationID }), let message = history.conversations[conversation].messages.firstIndex(where: { $0.id == reply.id }) else { return }
                        switch event {
                        case .text(let text):
                            guard history.conversations[conversation].messages[message].content.utf8.count + text.utf8.count <= 2_000_000 else { throw WorkspaceFailure("回答过长，已保留收到的内容。") }
                            history.conversations[conversation].messages[message].content += text
                            if Date().timeIntervalSince(lastSavedAt) >= 1 { saveHistory() }
                        case .finished(let value): limited = value
                        case .image(let data):
                            let attachment = try await files.saveGeneratedImage(data)
                            guard generationID == token, let freshConversation = history.conversations.firstIndex(where: { $0.id == conversationID }), let freshMessage = history.conversations[freshConversation].messages.firstIndex(where: { $0.id == reply.id }) else { await files.remove([attachment]); return }
                            history.conversations[freshConversation].messages[freshMessage].attachments = (history.conversations[freshConversation].messages[freshMessage].attachments ?? []) + [attachment]
                            saveHistory()
                        case .imageSource: throw WorkspaceFailure("图片响应未完成解码。")
                        }
                    }
                    finish(token: token, conversationID: conversationID, replyID: reply.id, status: .complete, note: limited ? "已达到输出上限" : nil)
                } catch {
                    finish(token: token, conversationID: conversationID, replyID: reply.id, status: error is CancellationError ? .stopped : .failed, note: error is CancellationError ? "已停止回答" : AuthDiagnostics.sanitized(error.localizedDescription, secrets: [key]))
                }
            }
            return true
        } catch { issue = error.localizedDescription; return false }
    }
    private func finish(token: UUID, conversationID: UUID, replyID: UUID, status: AIMessageStatus, note: String?) {
        guard generationID == token else { return }
        if let conversation = history.conversations.firstIndex(where: { $0.id == conversationID }), let message = history.conversations[conversation].messages.firstIndex(where: { $0.id == replyID }) {
            let empty = history.conversations[conversation].messages[message].content.isEmpty && history.conversations[conversation].messages[message].attachments?.isEmpty != false
            history.conversations[conversation].messages[message].status = status == .complete && empty ? .failed : status
            history.conversations[conversation].messages[message].note = status == .complete && empty ? "接口没有返回可显示的内容。" : note
        }
        generationID = nil; generation = nil; isGenerating = false; saveHistory()
    }
    func stop() {
        guard isGenerating else { return }
        if let id = backgroundReplyID { transfer.cancel(id); backgroundReplyID = nil }
        generationID = nil; generation?.cancel(); generation = nil; isGenerating = false
        if let index = history.conversations.firstIndex(where: { $0.id == history.currentID }), let message = history.conversations[index].messages.lastIndex(where: { $0.status == .streaming }) {
            history.conversations[index].messages[message].status = .stopped
            history.conversations[index].messages[message].note = "已停止回答"
        }
        saveHistory()
    }
    func retry() {
        guard !isGenerating, let index = history.conversations.firstIndex(where: { $0.id == history.currentID }), let last = history.conversations[index].messages.last,
              last.role == .assistant, last.status == .failed || last.status == .stopped,
              history.conversations[index].messages.count >= 2 else { return }
        let question = history.conversations[index].messages[history.conversations[index].messages.count - 2]
        guard question.role == .user else { return }
        let previous = history
        let oldDraft = draftAttachments
        draftAttachments = question.attachments ?? []
        if last.attachments?.isEmpty == false {
            if !send(question.content) { draftAttachments = oldDraft }
            return
        }
        history.conversations[index].messages.removeLast(2)
        if !send(question.content) { history = previous; draftAttachments = oldDraft }
    }
}
