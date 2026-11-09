import Foundation
import CryptoKit

struct FairPlayFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct FairPlaySlice: Sendable {
    let offset: UInt64, size: UInt64, cpu: UInt32, subtype: UInt32
    let encryptedOffset: UInt64, encryptedSize: UInt64, cryptIDOffset: UInt64
    let cryptID: UInt32, signatureOffset: UInt64, signatureSize: UInt64
}

/// Independent, bounds-checked parser. No mutation occurs during inspection.
enum FairPlayMachO {
    static func isMachO(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic = data.prefix(4).map { $0 }
        return [[0xcf,0xfa,0xed,0xfe], [0xce,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf],
                [0xfe,0xed,0xfa,0xce], [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca],
                [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca]].contains(magic)
    }
    static func inspect(_ url: URL) throws -> [FairPlaySlice] {
        try inspect(Data(contentsOf: url, options: .mappedIfSafe))
    }
    static func inspect(_ data: Data) throws -> [FairPlaySlice] {
        func integer(_ at: Int, _ width: Int = 4, big: Bool = false) throws -> UInt64 {
            guard at >= 0, at <= data.count - width else { throw FairPlayFailure("Mach-O 文件被截断。") }
            return (0..<width).reduce(UInt64(0)) { $0 | UInt64(data[at+$1]) << ((big ? width-1-$1 : $1)*8) }
        }
        let magic = try integer(0)
        var ranges: [(Int, Int)] = []
        if [0xbebafeca,0xcafebabe,0xbfbafeca,0xcafebabf].contains(magic) {
            let big = magic == 0xbebafeca || magic == 0xbfbafeca
            let wide = magic == 0xbfbafeca || magic == 0xcafebabf
            let count = Int(try integer(4, big: big)), stride = wide ? 32 : 20
            guard count > 0, count <= 32, data.count >= 8 + count*stride else { throw FairPlayFailure("Mach-O 架构表无效。") }
            for index in 0..<count {
                let at = 8 + index*stride
                let start = try integer(at+8, wide ? 8 : 4, big: big)
                let size = try integer(at+(wide ? 16 : 12), wide ? 8 : 4, big: big)
                guard start >= UInt64(8+count*stride), size >= 32, start <= UInt64(data.count),
                      size <= UInt64(data.count)-start else { throw FairPlayFailure("Mach-O 架构范围越界。") }
                let range = (Int(start), Int(size))
                guard !ranges.contains(where: { range.0 < $0.0+$0.1 && $0.0 < range.0+range.1 }) else { throw FairPlayFailure("Mach-O 架构范围重叠。") }
                ranges.append(range)
            }
        } else { ranges = [(0, data.count)] }
        var result: [FairPlaySlice] = []
        for (base, size) in ranges {
            guard size >= 32, try integer(base) == 0xfeedfacf else { throw FairPlayFailure("砸壳暂只支持 64 位 Mach-O。") }
            let cpu = UInt32(try integer(base+4)), subtype = UInt32(try integer(base+8))
            let count = Int(try integer(base+16)), total = Int(try integer(base+20))
            guard count <= 32768, total <= size-32 else { throw FairPlayFailure("Mach-O 加载命令范围无效。") }
            let end = base+32+total
            var cursor = base+32, encryption: (UInt64,UInt64,UInt64,UInt32)?, signature: (UInt64,UInt64) = (0,0)
            for _ in 0..<count {
                guard cursor <= end-8 else { throw FairPlayFailure("Mach-O 加载命令被截断。") }
                let kind = try integer(cursor), length = Int(try integer(cursor+4))
                guard length >= 8, length % 4 == 0, length <= end-cursor else { throw FairPlayFailure("Mach-O 加载命令长度无效。") }
                if kind == 0x2c || kind == 0x21 {
                    guard encryption == nil, length >= (kind == 0x2c ? 24 : 20) else { throw FairPlayFailure("Mach-O 加密信息无效。") }
                    let offset = try integer(cursor+8), bytes = try integer(cursor+12), id = UInt32(try integer(cursor+16))
                    guard offset <= UInt64(size), bytes <= UInt64(size)-offset,
                          id == 0 || (bytes > 0 && offset >= UInt64(32+total)) else { throw FairPlayFailure("Mach-O 加密区间越界或覆盖文件头。") }
                    encryption = (offset,bytes,UInt64(cursor+16),id)
                }
                if kind == 0x1d {
                    guard length >= 16, signature.1 == 0 else { throw FairPlayFailure("Mach-O 代码签名信息无效。") }
                    signature = (try integer(cursor+8),try integer(cursor+12))
                    guard signature.0 <= UInt64(size), signature.1 <= UInt64(size)-signature.0 else { throw FairPlayFailure("Mach-O 签名区间越界。") }
                }
                cursor += length
            }
            guard cursor == end else { throw FairPlayFailure("Mach-O 命令总长度不一致。") }
            let enc = encryption ?? (0,0,0,0)
            if enc.3 != 0 {
                guard cpu == 0x0100000c else { throw FairPlayFailure("发现非 arm64 的加密架构，暂无法完整砸壳。") }
            }
            result.append(FairPlaySlice(offset: UInt64(base), size: UInt64(size), cpu: cpu, subtype: subtype,
                encryptedOffset: enc.0, encryptedSize: enc.1, cryptIDOffset: enc.2, cryptID: enc.3,
                signatureOffset: signature.0, signatureSize: signature.1))
        }
        return result
    }
}

