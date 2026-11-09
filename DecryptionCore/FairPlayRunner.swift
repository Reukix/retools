import Foundation
#if !RETOOLS_DECRYPT_HELPER
import RetoolsNative
#endif

struct FairPlayReceipt: Codable, Sendable {
    let jobID: UUID, succeeded: Bool
    let outputName: String?, sha256: String?, error: String?
    let decryptedFiles: Int
}

enum FairPlayRunner {
    typealias DecryptRegion = (URL, URL, FairPlaySlice) throws -> Void

    static func decryptRegion(source: URL, output: URL, slice: FairPlaySlice) throws {
        let region = RTFairPlayRegion(slice_offset: slice.offset, slice_size: slice.size,
            encrypted_offset: slice.encryptedOffset, encrypted_size: slice.encryptedSize,
            signature_offset: slice.signatureOffset, signature_size: slice.signatureSize,
            cpu_type: slice.cpu, cpu_subtype: slice.subtype)
        var result = RTFairPlayResult()
        let status = source.path.withCString { a in output.path.withCString { b in rt_fairplay_decrypt_region(a,b,region,&result,nil,nil) } }
        guard status == 0, result.bytes_written == slice.encryptedSize, result.changed_bytes > 0 else {
            throw FairPlayFailure("系统未能确认解密（errno \(result.system_error)，页面错误 \(result.mach_error)，许可/签名错误 \(result.signature_error)）。请确认这台设备登录了拥有该应用的商店账号；当前系统也可能不支持此方式。")
        }
    }

