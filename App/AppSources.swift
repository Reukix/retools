import Foundation
import UIKit
import CryptoKit

/// 软件源中的一个可下载版本。
struct SourceVersion: Codable, Hashable, Sendable, Identifiable {
    var version: String
    var build: String?
    var date: String?
    var notes: String?
    var downloadURL: URL
    var size: Int64?
    var minimumOS: String?
    var sha256: String?
    var id: String { downloadURL.absoluteString }
    var dateLabel: String? {
        guard let date, !date.isEmpty else { return nil }
        if let value = ISO8601DateFormatter().date(from: date) { return value.formatted(date: .abbreviated, time: .omitted) }
        return String(date.prefix(10))
    }
}

/// 软件源中的一个应用（AltStore / SideStore 源格式）。
struct SourceApp: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var bundleID: String
    var developer: String?
    var subtitle: String?
    var summary: String?
    var iconURL: URL?
    var tintColor: String?
    var beta: Bool
    var screenshots: [URL]
    /// 最新版本在前。
    var versions: [SourceVersion]
    var id: String { bundleID + "|" + name }
    var latest: SourceVersion? { versions.first }
}

/// 版本号比较：按数字段逐段比较（5.0.10 比 5.0.9 新），非数字字符只作分隔。
enum VersionOrder {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
    private static func components(_ value: String) -> [Int] {
        value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0.prefix(9)) }
    }
}

/// 应用库中某个应用在软件源里有更新的版本。
struct SourceUpdate: Identifiable, Sendable {
    let package: AppPackage
    let app: SourceApp
    let version: SourceVersion
    let sourceName: String
    var id: UUID { package.id }
}

/// 一个正在进行的下载。
struct SourceDownload: Identifiable, Sendable {
    let id: String
    let appName: String
    let version: String
    let iconURL: URL?
    var received: Int64 = 0
    var total: Int64?
    /// 重试或校验时的说明。
    var retry: String?
    var fraction: Double? { total.flatMap { $0 > 0 ? min(1, Double(received) / Double($0)) : nil } }
    /// 与详情页「大小」用同一种换算（ByteCountFormatter 的文件口径），否则同一个包会显示成 150.6 MB 和 143.6 MB 两个数。
    var sizeLabel: String {
        let mb = { (value: Int64) in String(format: "%.1f", Double(value) / 1_000_000) }
        return total.map { "\(mb(received)) / \(mb($0)) MB" } ?? "\(mb(received)) MB"
    }
}

/// 用户添加的一个软件源，连同最近一次成功读取的内容。
struct AppSource: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var url: URL
    var name: String
    var subtitle: String?
    var iconURL: URL?
    var website: URL?
    var apps: [SourceApp] = []
    var updatedAt: Date?
    var lastError: String?
    /// 用户改过的显示名称；为空时用源自己的名称。
    var customName: String?
    var displayName: String { customName ?? name }
    /// 短链接跳转后的实际网站（如 bit.ly → quarksources.github.io）。
    var resolvedHost: String?
    var displayHost: String { resolvedHost ?? url.host ?? url.absoluteString }
}

/// 解析软件源 JSON。同时兼容旧格式（应用顶层的 version / downloadURL）与新格式（versions 数组），
/// 字段类型不一致时尽量读取；不能下载的应用会被跳过。
enum AppSourceParser {
    struct Parsed: Sendable { var name: String; var subtitle: String?; var iconURL: URL?; var website: URL?; var apps: [SourceApp]; var finalURL: URL? = nil }

    static let maximumBytes = 20 * 1024 * 1024

