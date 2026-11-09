import Foundation
import IdeviceGateway

/// 一份应用数据备份：Retools 支持目录下 `AppBackups/<id>/`，里面是 `manifest.json` 和与沙盒结构一致的 `Container/`。
struct AppDataBackup: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var bundleID: String
    var appName: String
    var version: String
    /// "container"：整个沙盒；"documents"：只有文稿。
    var access: String
    var createdAt: Date
    var files: Int
    var bytes: Int64

    var accessTitle: String { access == DeviceContainerAccess.documents.rawValue ? "仅文稿" : "完整沙盒" }
}

enum AppDataBackupStore {
    static var root: URL { WorkspacePaths().support.appendingPathComponent("AppBackups", isDirectory: true) }

    /// 备份不包含可以重新生成的内容，也不碰系统维护的元数据。
    static let excluded: Set<String> = ["/tmp", "/Library/Caches", "/SystemData", "/.com.apple.mobile_container_manager.metadata.plist"]
    /// 恢复时先清空这些目录的内容，再写回备份；excluded 里的路径保留不动。
    static let cleared = ["/Documents", "/Library"]

    static func folder(_ id: UUID, root: URL = root) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func container(_ id: UUID, root: URL = root) -> URL { folder(id, root: root).appendingPathComponent("Container", isDirectory: true) }

    static func list(root: URL = root) -> [AppDataBackup] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> AppDataBackup? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let backup = try? JSONDecoder().decode(AppDataBackup.self, from: data) else {
                // 没有清单的是中断的备份，直接清掉。
                try? FileManager.default.removeItem(at: folder); return nil
            }
            return backup
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// 清单最后写入：有清单才算一份完整的备份。
    static func commit(_ backup: AppDataBackup, root: URL = root) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(backup).write(to: folder(backup.id, root: root).appendingPathComponent("manifest.json"), options: .atomic)
    }

    static func delete(_ id: UUID, root: URL = root) { try? FileManager.default.removeItem(at: folder(id, root: root)) }

    /// 打包成 zip 供分享，放在临时目录。
    static func export(_ backup: AppDataBackup, root: URL = root) throws -> URL {
        let source = folder(backup.id, root: root)
        var exported: URL?
        var failure: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .forUploading, error: &coordinationError) { zip in
            do {
                let target = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceFiles/\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let stamp = backup.createdAt.formatted(.iso8601.year().month().day().dateSeparator(.dash))
                let file = target.appendingPathComponent("\(backup.appName)-数据备份-\(stamp).zip")
                try FileManager.default.copyItem(at: zip, to: file)
                exported = file
            } catch { failure = error }
        }
        if let error = coordinationError ?? failure { throw error }
        guard let exported else { throw WorkspaceFailure("无法生成备份压缩包。") }
        return exported
    }

    /// 本机剩余空间（与「设置」一致，含可清理空间）。
    static func availableSpace() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// 正在进行的备份或恢复。
struct DeviceTransfer: Equatable {
    var title: String
    var files = 0
    var bytes: Int64 = 0
    var expected: Int64?
    var fraction: Double? { expected.flatMap { $0 > 0 ? min(1, Double(bytes) / Double($0)) : nil } }
}

/// 后台线程报告的进度先存在这里，主线程定时读取。
final class DeviceTransferMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (files: Int, bytes: Int64) = (0, 0)
    func update(_ files: Int, _ bytes: Int64) { lock.lock(); value = (files, bytes); lock.unlock() }
    var current: (files: Int, bytes: Int64) { lock.lock(); defer { lock.unlock() }; return value }
}

import SwiftUI

