import AppIntents
import Foundation
import UniformTypeIdentifiers

struct RetoolsShortcutError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SigningAccountEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Apple ID"
    static var defaultQuery = SigningAccountQuery()
    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}
struct SigningAccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SigningAccountEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [SigningAccountEntity] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Retools/renewal.json")
        guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (value["accounts"] as? [[String: Any]] ?? []).compactMap { account in
            guard let email = account["email"] as? String, !(account["teamID"] as? String ?? "").isEmpty else { return nil }
            return SigningAccountEntity(id: email)
        }
    }
}

@MainActor
private func runRetoolsAction(_ request: [String: String]) async throws -> String {
    let data = try JSONSerialization.data(withJSONObject: request)
    let text = String(decoding: data, as: UTF8.self)
    for _ in 0..<50 {
        if RTAutomationIsAvailable() { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    return try await withCheckedThrowingContinuation { continuation in
        let started = RTPerformAutomation(text) { success, message in
            if success { continuation.resume(returning: message) }
            else { continuation.resume(throwing: RetoolsShortcutError(message: message)) }
        }
        if !started { continuation.resume(throwing: RetoolsShortcutError(message: "Retools 当前不可用：可能正在运行容器应用，或尚未完成首次设置。请回到 Retools 工作台后重试。")) }
    }
}

struct RefreshAllAppsIntent: AppIntent {
    static var title: LocalizedStringResource = "续签全部应用"
    static var description = IntentDescription("在后台续签 Retools 队列中的全部应用，按各应用绑定的 Apple ID 和团队获取签名资料并安装，不会打开 Retools。适合在个人自动化中定时运行。")
    // 后台运行：适合「每天 0:00」之类的个人自动化。锁屏时也能运行——
    // 凭据在钥匙串中为「首次解锁后可用」，文件保护级别相同，设备重启后需先解锁一次。
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await runRetoolsAction(["action": "refresh-all"]))
    }
}

struct InstallIPAIntent: AppIntent {
    static var title: LocalizedStringResource = "安装 IPA"
    static var description = IntentDescription("导入指定 IPA，使用选择的 Apple ID 签名，再通过已配置的外部回环安装。")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "IPA 文件") var ipa: IntentFile
    @Parameter(title: "签名账号") var account: SigningAccountEntity?
    static var parameterSummary: some ParameterSummary { Summary("安装 \(\.$ipa)") { \.$account } }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Retools/ShortcutImports").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("source.ipa")
        let input = ipa
        try await Task.detached {
            func snapshot(_ source: URL) throws {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                var result: Result<Void, Error>?, error: NSError?
                NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &error) { coordinated in
                    result = Result { try FileManager.default.copyItem(at: coordinated, to: destination) }
                }
                if let result { try result.get() }
                else { throw error ?? RetoolsShortcutError(message: "无法读取快捷指令提供的文件。") as NSError }
            }
            if #available(iOS 18.0, *) {
                try await input.withFile(contentType: input.availableContentTypes.first ?? .data) { url, _ in try snapshot(url) }
            } else if let url = input.fileURL { try snapshot(url) }
            else { try input.data.write(to: destination, options: .atomic) }
        }.value
        let result = try await runRetoolsAction(["action": "install-ipa", "file": destination.path, "account": account?.id ?? ""])
        return .result(value: result)
    }
}

struct RetoolsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RefreshAllAppsIntent(), phrases: ["Refresh all apps with \(.applicationName)"], shortTitle: "续签全部应用", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: InstallIPAIntent(), phrases: ["Install IPA with \(.applicationName)"], shortTitle: "安装 IPA", systemImageName: "square.and.arrow.down")
    }
    static var shortcutTileColor: ShortcutTileColor = .orange
}