    static func parse(_ data: Data, sourceURL: URL) throws -> Parsed {
        guard data.count <= maximumBytes else { throw WorkspaceFailure("软件源内容超过 20 MB，已停止读取。") }
        let trimmed = data.prefix(64).drop { [0x20, 0x09, 0x0a, 0x0d, 0xef, 0xbb, 0xbf].contains($0) }
        if trimmed.first == UInt8(ascii: "<") {
            throw WorkspaceFailure("该地址返回的是网页，不是软件源。请填写 AltStore / SideStore 格式的 JSON 源地址。")
        }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw WorkspaceFailure("软件源不是有效的 JSON。") }
        guard let root = object as? [String: Any] else { throw WorkspaceFailure("软件源格式不受支持：缺少源信息。") }
        guard let rawApps = root["apps"] as? [Any] else { throw WorkspaceFailure("软件源中没有应用列表（apps）。") }
        var apps: [SourceApp] = []
        var seen = Set<String>()
        for case let item as [String: Any] in rawApps.prefix(5000) {
            guard let app = parseApp(item, base: sourceURL), seen.insert(app.id).inserted else { continue }
            apps.append(app)
        }
        let name = string(root["name"]) ?? sourceURL.host ?? "软件源"
        return Parsed(name: name, subtitle: string(root["subtitle"]) ?? string(root["description"]),
                      iconURL: url(root["iconURL"], base: sourceURL), website: url(root["website"], base: sourceURL), apps: apps)
    }

    static func parseApp(_ item: [String: Any], base: URL) -> SourceApp? {
        guard let name = string(item["name"]), let bundleID = string(item["bundleIdentifier"]) else { return nil }
        var versions: [SourceVersion] = []
        for case let raw as [String: Any] in (item["versions"] as? [Any]) ?? [] {
            if let version = parseVersion(raw, base: base, fallbackSize: nil) { versions.append(version) }
        }
        if versions.isEmpty {
            var legacy = item
            legacy["date"] = item["versionDate"]; legacy["localizedDescription"] = item["versionDescription"]
            if let version = parseVersion(legacy, base: base, fallbackSize: nil) { versions.append(version) }
        }
        guard !versions.isEmpty else { return nil }
        return SourceApp(name: name, bundleID: bundleID, developer: string(item["developerName"]), subtitle: string(item["subtitle"]),
                         summary: string(item["localizedDescription"]), iconURL: url(item["iconURL"], base: base),
                         tintColor: string(item["tintColor"]), beta: (item["beta"] as? Bool) ?? false,
                         screenshots: screenshots(item, base: base), versions: versions)
    }

    private static func parseVersion(_ raw: [String: Any], base: URL, fallbackSize: Int64?) -> SourceVersion? {
        guard let version = string(raw["version"]), let download = url(raw["downloadURL"], base: base) else { return nil }
        return SourceVersion(version: version, build: string(raw["buildVersion"]), date: string(raw["date"]),
                             notes: string(raw["localizedDescription"]), downloadURL: download,
                             size: integer(raw["size"]) ?? fallbackSize, minimumOS: string(raw["minOSVersion"]),
                             sha256: string(raw["sha256"])?.lowercased())
    }

    /// screenshotURLs 为字符串数组；新格式 screenshots 可以是字符串数组、{imageURL} 数组，或按设备分组的字典。
    private static func screenshots(_ item: [String: Any], base: URL) -> [URL] {
        func list(_ value: Any?) -> [URL] {
            ((value as? [Any]) ?? []).compactMap { entry in
                if let dict = entry as? [String: Any] { return url(dict["imageURL"], base: base) }
                return url(entry, base: base)
            }
        }
        if let grouped = item["screenshots"] as? [String: Any] {
            let phone = list(grouped["iphone"]); return phone.isEmpty ? list(grouped["ipad"]) : phone
        }
        let modern = list(item["screenshots"])
        return Array((modern.isEmpty ? list(item["screenshotURLs"]) : modern).prefix(12))
    }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String { let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines); return trimmed.isEmpty ? nil : trimmed }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
    static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value > 0 ? number.int64Value : nil }
        if let text = value as? String, let number = Int64(text), number > 0 { return number }
        return nil
    }
    /// 解析为可访问的 https 地址；http 自动升级（系统默认禁止明文请求），其他协议丢弃。
    static func url(_ value: Any?, base: URL) -> URL? {
        guard let text = string(value), let parsed = URL(string: text, relativeTo: base)?.absoluteURL else { return nil }
        return AppSourceAddress.secured(parsed)
    }
}

