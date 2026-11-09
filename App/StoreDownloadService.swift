import Foundation
import StoreDownloadEngine

struct StoreAccountInfo: Codable, Sendable {
    let email: String
    let name: String
    let storeFront: String
}
enum StoreLoginResult: Sendable { case signedIn(StoreAccountInfo), verificationRequired }

actor StoreDownloadService {
    private let stateKey = "retools.store.session.v1"
    private let accountKey = "retools.store.account.v1"
    private let guidKey = "retools.store.guid.v1"
    let root: URL
    init(paths: WorkspacePaths = WorkspacePaths()) { root = paths.support.appendingPathComponent("StoreDownloads") }
    func account() throws -> StoreAccountInfo? {
        try SecureStore.data(key: accountKey).map { try JSONDecoder().decode(StoreAccountInfo.self, from: $0) }
    }
    func signOut() throws {
        try SecureStore.deleteData(key: stateKey); try SecureStore.deleteData(key: accountKey)
    }
    nonisolated static func progress() -> String {
        guard let value = rt_store_progress() else { return "正在处理商店请求…" }
        defer { rt_store_free(value) }; return String(cString: value)
    }
    nonisolated static func cancel() { rt_store_cancel() }
    private func request(_ operation: String, values: [String: Any] = [:]) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let guid: String
        if let data = try SecureStore.data(key: guidKey), let stored = String(data: data, encoding: .utf8), stored.count == 12 { guid = stored }
        else {
            guid = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
            try SecureStore.saveData(Data(guid.utf8), key: guidKey)
        }
        let stateData = try SecureStore.data(key: stateKey) ?? Data("{\"keys\":{},\"cookies\":[]}".utf8)
        var request = values
        request["operation"] = operation; request["root"] = root.path; request["guid"] = guid
        request["state"] = try JSONSerialization.jsonObject(with: stateData)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let data = try await Task.detached(priority: .userInitiated) {
            try text.withCString { input -> Data in
                guard let output = rt_store_request(input) else { throw FairPlayFailure("商店引擎没有返回结果。") }
                defer { rt_store_free(output) }
                return Data(String(cString: output).utf8)
            }
        }.value
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FairPlayFailure("商店响应格式无效。") }
        if let state = response["state"] as? [String: Any], state["keys"] is [String: Any] {
            try SecureStore.saveData(JSONSerialization.data(withJSONObject: state), key: stateKey)
        }
        if let account = response["account"] as? [String: Any] {
            try SecureStore.saveData(JSONSerialization.data(withJSONObject: account), key: accountKey)
        }
        return response
    }
    private func requireSuccess(_ response: [String: Any]) throws {
        guard response["ok"] as? Bool == true else {
            let message = response["error"] as? String ?? "商店操作未完成。"
            if message.contains("context canceled") { throw FairPlayFailure("操作已取消，已校验的组件会保留。") }
            if message.contains("deadline exceeded") || message.contains("Client.Timeout") { throw FairPlayFailure("商店请求超时。已校验的组件会保留，请检查网络后重试。") }
            throw FairPlayFailure(message)
        }
    }
    func prepare() async throws { try requireSuccess(await request("prepare")) }
    func probe() async throws { try requireSuccess(await request("probe")) }
    func probeCancellation() async throws { try requireSuccess(await request("probeCancellation")) }
    func verifySetup() async throws { try requireSuccess(await request("setupCheck")) }
    func verifyDeviceAuth() async throws { try requireSuccess(await request("deviceAuthCheck")) }
    func verifyDownloadRuntime() async throws { try requireSuccess(await request("downloadRuntimeCheck")) }
    func login(email: String, password: String, code: String = "") async throws -> StoreLoginResult {
        let response = try await request("login", values: ["email": email, "password": password, "code": code])
        if response["requiresCode"] as? Bool == true { return .verificationRequired }
        try requireSuccess(response)
        guard let account = try account() else { throw FairPlayFailure("商店登录未返回账号信息。") }
        return .signedIn(account)
    }
    func download(_ app: StoreCatalogApp, version: String? = nil) async throws -> URL {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(app))
        let response = try await request("download", values: ["app": object, "version": version ?? "", "acquireFreeLicense": app.price == 0])
        try requireSuccess(response)
        guard let path = response["path"] as? String else { throw FairPlayFailure("商店没有返回下载文件。") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == root.appendingPathComponent("download-\(app.id).ipa").path, FileManager.default.fileExists(atPath: url.path) else { throw FairPlayFailure("商店返回的下载路径不匹配。") }
        return url
    }
    func versions(_ app: StoreCatalogApp) async throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(app))
        let response = try await request("versions", values: ["app": object])
        try requireSuccess(response)
        return response["versions"] as? [String] ?? []
    }
}
