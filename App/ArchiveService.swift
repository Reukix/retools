import Foundation

enum ArchiveService {
    static let maximumExpandedSize: UInt64 = 8 * 1024 * 1024 * 1024
    static func validate(path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"), !components.contains(".."), !components.contains(".") else {
            throw WorkspaceFailure("压缩包包含不安全的文件路径。")
        }
    }
    static func unpack(_ ipa: URL, to destination: URL, progress: ((Double, String) -> Void)? = nil) throws -> URL {
        let archive = try Archive(url: ipa, accessMode: .read)
        var size: UInt64 = 0, count = 0
        for entry in archive {
            try Task.checkCancellation()
            try validate(path: entry.path)
            guard entry.type != .symlink else { throw WorkspaceFailure("暂不支持包含符号链接的 IPA。") }
            let (next, overflow) = size.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, next <= maximumExpandedSize else { throw WorkspaceFailure("IPA 解压后的体积超过 8 GB。") }
            size = next; count += 1
            guard count <= 100_000 else { throw WorkspaceFailure("IPA 内文件数量过多。") }
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            var extracted: UInt64 = 0
            for entry in archive {
                try Task.checkCancellation()
                _ = try archive.extract(entry, to: destination.appendingPathComponent(entry.path))
                extracted += entry.uncompressedSize
                progress?(size == 0 ? 1 : Double(extracted) / Double(size), (entry.path as NSString).lastPathComponent)
            }
            let payload = destination.appendingPathComponent("Payload")
            let apps = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey]).filter { $0.pathExtension == "app" }
            guard apps.count == 1 else { throw WorkspaceFailure("IPA 必须包含一个 Payload/*.app 应用。") }
            return apps[0]
        } catch { try? fm.removeItem(at: destination); throw error }
    }
    static func metadata(at app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
        guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = dict["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
              let executable = dict["CFBundleExecutable"] as? String, !executable.isEmpty,
              executable == (executable as NSString).lastPathComponent, executable != ".", executable != ".." else {
            throw WorkspaceFailure("IPA 的 Info.plist 缺少有效的标识或可执行文件。")
        }
        return dict
    }
    static func icon(at app: URL, info: [String: Any]) -> Data? {
        let icons = info["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let names = (primary?["CFBundleIconFiles"] as? [String]) ?? (info["CFBundleIconFiles"] as? [String]) ?? []
        let files = (try? FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)) ?? []
        for name in names.reversed() {
            let stem = (name as NSString).deletingPathExtension
            if let file = files.first(where: { $0.lastPathComponent.hasPrefix(stem) && $0.pathExtension.lowercased() == "png" }) {
                if let data = try? Data(contentsOf: file), data.count < 8_000_000 { return data }
            }
        }
        return nil
    }
    static func pack(app: URL, to output: URL, progress: ((Double) -> Void)? = nil) throws {
        let directory = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let payload = directory.appendingPathComponent("Payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: app, to: payload.appendingPathComponent(app.lastPathComponent))
        let tracker = Progress()
        let observation = progress.map { report in tracker.observe(\.fractionCompleted) { value, _ in report(value.fractionCompleted) } }
        defer { observation?.invalidate() }
        if let info = try? metadata(at: app), info["RetoolsDecryptHelper"] as? Bool == true,
           let manifestData = try? Data(contentsOf: app.appendingPathComponent(FairPlayManifest.fileName)) {
            let manifest = try JSONDecoder().decode(FairPlayManifest.self,from: manifestData)
            try manifest.validate()
            let prefix = "Payload/"+app.lastPathComponent+"/"+FairPlayManifest.resourceDirectory+"/Target/"
            let stored = Set(manifest.binaries.filter { $0.encryptedSlices > 0 }.map { prefix+$0.path })
            let archive = try Archive(url: output,accessMode: .create)
            let entries = (try FileManager.default.subpathsOfDirectory(atPath: payload.path)+[""]).sorted()
            for (index,path) in entries.enumerated() {
                try Task.checkCancellation()
                let name = "Payload/"+path
                // Ciphertext is mostly incompressible. Keep its bytes as stored
                // ZIP entries and compress the remaining resources as before.
                try archive.addEntry(with: name,relativeTo: directory,compressionMethod: stored.contains(name) ? .none : .deflate)
                progress?(Double(index+1)/Double(entries.count))
            }
            return
        }
        try FileManager.default.zipItem(at: payload, to: output, shouldKeepParent: true, compressionMethod: .deflate, progress: progress == nil ? nil : tracker)
    }
}
