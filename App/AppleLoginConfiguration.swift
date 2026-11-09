import Foundation

enum AppleLoginConfiguration {
    static let defaultAnisetteURL = "https://new.ani.sidestore.io"
    static let legacyAnisetteURL = "https://ani.sidestore.io"
    static func stateForEndpoint(_ state: [String: String], endpoint: String) -> [String: String] {
        var next = state
        if next["retools_anisette_endpoint"] != endpoint { next.removeValue(forKey: "anisette_state") }
        next["retools_anisette_endpoint"] = endpoint
        return next
    }
    static func migratedAnisetteURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["https://ani.iloader.app", "https://ani.iloader.app/"].contains(trimmed) ? defaultAnisetteURL : trimmed
    }
    static func validatedAnisetteURL(_ value: String) throws -> String {
        guard var url = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw WorkspaceFailure("Anisette 服务必须是有效的 HTTPS 地址，不能包含账号、密码或查询参数。")
        }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        guard let normalized = url.url?.absoluteString else { throw WorkspaceFailure("Anisette 服务地址无效。") }
        return normalized
    }
}
