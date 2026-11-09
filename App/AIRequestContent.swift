import Foundation

enum AIRequestContent {
    static func messages(_ messages: [AIChatMessage], provider: AIProvider, directory: URL?) throws -> [[String: Any]] {
        let messages = messages.filter { $0.status != .failed && $0.status != .streaming && (!$0.content.isEmpty || $0.attachments?.isEmpty == false) }
        let selected = Set(messages.flatMap { $0.attachments ?? [] }.suffix(12).map(\.id))
        var result: [[String: Any]] = [], pendingImages: [AIChatAttachment] = []
        var prepared: [UUID: [String: Any]] = [:], payloadBytes = 0
        func part(_ attachment: AIChatAttachment) throws -> [String: Any] {
            if let value = prepared[attachment.id] { return value }
            guard selected.contains(attachment.id) else { return ["type": "text", "text": "较早的附件「\(attachment.name)」本轮未再次传输。"] }
            guard let directory else { return ["type": "text", "text": "附件：" + attachment.name] }
            let file = try AIChatFiles.fileURL(attachment, directory: directory)
            let value: [String: Any]
            if attachment.kind == .image {
                guard let thumbnail = AIChatFiles.thumbnail(at: file, side: 1536) else { throw WorkspaceFailure("无法读取图片附件。") }
                let data = try AIChatFiles.jpeg(thumbnail), encoded = data.base64EncodedString(); payloadBytes += encoded.utf8.count
                value = provider == .openAI ? ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + encoded]] : ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": encoded]]
            } else {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                if attachment.kind == .file, attachment.mediaType != "application/pdf", data.count <= 1_000_000, !data.contains(0), let text = String(data: data, encoding: .utf8) {
                    payloadBytes += data.count
                    value = ["type": "text", "text": "附件「\(attachment.name)」：\n" + text]
                } else {
                    let encoded = data.base64EncodedString(); payloadBytes += encoded.utf8.count
                    if attachment.kind == .video {
                        guard provider == .openAI else { throw WorkspaceFailure("当前 Anthropic Messages 接口不支持视频输入。附件已保留，可切换到支持视频的兼容接口。") }
                        value = ["type": "video_url", "video_url": ["url": "data:\(attachment.mediaType);base64," + encoded]]
                    } else if provider == .anthropic {
                        guard attachment.mediaType == "application/pdf" else { throw WorkspaceFailure("当前 Anthropic 接口支持图片、PDF 和文本附件；请将这个文件转换为 PDF 或文本后发送。") }
                        value = ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": encoded], "title": attachment.name]
                    } else { value = ["type": "file", "file": ["filename": attachment.name, "file_data": "data:\(attachment.mediaType);base64," + encoded]] }
                }
            }
            guard payloadBytes <= (provider == .anthropic ? 25_000_000 : 60_000_000) else { throw WorkspaceFailure("附件内容超过当前接口的请求上限，请减少附件或新建对话。") }
            prepared[attachment.id] = value
            return value
        }
        for message in messages {
            if message.role == .assistant {
                pendingImages += (message.attachments ?? []).filter { $0.kind == .image }
                result.append(["role": "assistant", "content": message.content.isEmpty ? "图片已生成。" : message.content])
            } else {
                var parts: [[String: Any]] = []
                if !message.content.isEmpty { parts.append(["type": "text", "text": message.content]) }
                for attachment in pendingImages + (message.attachments ?? []) { parts.append(try part(attachment)) }
                pendingImages.removeAll()
                if parts.count == 1, let text = parts[0]["text"] as? String { result.append(["role": "user", "content": text]) }
                else if !parts.isEmpty { result.append(["role": "user", "content": parts]) }
            }
        }
        return result
    }

    static func multipartEditRequest(url: URL, key: String, model: String, prompt: String, images: [Data], extra: [String: Any] = [:]) throws -> URLRequest {
        let boundary = "RetoolsBoundary-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model); field("prompt", prompt); field("n", "1")
        for (name, value) in extra.sorted(by: { $0.key < $1.key }) { field(name, "\(value)") }
        let name = images.count > 1 ? "image[]" : "image"
        for (index, image) in images.enumerated() {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"reference-\(index + 1).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
            body.append(image); body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        guard body.count <= 50_000_000 else { throw WorkspaceFailure("参考图片过大，请减少图片后重试。") }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        return request
    }

    static func nativeImageRequest(connection: AIChatConnection, key: String, messages: [AIChatMessage], directory: URL?) throws -> URLRequest {
        guard let last = messages.last(where: { $0.role == .user }) else { throw WorkspaceFailure("请先输入消息或添加附件。") }
        let references = (last.attachments?.isEmpty == false ? last.attachments! : messages.dropLast().last(where: { $0.attachments?.contains(where: { $0.kind == .image }) == true })?.attachments ?? []).filter { $0.kind == .image }.suffix(4)
        guard last.attachments?.allSatisfy({ $0.kind == .image }) != false else { throw WorkspaceFailure("当前图像接口仅接受图片参考，文件和视频仍已保留在对话中。") }
        var url = connection.url, body: [String: Any] = ["model": connection.model, "prompt": last.content.isEmpty ? "请根据参考图片进行创作。" : last.content, "n": 1]
        let animation = AIImageAnimation.parameters(model: connection.model, prompt: last.content)
        body.merge(animation) { _, new in new }
        if let directory, !references.isEmpty {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            if parts.percentEncodedPath.hasSuffix("/images/generations") { parts.percentEncodedPath = String(parts.percentEncodedPath.dropLast("generations".count)) + "edits" }
            url = parts.url!
            var values: [[String: String]] = []
            var files: [Data] = []
            for attachment in references {
                let file = try AIChatFiles.fileURL(attachment, directory: directory)
                guard let thumbnail = AIChatFiles.thumbnail(at: file, side: 2048) else { throw WorkspaceFailure("无法读取参考图片。") }
                let jpeg = try AIChatFiles.jpeg(thumbnail)
                files.append(jpeg)
                values.append(["image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString()])
            }
            // 图片编辑接口按官方格式用 multipart 上传参考图文件，绝大多数中转接口也只接受这种格式。
            if url.path.hasSuffix("/edits") { return try multipartEditRequest(url: url, key: key, model: connection.model, prompt: body["prompt"] as? String ?? "", images: files, extra: animation) }
            else { body["input_references"] = values.compactMap { value -> [String: Any]? in
                guard let url = value["image_url"] else { return nil }
                return ["type": "image_url", "image_url": ["url": url]]
            } }
        }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= 50_000_000 else { throw WorkspaceFailure("参考图片过大，请减少图片后重试。") }
        request.httpBody = data; return request
    }
}

/// gpt-image-2.6 起，图像接口可以直接输出 GIF 动图（output_format: "gif"）。
/// 提示词里提到动图、GIF、动画时自动请求动图；默认 9 帧、每帧 200 毫秒，提示词写了「N 帧」则按 2–16 帧取值。
enum AIImageAnimation {
    static func supports(_ model: String) -> Bool {
        let name = model.lowercased()
        guard let match = name.range(of: #"gpt-image-(\d+)\.(\d+)"#, options: .regularExpression) else { return false }
        let numbers = name[match].dropFirst("gpt-image-".count).split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 2 else { return false }
        return numbers[0] > 2 || (numbers[0] == 2 && numbers[1] >= 6)
    }
    static func requested(_ prompt: String) -> Bool {
        let text = prompt.lowercased()
        return ["动图", "gif", "动画", "会动", "animated", "animation", "动起来"].contains { text.contains($0) }
    }
    static func parameters(model: String, prompt: String) -> [String: Any] {
        guard supports(model), requested(prompt) else { return [:] }
        var frames = 9
        if let match = prompt.range(of: #"(\d{1,2})\s*帧"#, options: .regularExpression), let value = Int(prompt[match].filter(\.isNumber)) { frames = min(16, max(2, value)) }
        return ["output_format": "gif", "frame_count": frames, "frame_duration_ms": 200]
    }
}