/// 设备上应用的图标；还没读到时显示圆角占位。
struct DeviceAppIcon: View {
    let bundleID: String
    var size: CGFloat = 36
    @ObservedObject private var tools = DeviceToolsStore.shared
    var body: some View {
        Group {
            if let image = tools.icons[bundleID] {
                Image(uiImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).fill(.quaternary)
                    .overlay { Image(systemName: "app").font(.system(size: size * 0.45)).foregroundStyle(.tertiary) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// 备份或恢复进行中时显示的进度与取消按钮。
struct DeviceTransferSection: View {
    @ObservedObject private var tools = DeviceToolsStore.shared
    var body: some View {
        if let transfer = tools.transfer {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(transfer.title).font(.subheadline.weight(.semibold))
                    if let fraction = transfer.fraction { ProgressView(value: fraction) } else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                    HStack {
                        Text("\(transfer.files) 个文件 · \(transfer.bytes.byteLabel)" + (transfer.expected.map { " / 约 \($0.byteLabel)" } ?? ""))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Button("取消", role: .cancel) { tools.cancelTransfer() }.font(.caption.weight(.semibold))
                    }
                }.padding(.vertical, 4)
            } footer: { Text("传输期间请保持 Retools 在前台。") }
        }
    }
}

/// 一行备份记录，带恢复、导出、删除。
struct AppDataBackupRow: View {
    let backup: AppDataBackup
    var showsApp = false
    let onRestore: () -> Void
    @ObservedObject private var tools = DeviceToolsStore.shared
    @State private var share: SigningProjectShare?
    @State private var confirmDelete = false
    var body: some View {
        HStack(spacing: 12) {
            if showsApp { DeviceAppIcon(bundleID: backup.bundleID, size: 32) }
            VStack(alignment: .leading, spacing: 3) {
                Text(showsApp ? backup.appName : backup.createdAt.formatted(date: .abbreviated, time: .shortened)).lineLimit(1)
                Text([showsApp ? backup.createdAt.formatted(date: .abbreviated, time: .shortened) : nil, backup.version.isEmpty ? nil : "v" + backup.version,
                      backup.bytes.byteLabel, backup.accessTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Menu {
                Button(action: onRestore) { Label("恢复…", systemImage: "arrow.counterclockwise") }
                Button {
                    do { share = SigningProjectShare(urls: [try AppDataBackupStore.export(backup)]) }
                    catch { tools.errorMessage = "导出失败：\(error.localizedDescription)" }
                } label: { Label("导出为 zip", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("删除备份", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .disabled(tools.transfer != nil)
        }
        .sheet(item: $share) { SigningProjectShareSheet(urls: $0.urls) }
        .confirmationDialog("删除这份备份？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { tools.deleteBackup(backup) }
        } message: { Text("会释放 \(backup.bytes.byteLabel)，删除后无法恢复。") }
    }
}

/// 选择恢复目标：同一个 Bundle ID 的应用排在前面（重签换了 Bundle ID 时可以选其他应用）。
struct AppDataRestoreSheet: View {
    let backup: AppDataBackup
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var tools = DeviceToolsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var target: DeviceInstalledApp?

    private var candidates: [DeviceInstalledApp] {
        tools.apps.filter(\.filesAccessible).sorted { ($0.bundleID == backup.bundleID ? 0 : 1, $0.name) < ($1.bundleID == backup.bundleID ? 0 : 1, $1.name) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates) { app in
                        Button { target = app } label: {
                            HStack(spacing: 12) {
                                DeviceAppIcon(bundleID: app.bundleID, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).foregroundStyle(.primary)
                                    Text(app.bundleID == backup.bundleID ? "原应用" : app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(app.debuggable ? "完整沙盒" : "仅文稿").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if candidates.isEmpty { Text("没有可以写入数据的应用。").foregroundStyle(.secondary) }
                } header: { Text("恢复到") } footer: {
                    Text("会先清空目标应用的「文稿」和「Library」（缓存除外），再写入这份备份。只能访问文稿的应用只恢复文稿。恢复前请先退出目标应用。")
                }
            }
            .navigationTitle("恢复 \(backup.appName) 的数据").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await tools.loadIcons(for: candidates, renewal: renewal) }
            .confirmationDialog(target.map { "用这份备份覆盖「\($0.name)」的数据？" } ?? "", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                                titleVisibility: .visible, presenting: target) { app in
                Button("覆盖并恢复", role: .destructive) {
                    dismiss()
                    Task { await tools.restore(backup, to: app, renewal: renewal) }
                }
            } message: { app in Text("「\(app.name)」现有的数据会被替换，无法撤销。需要的话可以先给它做一份备份。") }
        }
    }
}

/// 所有应用数据备份，按时间倒序。
struct AppDataBackupsView: View {
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var tools = DeviceToolsStore.shared
    @State private var restoring: AppDataBackup?

    var body: some View {
        List {
            DeviceTransferSection()
            if tools.backups.isEmpty {
                ContentUnavailableView("还没有数据备份", systemImage: "externaldrive.badge.timemachine",
                                       description: Text("在「应用」里打开一个侧载应用，点「备份应用数据」。"))
            } else {
                Section {
                    ForEach(tools.backups) { backup in AppDataBackupRow(backup: backup, showsApp: true) { restoring = backup } }
                } footer: {
                    Text("共 \(tools.backups.count) 份，占用 \(tools.backups.reduce(Int64(0)) { $0 + $1.bytes }.byteLabel)。备份保存在 Retools 里，卸载 Retools 会一起删除，重要的请导出。")
                }
            }
        }
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle("数据备份").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
        .task { tools.reloadBackups(); await tools.loadIcons(for: tools.apps.filter { app in tools.backups.contains { $0.bundleID == app.bundleID } }, renewal: renewal) }
        .sheet(item: $restoring) { AppDataRestoreSheet(backup: $0) }
    }
}