/// GitHub 仓库作为软件源：读取 Releases 中的 IPA 文件，每个 IPA 是一个可下载版本。
/// 不带令牌时 GitHub 按网络地址限流（每小时 60 次），刷新不要过于频繁。
enum GitHubReleaseSource {
    struct Repository: Equatable, Sendable { let owner: String; let name: String }

    /// github.com/<owner>/<repo>（可带 /releases 等后缀）；Release 附件的直链和 .json 文件按普通地址处理。
    static func repository(in url: URL) -> Repository? {
        guard ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, !url.path.lowercased().hasSuffix(".json"), !url.path.contains("/releases/download/") else { return nil }
        let reserved: Set<String> = ["orgs", "settings", "topics", "search", "marketplace", "explore", "sponsors", "login"]
        guard !reserved.contains(parts[0].lowercased()) else { return nil }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return Repository(owner: parts[0], name: name)
    }

    static func fetch(_ repository: Repository, session: URLSession) async throws -> AppSourceParser.Parsed {
        let api = URL(string: "https://api.github.com/repos/\(repository.owner)/\(repository.name)/releases?per_page=30")!
        var request = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw WorkspaceFailure("无法连接到 GitHub，请检查网络环境（中国大陆通常需要代理）。") }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 404 { throw WorkspaceFailure("找不到 GitHub 仓库 \(repository.owner)/\(repository.name)。") }
            if http.statusCode == 403 || http.statusCode == 429, http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
                throw WorkspaceFailure("GitHub 接口请求次数已达上限（每小时 60 次）" + (reset.map { "，约 " + $0.formatted(date: .omitted, time: .shortened) + " 恢复。" } ?? "，请稍后再试。"))
            }
            throw WorkspaceFailure("GitHub 请求失败（HTTP \(http.statusCode)）。")
        }
        guard let releases = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { throw WorkspaceFailure("GitHub 返回的 Releases 无法读取。") }
        var versions: [SourceVersion] = []
        var avatar: URL?
        for release in releases where (release["draft"] as? Bool) != true {
            let tag = AppSourceParser.string(release["tag_name"]) ?? AppSourceParser.string(release["name"]) ?? "release"
            let assets = ((release["assets"] as? [[String: Any]]) ?? []).filter { (AppSourceParser.string($0["name"]) ?? "").lowercased().hasSuffix(".ipa") }
            if avatar == nil, let author = release["author"] as? [String: Any] { avatar = AppSourceParser.url(author["avatar_url"], base: api) }
            for asset in assets {
                guard let download = AppSourceParser.url(asset["browser_download_url"], base: api) else { continue }
                let file = AppSourceParser.string(asset["name"]) ?? ""
                let version = tag.hasPrefix("v") && tag.dropFirst().first?.isNumber == true ? String(tag.dropFirst()) : tag
                versions.append(SourceVersion(version: assets.count > 1 ? "\(version) · \(file)" : version, build: nil,
                                              date: AppSourceParser.string(release["published_at"]), notes: AppSourceParser.string(release["body"]),
                                              downloadURL: download, size: AppSourceParser.integer(asset["size"]), minimumOS: nil,
                                              sha256: AppSourceParser.string(asset["digest"]).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }))
            }
        }
        guard !versions.isEmpty else { throw WorkspaceFailure("仓库 \(repository.owner)/\(repository.name) 的 Releases 里没有 IPA 文件。") }
        let app = SourceApp(name: repository.name, bundleID: "github.\(repository.owner).\(repository.name)".lowercased(), developer: repository.owner,
                            subtitle: "GitHub Releases", summary: nil, iconURL: avatar, tintColor: nil, beta: false, screenshots: [], versions: versions)
        return AppSourceParser.Parsed(name: "\(repository.owner)/\(repository.name)", subtitle: "GitHub Releases", iconURL: avatar,
                                      website: URL(string: "https://github.com/\(repository.owner)/\(repository.name)"), apps: [app])
    }
}

