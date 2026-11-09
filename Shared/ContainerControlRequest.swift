import Foundation

struct ContainerControlRequest: Codable, Sendable, Equatable {
    enum Action: String, Codable, Sendable { case switchApp, workbench }
    let version: Int
    let action: Action
    let createdAt: Date
    let appID: UUID?
    let containerID: UUID?
    init(action: Action, appID: UUID? = nil, containerID: UUID? = nil, createdAt: Date = Date()) {
        version = 1; self.action = action; self.appID = appID; self.containerID = containerID; self.createdAt = createdAt
    }
    func validate(now: Date = Date()) throws {
        guard version == 1, now.timeIntervalSince(createdAt) >= -30, now.timeIntervalSince(createdAt) <= 300,
              action == .switchApp ? (appID != nil && containerID != nil) : (appID == nil && containerID == nil) else {
            throw ContainerControlFailure("容器切换请求已失效，请重新选择应用。")
        }
    }
}

struct ContainerControlFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ContainerControlMailbox {
    static func location(in support: URL) -> URL { support.appendingPathComponent("Runtime/next-action.json") }
    static func write(_ request: ContainerControlRequest, support: URL) throws {
        try request.validate()
        let url = location(in: support)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func consume(support: URL, now: Date = Date()) throws -> ContainerControlRequest? {
        let url = location(in: support), fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 16_384 else {
            throw ContainerControlFailure("容器切换请求格式无效。")
        }
        defer { try? fm.removeItem(at: url) }
        let request = try JSONDecoder().decode(ContainerControlRequest.self, from: Data(contentsOf: url))
        try request.validate(now: now)
        return request
    }
}
