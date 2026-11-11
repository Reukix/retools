import SwiftUI

enum DecryptionCache {
    private struct Plan {
        var items: [URL] = []
        var results: [URL] = []
    }

    private static func children(_ directory: URL) throws -> [URL] {
        let fm = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fm.attributesOfItem(atPath: directory.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return [] }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw WorkspaceFailure("缓存目录不是普通文件夹，未清理其内容。") }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    }

    private static func plan(paths: WorkspacePaths) throws -> Plan {
        var plan = Plan()
        for item in try children(paths.support.appendingPathComponent("Decryption")) {
            if item.lastPathComponent == "Current" { plan.items.append(item); continue }
            guard UUID(uuidString: item.lastPathComponent) != nil else { continue }
            plan.items.append(item)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true, values.isSymbolicLink != true {
                let result = item.appendingPathComponent("Result.ipa")
                if FileManager.default.fileExists(atPath: result.path) {
                    let values = try result.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WorkspaceFailure("砸壳结果不是普通文件，已停止清理。") }
                    plan.results.append(result)
                }
            }
        }
        for item in try children(paths.support.appendingPathComponent("StoreDownloads")) {
            if item.lastPathComponent.range(of: "^download-[0-9]+\\.ipa(?:\\..*)?$", options: .regularExpression) != nil { plan.items.append(item) }
        }
        for item in try children(paths.staging) where item.lastPathComponent.hasPrefix("InstalledSource-") { plan.items.append(item) }
        return plan
    }

    private static func bytes(at url: URL, preserving: Set<String>) throws -> Int64 {
        if preserving.contains(url.path) { return 0 }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isDirectory == true, values.isSymbolicLink != true {
            return try children(url).reduce(Int64(0)) { try $0 + bytes(at: $1, preserving: preserving) }
        }
        return Int64(values.fileSize ?? 0)
    }

    static func size(paths: WorkspacePaths) throws -> Int64 {
        let plan = try plan(paths: paths), results = Set(plan.results.map(\.path))
        return try plan.items.reduce(Int64(0)) { try $0 + bytes(at: $1, preserving: results) }
    }

    static func savedResults(paths: WorkspacePaths) throws -> [URL] {
        try children(paths.exports.appendingPathComponent("Decrypted")).compactMap { file -> (URL, Date)? in
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard file.pathExtension == "ipa", values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (file, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 > $1.1 }.map { $0.0 }
    }

    @discardableResult
    static func clear(paths: WorkspacePaths) throws -> Int64 {
        let plan = try plan(paths: paths), fm = FileManager.default
        let results = Set(plan.results.map(\.path))
        let size = try plan.items.reduce(Int64(0)) { try $0 + bytes(at: $1, preserving: results) }
        // Preserve every completed result before removing any task, including older jobs.
        if !plan.results.isEmpty {
            let exports = paths.exports.appendingPathComponent("Decrypted")
            try fm.createDirectory(at: paths.exports, withIntermediateDirectories: true)
            _ = try children(paths.exports)
            try fm.createDirectory(at: exports, withIntermediateDirectories: true)
            _ = try children(exports)
            for result in plan.results {
                let id = result.deletingLastPathComponent().lastPathComponent
                var destination = exports.appendingPathComponent(id + "-decrypted.ipa")
                if fm.fileExists(atPath: destination.path) { destination = exports.appendingPathComponent(id + "-" + UUID().uuidString + "-decrypted.ipa") }
                try fm.moveItem(at: result, to: destination)
            }
        }
        for item in plan.items { try fm.removeItem(at: item) }
        return size
    }
}

struct DecryptionCacheView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var renewal: RenewalController
    @State private var bytes: Int64?
    @State private var results: [URL] = []
    @State private var scanning = false
    @State private var clearing = false
    @State private var confirmClear = false
    @State private var message: String?
    @State private var error: String?
    private var blocked: Bool { scanning || clearing || store.isWorking || renewal.isWorking || store.loadFailed }

    var body: some View {
        List {
            Section {
                LabeledContent("可清理缓存", value: bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "正在计算…")
                    .accessibilityIdentifier("decryption.cache.size")
                Text("包含助手工作副本、历史任务和商店下载的 IPA。已校验的商店组件会保留，方便下次使用。")
                    .font(.footnote).foregroundStyle(Color.secondary)
                Button(role: .destructive) { confirmClear = true } label: {
                    Label(clearing ? "正在清理…" : "清除砸壳缓存", systemImage: "trash")
                }.disabled(blocked || bytes == nil || bytes == 0).accessibilityIdentifier("decryption.cache.clear")
                if let message { Text(message).font(.footnote).foregroundStyle(Color.secondary).accessibilityIdentifier("decryption.cache.message") }
                if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            } footer: {
                Text("已取回的解密 IPA 会先保存到「文件 → 我的 iPhone → Retools → Retools → Exports → Decrypted」。清理后需重新准备助手；已安装的助手需另行卸载。")
            }
            if !results.isEmpty {
                Section("已保存的砸壳结果") {
                    ForEach(results, id: \.path) { file in
                        ShareLink(item: file) { Label(file.lastPathComponent, systemImage: "square.and.arrow.up").lineLimit(2) }
                            .disabled(clearing)
                    }
                }
            }
        }
        .toolListStyle()
        .navigationTitle("缓存清理").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(clearing)
        .task { await refresh() }
        .confirmationDialog("清除砸壳缓存？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除缓存", role: .destructive) { Task { await clear() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会结束 Retools 中当前准备的砸壳任务，清除助手副本和下载包。已取回的结果、应用库、账号和证书会保留。")
        }
    }

    @MainActor private func refresh() async {
        scanning = true; defer { scanning = false }
        let paths = store.paths
        do {
            let value = try await Task.detached(priority: .utility) { (try DecryptionCache.size(paths: paths), try DecryptionCache.savedResults(paths: paths)) }.value
            bytes = value.0; results = value.1
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func clear() async {
        guard !blocked, !DevicePairingCoordinator.shared.isRunning else { error = "请等待当前操作完成后再清理。"; return }
        clearing = true; store.isWorking = true; store.workLabel = "正在清理砸壳缓存…"; error = nil; message = nil
        defer { clearing = false; store.isWorking = false; store.workLabel = ""; store.refreshStorage() }
        let paths = store.paths
        do {
            let removed = try await Task.detached(priority: .utility) { try DecryptionCache.clear(paths: paths) }.value
            message = "已清理 " + ByteCountFormatter.string(fromByteCount: removed, countStyle: .file) + " 缓存"
        } catch { self.error = "部分缓存未能清理：" + error.localizedDescription }
        await refresh()
    }
}