/// 用户输入的软件源地址。
enum AppSourceAddress {
    /// 接受 https / http 地址、省略协议的地址，以及 altstore:// 或 sidestore:// 的「添加源」链接。
    static func normalize(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WorkspaceFailure("请填写软件源地址。") }
        if let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(), ["altstore", "sidestore"].contains(scheme) {
            guard let inner = components.queryItems?.first(where: { $0.name == "url" })?.value else { throw WorkspaceFailure("链接中没有软件源地址。") }
            return try normalize(inner)
        }
        let candidate = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: candidate), let secured = secured(url) else { throw WorkspaceFailure("软件源地址无效：\(text)") }
        if let repository = GitHubReleaseSource.repository(in: secured) { return URL(string: "https://github.com/\(repository.owner)/\(repository.name)")! }
        // altdirect.app/?url=… 是「一键添加源」的包装页面，真正的源在 url 参数里。
        if secured.host?.lowercased() == "altdirect.app", let inner = URLComponents(url: secured, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value {
            return try normalize(inner)
        }
        return secured
    }
    static func secured(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        switch components.scheme?.lowercased() {
        case "https": break
        case "http": components.scheme = "https"
        default: return nil
        }
        return components.url
    }
    /// 一段文字里的全部地址。先找出带协议的链接（可夹在中文说明里）；一个都没有时按行或空白分隔，
    /// 以支持只写域名的地址。去掉末尾的标点和括号，按出现顺序去重。
    static func candidates(in text: String) -> [String] {
        let pattern = #"(?i)\b(?:https?|altstore|sidestore)://[^\s"'<>，。；、）】」》]+"#
        let range = NSRange(text.startIndex..., in: text)
        var found = (try? NSRegularExpression(pattern: pattern))?.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } } ?? []
        if found.isEmpty {
            found = text.components(separatedBy: .whitespacesAndNewlines).filter { $0.contains(".") }
        }
        // 连在一起粘贴的地址（如 …apphttps://…）按下一个协议头拆开。
        let splitter = try? NSRegularExpression(pattern: #"(?i)(?<=.)(?<!=)(?=(?:https?|altstore|sidestore)://)"#)
        found = found.flatMap { item -> [String] in
            guard let splitter else { return [item] }
            var parts: [String] = [], start = item.startIndex
            for match in splitter.matches(in: item, range: NSRange(item.startIndex..., in: item)) {
                guard let cut = Range(match.range, in: item)?.lowerBound else { continue }
                parts.append(String(item[start..<cut])); start = cut
            }
            parts.append(String(item[start...]))
            return parts
        }
        var result: [String] = []
        for item in found {
            let trimmed = item.trimmingCharacters(in: CharacterSet(charactersIn: ",;.!?)]}，；。！？）】」》、"))
            if !trimmed.isEmpty, !result.contains(trimmed) { result.append(trimmed) }
        }
        return result
    }
}

/// 管理软件源列表、刷新与下载。源内容缓存在支持目录，离线时仍可浏览。
@MainActor
final class AppSourceStore: ObservableObject {
    static let shared = AppSourceStore()
    @Published private(set) var sources: [AppSource] = []
    @Published private(set) var refreshing: Set<UUID> = []
    /// 正在下载的版本（键为下载地址）及进度 0...1；未知大小时为 nil。
    @Published private(set) var downloads: [String: SourceDownload] = [:]
    var activeDownloads: [SourceDownload] { downloads.values.sorted { $0.appName < $1.appName } }
    @Published var message: String?
    private let file: URL
    private let session: URLSession
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    /// 单个源最多等待 20 秒，避免失效的服务器拖住整个添加或刷新过程。
    static let sourceSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    init(paths: WorkspacePaths = WorkspacePaths(), session: URLSession = AppSourceStore.sourceSession) {
        file = paths.support.appendingPathComponent("Sources/sources.json")
        self.session = session
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode([AppSource].self, from: data) { sources = stored }
    }

    var failedIDs: Set<UUID> { Set(sources.filter { $0.lastError != nil }.map(\.id)) }

    var allApps: [(source: AppSource, app: SourceApp)] {
        sources.flatMap { source in source.apps.map { (source, $0) } }
    }