struct FairPlayManifest: Codable, Sendable, Equatable {
    struct Binary: Codable, Sendable, Equatable {
        let path: String, sha256: String
        let encryptedSlices: Int
    }
    static let fileName = "RetoolsDecryption.json"
    static let resourceDirectory = "RetoolsPayload"
    static let helperBundleID = "dev.retools.decrypt"
    let schemaVersion: Int
    let id: UUID
    let name: String, bundleID: String, appFileName: String
    let binaries: [Binary]
    var startAuthorization: UUID? = nil
    var encryptedCount: Int { binaries.filter { $0.encryptedSlices > 0 }.count }
    func authorizesStart(_ url: URL) -> Bool {
        guard url.scheme == "retoolsdecrypt", url.host == "start", let token = startAuthorization,
              let query = URLComponents(url: url,resolvingAgainstBaseURL: false)?.queryItems,
              query.filter({ $0.name == "job" }).count == 1,
              query.filter({ $0.name == "authorization" }).count == 1 else { return false }
        return query.first(where: { $0.name == "job" })?.value == id.uuidString
            && query.first(where: { $0.name == "authorization" })?.value == token.uuidString
    }

    func validate() throws {
        guard schemaVersion == 1, appFileName.hasSuffix(".app"), !name.isEmpty, !bundleID.isEmpty,
              !binaries.isEmpty, binaries.count <= 10000 else { throw FairPlayFailure("解密任务信息无效。") }
        try FairPlayFiles.validate(relative: appFileName, singleComponent: true)
        var paths = Set<String>()
        for binary in binaries {
            try FairPlayFiles.validate(relative: binary.path)
            guard paths.insert(binary.path).inserted, binary.encryptedSlices >= 0,
                  binary.sha256.count == 64, binary.sha256.allSatisfy({ $0.isHexDigit }) else { throw FairPlayFailure("解密任务中的二进制记录无效。") }
        }
    }
}

enum FairPlayFiles {
    static func validate(relative path: String, singleComponent: Bool = false) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !singleComponent || parts.count == 1 else { throw FairPlayFailure("解密任务包含不安全的文件路径。") }
    }
    static func regularFiles(in root: URL) throws -> [URL] {
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey], errorHandler: { _, error in failure = error; return false }) else { throw FairPlayFailure("无法遍历应用文件。") }
        var files: [URL] = []
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw FairPlayFailure("解密包中不允许符号链接。") }
            if values.isRegularFile == true { files.append(file) }
            guard files.count <= 100000 else { throw FairPlayFailure("应用文件数量过多。") }
        }
        if let failure { throw failure }
        return files.sorted { $0.path < $1.path }
    }
    static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024*1024), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func binaryRecords(in root: URL) throws -> [FairPlayManifest.Binary] {
        let directory = root.standardizedFileURL.resolvingSymlinksInPath()
        let components = directory.pathComponents
        return try regularFiles(in: directory).compactMap { file in
            let parts = file.standardizedFileURL.pathComponents
            guard parts.count > components.count, Array(parts.prefix(components.count)) == components else { throw FairPlayFailure("目标文件超出了应用目录。") }
            let relative = Array(parts.dropFirst(components.count))
            // Installed Store metadata may be protected even inside our bundle.
            // It is never executable code and is not part of the Mach-O inventory.
            if relative.contains("SC_Info") || relative.contains("_CodeSignature") { return nil }
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            guard FairPlayMachO.isMachO(try handle.read(upToCount: 4) ?? Data()) else { return nil }
            let slices = try FairPlayMachO.inspect(file)
            return FairPlayManifest.Binary(path: relative.joined(separator: "/"), sha256: try hash(file), encryptedSlices: slices.filter { $0.cryptID != 0 }.count)
        }.sorted { $0.path < $1.path }
    }
    static func verifyOriginals(_ manifest: FairPlayManifest, in root: URL) throws {
        try manifest.validate()
        let actual = try binaryRecords(in: root), expected = manifest.binaries.sorted { $0.path < $1.path }
        guard actual == expected else {
            let changed = expected.first { record in actual.first(where: { $0.path == record.path }) != record }?.path
                ?? actual.first { record in !expected.contains(where: { $0.path == record.path }) }?.path ?? "文件列表"
            throw FairPlayFailure("目标二进制已改变（\(changed)），请重新生成解密助手。")
        }
    }
}