    /// The source must remain in the installed helper's bundle. Only copies are patched.
    static func run(manifest: FairPlayManifest, source: URL, outputDirectory: URL,
                    decrypt: DecryptRegion = decryptRegion,
                    progress: (String) -> Void = { _ in }) throws -> URL {
        progress("正在校验已安装的源文件…")
        try FairPlayFiles.verifyOriginals(manifest, in: source)
        let fm = FileManager.default
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let work = outputDirectory.appendingPathComponent("work-"+UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let app = work.appendingPathComponent(manifest.appFileName)
        progress("正在建立可写的工作副本…")
        try copyWorkingTree(source: source,to: app)
        for (index, binary) in manifest.binaries.enumerated() {
            try Task.checkCancellation()
            progress("正在处理 \(index+1)/\(manifest.binaries.count)：\((binary.path as NSString).lastPathComponent)")
            let original = source.appendingPathComponent(binary.path), copy = app.appendingPathComponent(binary.path)
            let slices = try FairPlayMachO.inspect(original)
            for slice in slices where slice.cryptID != 0 {
                try decrypt(original,copy,slice)
                try Task.checkCancellation()
                // The native call must have actually written different bytes in the protected range.
                let a = try FileHandle(forReadingFrom: original), b = try FileHandle(forReadingFrom: copy)
                defer { try? a.close(); try? b.close() }
                try a.seek(toOffset: slice.offset+slice.encryptedOffset); try b.seek(toOffset: slice.offset+slice.encryptedOffset)
                var left = slice.encryptedSize, changed = false
                while left > 0 {
                    let size = Int(min(left,1024*1024))
                    let old = try a.read(upToCount: size), new = try b.read(upToCount: size)
                    guard old?.count == size, new?.count == size else { throw FairPlayFailure("解密副本被截断。") }
                    if old != new { changed = true }; left -= UInt64(size)
                }
                guard changed else { throw FairPlayFailure("加密区域没有变化，未生成砸壳结果。") }
                let handle = try FileHandle(forWritingTo: copy); defer { try? handle.close() }
                try handle.seek(toOffset: slice.cryptIDOffset)
                try handle.write(contentsOf: Data(repeating: 0, count: 4)); try handle.synchronize()
            }
        }
        progress("正在校验全部二进制…")
        let verified = try FairPlayFiles.binaryRecords(in: app)
        guard verified.map(\.path) == manifest.binaries.map(\.path), verified.allSatisfy({ $0.encryptedSlices == 0 }) else {
            throw FairPlayFailure("仍有加密二进制，未生成完整砸壳结果。")
        }
        // Signatures and store licenses no longer match the modified binaries. Export for re-signing.
        for file in try FairPlayFiles.regularFiles(in: app) where file.lastPathComponent == "embedded.mobileprovision" {
            try fm.removeItem(at: file)
        }
        if let folders = fm.enumerator(at: app, includingPropertiesForKeys: [.isDirectoryKey]) {
            var obsolete: [URL] = []
            for case let folder as URL in folders where ["_CodeSignature","SC_Info"].contains(folder.lastPathComponent) {
                if (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true { obsolete.append(folder); folders.skipDescendants() }
            }
            for folder in obsolete { try fm.removeItem(at: folder) }
        }
        progress("正在打包 IPA…")
        let filename = manifest.id.uuidString+"-decrypted.ipa"
        let temporary = work.appendingPathComponent(filename), destination = outputDirectory.appendingPathComponent(filename)
        try ArchiveService.pack(app: app, to: temporary)
        // Re-open the archive before publishing; a failed run cannot leave a successful-looking IPA.
        let check = try ArchiveService.unpack(temporary, to: work.appendingPathComponent("Verify"))
        guard try FairPlayFiles.binaryRecords(in: check) == verified else { throw FairPlayFailure("输出 IPA 校验失败。") }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporary, to: destination)
        return destination
    }

    // Installed bundle metadata can carry permissions/attributes which copyItem
    // cannot reproduce inside Documents. Copy bytes into fresh writable files.
    // Licenses stay beside the immutable source used by mremap_encrypted; they
    // and the old code seals must never be included in the decrypted output.
    static func copyWorkingTree(source: URL, to destination: URL) throws {
        let fm = FileManager.default, root = source.standardizedFileURL.resolvingSymlinksInPath()
        let base = root.pathComponents
        try fm.createDirectory(at: destination,withIntermediateDirectories: true,attributes: [.posixPermissions:0o755])
        guard let entries = fm.enumerator(at: root,includingPropertiesForKeys: [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey]) else { throw FairPlayFailure("无法遍历工作副本的源目录。") }
        var count = 0
        for case let file as URL in entries {
            try Task.checkCancellation()
            count += 1; guard count <= 100000 else { throw FairPlayFailure("应用文件数量过多。") }
            let values = try file.resourceValues(forKeys: [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw FairPlayFailure("解密包中不允许符号链接。") }
            let parts = file.standardizedFileURL.pathComponents
            guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { throw FairPlayFailure("工作文件超出了源目录。") }
            let relative = Array(parts.dropFirst(base.count))
            if relative.contains("SC_Info") || relative.contains("_CodeSignature") {
                if values.isDirectory == true { entries.skipDescendants() }
                continue
            }
            let copy = destination.appendingPathComponent(relative.joined(separator: "/"))
            if values.isDirectory == true {
                try fm.createDirectory(at: copy,withIntermediateDirectories: true,attributes: [.posixPermissions:0o755]); continue
            }
            guard values.isRegularFile == true else { throw FairPlayFailure("工作副本包含不支持的文件类型。") }
            if file.lastPathComponent == "embedded.mobileprovision" { continue }
            try fm.createDirectory(at: copy.deletingLastPathComponent(),withIntermediateDirectories: true)
            let mode = (try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            guard fm.createFile(atPath: copy.path,contents: nil,attributes: [.posixPermissions: (mode & 0o111) == 0 ? 0o644 : 0o755]) else { throw FairPlayFailure("无法创建可写的工作文件。") }
            let input = try FileHandle(forReadingFrom: file), output = try FileHandle(forWritingTo: copy)
            do {
                while let data = try input.read(upToCount: 1024*1024), !data.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: data) }
                try input.close(); try output.close()
            } catch { try? input.close(); try? output.close(); throw error }
        }
    }
}