    /// 应用库中可从软件源更新的应用：同一 Bundle ID 在所有源里版本最高、且比应用库中更新的那一版。
    func updates(for packages: [AppPackage]) -> [SourceUpdate] {
        var best: [String: (app: SourceApp, version: SourceVersion, source: String)] = [:]
        for (source, app) in allApps {
            guard let latest = app.latest else { continue }
            if let current = best[app.bundleID], !VersionOrder.isNewer(latest.version, than: current.version.version) { continue }
            best[app.bundleID] = (app, latest, source.displayName)
        }
        return packages.compactMap { package in
            guard let match = best[package.bundleID], VersionOrder.isNewer(match.version.version, than: package.version) else { return nil }
            return SourceUpdate(package: package, app: match.app, version: match.version, sourceName: match.source)
        }
    }
    func update(for package: AppPackage) -> SourceUpdate? { updates(for: [package]).first }
    /// 下载新版本并替换应用库中的原项，保留签名配置。
    func update(_ update: SourceUpdate, into store: WorkspaceStore) {
        download(update.app, version: update.version, into: store, replacing: update.package.id)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(sources).write(to: file, options: .atomic)
        } catch { message = "无法保存软件源：\(error.localizedDescription)" }
    }

    static func fetch(_ url: URL, session: URLSession) async throws -> AppSourceParser.Parsed {
        if let repository = GitHubReleaseSource.repository(in: url) { return try await GitHubReleaseSource.fetch(repository, session: session) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError {
            switch error.code {
            case .timedOut: throw WorkspaceFailure("连接超时：服务器 20 秒内没有响应。")
            case .cannotFindHost, .dnsLookupFailed: throw WorkspaceFailure("找不到服务器（\(url.host ?? "")），域名可能已失效或在当前网络被屏蔽。")
            case .cannotConnectToHost, .networkConnectionLost: throw WorkspaceFailure("无法连接服务器（\(url.host ?? "")），可能在当前网络被屏蔽。")
            case .notConnectedToInternet: throw WorkspaceFailure("当前没有网络连接。")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
                throw WorkspaceFailure("与服务器的安全连接失败（\(url.host ?? "")）。")
            default: throw error
            }
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            switch http.statusCode {
            case 404, 410: throw WorkspaceFailure("HTTP \(http.statusCode)：该源地址已不存在，可能已迁移。")
            case 500...599: throw WorkspaceFailure("HTTP \(http.statusCode)：源服务器暂时无法访问，可稍后再试。")
            default: throw WorkspaceFailure("服务器返回 HTTP \(http.statusCode)。")
            }
        }
        // 只要内容是 JSON 就接受：部分源（如 UTM）以 text/html 返回 JSON。
        var parsed = try AppSourceParser.parse(data, sourceURL: response.url ?? url)
        parsed.finalURL = response.url
        return parsed
    }

    /// 同时添加多个地址，按输入顺序返回每个地址的结果。已存在的源只刷新。
    func add(_ inputs: [String], onResult: ((Int, Result<String, Error>) -> Void)? = nil) async -> [(input: String, result: Result<String, Error>)] {
        var results = [Result<String, Error>?](repeating: nil, count: inputs.count)
        await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
            for (index, input) in inputs.enumerated() {
                group.addTask { (index, await self.addOne(input)) }
            }
            for await (index, result) in group { results[index] = result; onResult?(index, result) }
        }
        return zip(inputs, results).map { ($0, $1 ?? .failure(WorkspaceFailure("未完成"))) }
    }

    func addOne(_ input: String) async -> Result<String, Error> {
        do {
            let url = try AppSourceAddress.normalize(input)
            if let existing = sources.first(where: { $0.url == url }) {
                await refresh(existing.id)
                if let error = sources.first(where: { $0.id == existing.id })?.lastError { throw WorkspaceFailure(error) }
                return .success("已存在，已刷新")
            }
            let parsed = try await Self.fetch(url, session: session)
            // 同一批里可能有两个地址指向同一个源。
            guard !sources.contains(where: { $0.url == url }) else { return .success("已存在") }
            var source = AppSource(url: url, name: parsed.name, subtitle: parsed.subtitle, iconURL: parsed.iconURL, website: parsed.website,
                                   apps: parsed.apps, updatedAt: Date())
            source.resolvedHost = parsed.finalURL?.host.flatMap { $0 == url.host ? nil : $0 }
            sources.append(source)
            save()
            return .success("\(parsed.name) · \(parsed.apps.count) 个应用")
        } catch { return .failure(error) }
    }

    func refresh(_ id: UUID) async {
        guard let source = sources.first(where: { $0.id == id }), !refreshing.contains(id) else { return }
        refreshing.insert(id); defer { refreshing.remove(id) }
        do {
            let parsed = try await Self.fetch(source.url, session: session)
            guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
            sources[index].name = parsed.name; sources[index].subtitle = parsed.subtitle
            sources[index].iconURL = parsed.iconURL; sources[index].website = parsed.website
            sources[index].apps = parsed.apps; sources[index].updatedAt = Date(); sources[index].lastError = nil
            sources[index].resolvedHost = parsed.finalURL?.host.flatMap { $0 == source.url.host ? nil : $0 }
        } catch {
            // 保留上次成功读取的应用，只记录失败原因。
            guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
            sources[index].lastError = error.localizedDescription
        }
        save()
    }

    /// 回到前台时检查更新：距上次成功读取超过 6 小时的源才重新读取，避免频繁联网。
    func refreshIfStale(maxAge: TimeInterval = 6 * 3600) async {
        let stale = sources.filter { ($0.updatedAt ?? .distantPast).addingTimeInterval(maxAge) < Date() }.map(\.id)
        guard !stale.isEmpty else { return }
        await refresh(Set(stale))
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for source in sources { group.addTask { await self.refresh(source.id) } }
        }
    }

    func remove(_ ids: Set<UUID>) {
        sources.removeAll { ids.contains($0.id) }
        save()
    }

    func refresh(_ ids: Set<UUID>) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.refresh(id) } }
        }
    }

    /// 修改显示名称或源地址。地址变了会先读取新地址，成功后才替换内容。
    func update(_ id: UUID, name: String, address: String) async throws {
        guard let current = sources.first(where: { $0.id == id }) else { throw WorkspaceFailure("找不到这个软件源。") }
        let url = try AppSourceAddress.normalize(address)
        if url != current.url, sources.contains(where: { $0.url == url && $0.id != id }) { throw WorkspaceFailure("已经添加过这个地址。") }
        let parsed = url == current.url ? nil : try await Self.fetch(url, session: session)
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed {
            sources[index].url = url; sources[index].name = parsed.name; sources[index].subtitle = parsed.subtitle
            sources[index].iconURL = parsed.iconURL; sources[index].website = parsed.website; sources[index].apps = parsed.apps
            sources[index].updatedAt = Date(); sources[index].lastError = nil
        }
        sources[index].customName = trimmed.isEmpty || trimmed == sources[index].name ? nil : trimmed
        save()
    }

    /// 把一个源移到新位置（列表拖动排序）。
    func move(from offsets: IndexSet, to destination: Int) {
        sources.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    func isDownloading(_ version: SourceVersion) -> Bool { downloads[version.id] != nil }
    func progress(_ version: SourceVersion) -> Double? { downloads[version.id]?.fraction }

    /// 下载 IPA，校验后交给应用库导入（导入时还会完整解析 IPA 内容）。
    /// 网络中断、超时或服务器 5xx 时自动重试，最多 3 次。
    func download(_ app: SourceApp, version: SourceVersion, into store: WorkspaceStore, replacing packageID: UUID? = nil) {
        guard downloads[version.id] == nil else { return }
        let key = version.id
        downloads[key] = SourceDownload(id: key, appName: app.name, version: version.version, iconURL: app.iconURL, total: version.size)
        downloadTasks[key] = Task {
            let lease = BackgroundLease("Retools 下载 IPA")
            defer { downloads[key] = nil; downloadTasks[key] = nil; lease.end() }
            let folder = store.paths.staging.appendingPathComponent("Downloads/" + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(Self.fileName(app, version: version))
                var attempt = 1
                while true {
                    do {
                        try await IPADownloader().download(version.downloadURL, to: target, expectedSize: version.size) { [weak self] received, total in
                            Task { @MainActor in
                                guard self?.downloads[key] != nil else { return }
                                self?.downloads[key]?.received = received
                                if let total { self?.downloads[key]?.total = total }
                            }
                        }
                        break
                    } catch where attempt < 3 && Self.isTransient(error) && !Task.isCancelled {
                        downloads[key]?.retry = "第 \(attempt) 次失败，\(attempt * 2) 秒后重试"
                        try await Task.sleep(for: .seconds(attempt * 2))
                        try? FileManager.default.removeItem(at: target)
                        attempt += 1; downloads[key]?.retry = "重试 \(attempt)/3"; downloads[key]?.received = 0
                    }
                }
                try Task.checkCancellation()
                downloads[key]?.retry = "正在校验"
                try Self.verify(target, sha256: version.sha256)
                downloads[key]?.retry = store.isWorking ? "等待导入" : (packageID == nil ? "正在导入" : "正在替换")
                if let packageID { await store.replaceDownloadedIPA(target, packageID: packageID) }
                else { await store.importDownloadedIPA(target) }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    let reason = error.localizedDescription
                    message = "\(app.name) " + (packageID == nil ? "下载" : "更新") + "失败：" + reason
                        + (Self.isTransient(error) ? "\n已自动重试 3 次。服务器暂时不可用，可以稍后再试。" : "")
                }
            }
        }
    }

    nonisolated static func isTransient(_ error: Error) -> Bool {
        if let failure = error as? WorkspaceFailure { return failure.message.contains("HTTP 5") }
        guard let code = (error as? URLError)?.code else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost].contains(code)
    }

    func cancelDownload(_ version: SourceVersion) { downloadTasks[version.id]?.cancel() }
    func cancelDownload(id: String) { downloadTasks[id]?.cancel() }

    static func fileName(_ app: SourceApp, version: SourceVersion) -> String {
        let raw = "\(app.name)_\(version.version).ipa"
        let safe = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)).joined(separator: "-")
        return String(safe.prefix(180))
    }

    /// 文件必须是 ZIP；源提供 SHA-256 时必须一致。
    nonisolated static func verify(_ file: URL, sha256: String?) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
            throw WorkspaceFailure("下载的文件不是 IPA（可能是网页或已失效的链接）。")
        }
        guard let expected = sha256, expected.count == 64 else { return }
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw WorkspaceFailure("下载文件的 SHA-256 与软件源不一致，已丢弃。") }
    }
}

