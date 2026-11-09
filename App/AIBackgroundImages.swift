import Foundation
import UIKit
import UserNotifications

/// 一个交给系统后台会话的图像请求。
struct AIPendingImageJob: Codable, Equatable, Sendable {
    let conversationID: UUID
    let replyID: UUID
    /// 结果中的相对图片地址按这个地址解析。
    let baseURL: URL
    let createdAt: Date
}

/// 图像接口的后台传输。
///
/// 请求体写入文件后交给系统的后台上传会话：Retools 切到后台、被挂起甚至被系统结束后，
/// 系统仍会完成请求，结果到达时唤醒 Retools。结果先写入文件，再由 `AIChatStore` 写回对话，
/// 所以即使 AI 页面当时没有加载，下次打开也能拿到。
final class AIBackgroundImageTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let identifier = "dev.retools.ios.ai-images"
    static let shared = AIBackgroundImageTransfer()

    let directory: URL
    private let lock = NSLock()
    private var buffers: [Int: Data] = [:]
    private var eventsCompletion: (() -> Void)?
    /// 有结果写入磁盘时调用（在任意线程）。
    var onFinished: (@Sendable () -> Void)?

    init(directory: URL = WorkspacePaths().support.appendingPathComponent("AI/Pending")) {
        self.directory = directory
        super.init()
    }

    private(set) lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 1800
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// 应用启动时调用，重新连上系统里仍在进行的后台任务。
    func reconnect() { _ = session }

    /// 系统因后台任务唤醒应用时调用；处理完全部事件后回调。
    func handleEvents(completion: @escaping () -> Void) {
        lock.withLock { eventsCompletion = completion }
        reconnect()
    }

    private func file(_ id: UUID, _ suffix: String) -> URL { directory.appendingPathComponent(id.uuidString + "." + suffix) }

    func start(_ request: URLRequest, job: AIPendingImageJob) throws {
        guard let body = request.httpBody else { throw WorkspaceFailure("图像请求缺少内容。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 后台上传在锁屏时也要读取请求文件，所以用「首次解锁后可读」的保护级别。
        let bodyFile = file(job.replyID, "body")
        try body.write(to: bodyFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try JSONEncoder().encode(job).write(to: file(job.replyID, "job"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var upload = request
        upload.httpBody = nil
        let task = session.uploadTask(with: upload, fromFile: bodyFile)
        task.taskDescription = job.replyID.uuidString
        task.resume()
    }

    func cancel(_ replyID: UUID) {
        session.getAllTasks { tasks in tasks.filter { $0.taskDescription == replyID.uuidString }.forEach { $0.cancel() } }
        discard(replyID)
    }

    func discard(_ replyID: UUID) {
        for suffix in ["body", "job", "result", "status"] { try? FileManager.default.removeItem(at: file(replyID, suffix)) }
    }

    /// 已提交、尚未处理结果的任务。
    func jobs() -> [AIPendingImageJob] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".job") }.compactMap { name in
            (try? Data(contentsOf: directory.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(AIPendingImageJob.self, from: $0) }
        }
    }

    /// 已完成的结果：HTTP 状态码与响应体；网络失败时状态码为 0，响应体是错误说明。
    func result(for job: AIPendingImageJob) -> (status: Int, body: Data)? {
        guard let status = (try? String(contentsOf: file(job.replyID, "status"), encoding: .utf8)).flatMap({ Int($0) }),
              let body = try? Data(contentsOf: file(job.replyID, "result")) else { return nil }
        return (status, body)
    }

    // MARK: URLSession

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            var buffer = buffers[dataTask.taskIdentifier] ?? Data()
            // 与前台请求一致的响应上限。
            if buffer.count + data.count <= 60_000_000 { buffer.append(data) }
            buffers[dataTask.taskIdentifier] = buffer
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = lock.withLock { buffers.removeValue(forKey: task.taskIdentifier) } ?? Data()
        guard let description = task.taskDescription, let replyID = UUID(uuidString: description) else { return }
        try? FileManager.default.removeItem(at: file(replyID, "body"))
        // 已取消的任务不再写结果。
        guard FileManager.default.fileExists(atPath: file(replyID, "job").path) else { return }
        let status: Int, body: Data
        if let error {
            if (error as? URLError)?.code == .cancelled { status = 0; body = Data("已停止回答".utf8) }
            else { status = 0; body = Data(error.localizedDescription.utf8) }
        } else {
            status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            body = status == 0 ? Data("没有收到有效的 API 响应。".utf8) : data
        }
        try? body.write(to: file(replyID, "result"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? String(status).write(to: file(replyID, "status"), atomically: true, encoding: .utf8)
        onFinished?()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { () -> (() -> Void)? in let value = eventsCompletion; eventsCompletion = nil; return value }
        // 给对话写回留一点时间后再告诉系统可以挂起。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { completion?() }
    }

    /// 应用不在前台时提示图片已生成（需要用户已允许通知）。
    static func notifyIfInBackground(success: Bool) {
        Task { @MainActor in
            guard UIApplication.shared.applicationState != .active else { return }
            let content = UNMutableNotificationContent()
            content.title = success ? "图片已生成" : "图片生成未完成"
            content.body = success ? "回到 Retools 的 AI 对话查看结果。" : "打开 Retools 的 AI 对话查看原因。"
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "retools.ai.image." + UUID().uuidString, content: content, trigger: nil))
        }
    }
}
