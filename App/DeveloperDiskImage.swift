import Foundation
import CryptoKit

/// iOS 17 及以上使用的个性化开发者镜像。文件来自 doronz88/DeveloperDiskImage（与 StikDebug 等工具相同），
/// 约 16.5 MB，下载一次后保存在 Retools 里；每次挂载时由设备向 Apple 申请针对本机的签名。
enum DeveloperDiskImage {
    static let source = URL(string: "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/")!
    static let manifestName = "BuildManifest.plist", imageName = "Image.dmg", trustCacheName = "Image.dmg.trustcache"
    static let files = [manifestName, imageName, trustCacheName]
    static let approximateSize: Int64 = 16_500_000

    static let autoMountKey = "RetoolsAutoMountDeveloperImage"
    /// 需要时（定位模拟、进程管理、容器 JIT、启动 Retools）自动挂载，默认开启。
    static var autoMountEnabled: Bool { UserDefaults.standard.object(forKey: autoMountKey) as? Bool ?? true }

    static var folder: URL { WorkspacePaths().support.appendingPathComponent("DeveloperDiskImage", isDirectory: true) }

    struct Files: Sendable { var image: Data; var trustCache: Data; var manifest: Data }

    static func isDownloaded(in folder: URL = folder) -> Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// 读取并校验已下载的文件；镜像和信任缓存必须与清单里的 SHA-384 摘要一致。
    static func load(from folder: URL = folder) throws -> Files {
        let files = Files(image: try Data(contentsOf: folder.appendingPathComponent(imageName)),
                          trustCache: try Data(contentsOf: folder.appendingPathComponent(trustCacheName)),
                          manifest: try Data(contentsOf: folder.appendingPathComponent(manifestName)))
        try verify(files)
        return files
    }

    static func verify(_ files: Files) throws {
        guard files.image.count > 1_000_000, !files.trustCache.isEmpty else { throw WorkspaceFailure("开发者镜像文件不完整，请重新下载。") }
        let digests = manifestDigests(files.manifest)
        if let expected = digests["PersonalizedDMG"], !expected.contains(Data(SHA384.hash(data: files.image))) {
            throw WorkspaceFailure("开发者镜像与清单不一致，可能下载损坏，请重新下载。")
        }
        if let expected = digests["LoadableTrustCache"], !expected.contains(Data(SHA384.hash(data: files.trustCache))) {
            throw WorkspaceFailure("信任缓存与清单不一致，可能下载损坏，请重新下载。")
        }
    }

    /// 清单里各构建身份列出的镜像与信任缓存摘要。
    static func manifestDigests(_ manifest: Data) -> [String: Set<Data>] {
        guard let plist = try? PropertyListSerialization.propertyList(from: manifest, format: nil) as? [String: Any],
              let identities = plist["BuildIdentities"] as? [[String: Any]] else { return [:] }
        var result: [String: Set<Data>] = [:]
        for identity in identities {
            let entries = identity["Manifest"] as? [String: Any] ?? [:]
            for key in ["PersonalizedDMG", "LoadableTrustCache"] {
                if let digest = (entries[key] as? [String: Any])?["Digest"] as? Data { result[key, default: []].insert(digest) }
            }
        }
        return result
    }

    /// 依次下载三个文件到临时目录，校验通过后整体替换，避免留下半套文件。
    static func download(to folder: URL = folder, session: URLSession = .shared, progress: @escaping @Sendable (String) -> Void) async throws {
        let staging = folder.deletingLastPathComponent().appendingPathComponent("DeveloperDiskImage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (index, name) in files.enumerated() {
            progress("正在下载开发者镜像（\(index + 1)/\(files.count)）…")
            var lastError: Error?
            for attempt in 0..<3 {
                do {
                    let (temp, response) = try await session.download(from: source.appendingPathComponent(name))
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw WorkspaceFailure("下载 \(name) 失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
                    }
                    try FileManager.default.moveItem(at: temp, to: staging.appendingPathComponent(name))
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < 2 { try await Task.sleep(for: .seconds(2)) }
                }
            }
            if let lastError { throw lastError }
        }
        progress("正在校验开发者镜像…")
        _ = try load(from: staging)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: staging, to: folder)
    }

    static func remove(from folder: URL = folder) { try? FileManager.default.removeItem(at: folder) }
}