/// 带进度的下载，结果移动到指定位置。
final class IPADownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private var continuation: CheckedContinuation<Void, Error>?
    private var target: URL?
    private var expectedSize: Int64?
    private var progress: (@Sendable (Int64, Int64?) -> Void)?
    private let lock = NSLock()

    /// IPA 可能很大：单次读写最多等 60 秒，整个下载最长 1 小时。
    init(configuration: URLSessionConfiguration = {
        let value = URLSessionConfiguration.default
        value.timeoutIntervalForRequest = 60
        value.timeoutIntervalForResource = 3600
        return value
    }()) { self.configuration = configuration }

    func download(_ url: URL, to target: URL, expectedSize: Int64?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        guard let secured = AppSourceAddress.secured(url) else { throw WorkspaceFailure("下载地址无效。") }
        self.target = target; self.expectedSize = expectedSize; self.progress = progress
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: URLRequest(url: secured, timeoutInterval: 60))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in let value = self.continuation; self.continuation = nil; return value }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (expectedSize ?? 0)
        progress?(totalBytesWritten, total > 0 ? total : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(WorkspaceFailure("下载服务器返回 HTTP \(http.statusCode)。"))); return
        }
        do {
            guard let target else { throw WorkspaceFailure("下载目标无效。") }
            try FileManager.default.moveItem(at: location, to: target)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

/// 切到后台时向系统多申请一段运行时间（通常约 30 秒）。到期时系统回调会立即结束申请，
/// 否则系统会终止应用；正在进行的请求随后可能被挂起。
@MainActor
final class BackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init(_ name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
