import Foundation

/// 本机开发工具使用的可重复自检，只操作自己创建的 UUID 目录。
@MainActor
enum LocalFileWriteDiagnostics {
    static func run(paths: WorkspacePaths) async {
        let reportURL = paths.support.appendingPathComponent("LocalFileWriteCheck.json")
        let name = "Retools-FileCheck-" + UUID().uuidString
        let documents = NSHomeDirectory() + "/Documents"
        let folder = documents + "/" + name
        let file = folder + "/sample.txt"
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = LocalFileAccessService.shared
        var report: [String: Any] = ["phase": "running", "startedAt": Date().timeIntervalSince1970]
        func save() { if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) { try? data.write(to: reportURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) } }
        save()
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            if let reason = LocalFileAccessService.unavailableReason { throw WorkspaceFailure(reason) }
            guard let group = HostAppGroup.signedIdentifier() else { throw WorkspaceFailure("当前签名没有文件访问 App Group。") }
            try await service.makeDirectory(directory: documents, name: name, group: group)
            try await service.createTextFile(directory: folder, name: "sample.txt", group: group)
            let before = try await service.snapshot(path: file, group: group)
            let first = Data("Retools local file read/write check".utf8)
            try await service.save(path: file, data: first, expected: before.version, group: group)
            let after = try await service.snapshot(path: file, group: group)
            guard after.data == first, after.version.sameIdentity(as: before.version) else { throw WorkspaceFailure("原地写入或文件身份校验失败。") }
            report["writeReadPassed"] = true
            report["identityPreserved"] = true
            let second = Data("updated local contents".utf8)
            try await service.save(path: file, data: second, expected: after.version, group: group)
            let updated = try await service.snapshot(path: file, group: group)
            guard updated.data == second else { throw WorkspaceFailure("覆盖内容校验失败。") }
            let exported = try await service.export(path: file, group: group)
            defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
            guard try Data(contentsOf: exported) == second else { throw WorkspaceFailure("导出校验失败。") }
            report["exportPassed"] = true
            try Data("imported binary fixture".utf8).write(to: temporary, options: .atomic)
            try await service.importFile(temporary, directory: folder, name: "imported.bin", group: group)
            let imported = try await service.snapshot(path: folder + "/imported.bin", group: group)
            guard imported.data == Data("imported binary fixture".utf8) else { throw WorkspaceFailure("导入校验失败。") }
            try await service.rename(path: folder + "/imported.bin", name: "renamed.bin", expected: imported.version, group: group)
            let renamed = try await service.snapshot(path: folder + "/renamed.bin", group: group)
            try await service.remove(path: folder + "/renamed.bin", expected: renamed.version, group: group)
            try await service.remove(path: file, expected: updated.version, group: group)
            guard let directory = try await service.entries(path: documents, group: group).first(where: { $0.name == name }), let version = directory.version else { throw WorkspaceFailure("测试目录状态不可用。") }
            try await service.remove(path: folder, expected: version, group: group)
            let target = try LocalFileTarget(file)
            let records = LocalFileBackupStore.list().filter { $0.originalPath.hasPrefix((target.path as NSString).deletingLastPathComponent + "/") }
            guard records.count >= 3 else { throw WorkspaceFailure("未生成预期的原文件备份。") }
            report["backupPassed"] = true
            report["importRenameDeletePassed"] = true
            // 测试备份也只清理本次唯一目录对应的记录。
            for record in records { try FileManager.default.removeItem(at: LocalFileBackupStore.root.appendingPathComponent(record.id.uuidString)) }
            report["temporaryFilesRemoved"] = true
            report["phase"] = "complete"
        } catch {
            report["phase"] = "failed"; report["error"] = error.localizedDescription
            report["testDirectory"] = folder
        }
        report["finishedAt"] = Date().timeIntervalSince1970; save()
    }
}
