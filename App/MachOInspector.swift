import Foundation

/// Validate all offsets before handing a guest executable to the native patcher.
enum MachOInspector {
    static func setMinimumOS(_ version: UInt32, in data: inout Data) throws {
        guard !(try inspect(data)).isEncrypted else { throw WorkspaceFailure("无法修改加密二进制的系统版本。") }
        func word(_ offset: Int, big: Bool = false) -> UInt32 { data[offset..<offset+4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ((big ? 3 - $1.offset : $1.offset) * 8) } }
        let magic = word(0)
        let bases: [Int]
        if magic == 0xbebafeca || magic == 0xcafebabe {
            let big = magic == 0xbebafeca
            bases = (0..<Int(word(4, big: big))).map { Int(word(8 + $0 * 20 + 8, big: big)) }
        } else { bases = [0] }
        for base in bases where word(base + 4) == 0x0100000c {
            var cursor = base + 32
            for _ in 0..<Int(word(base + 16)) {
                let kind = word(cursor), length = Int(word(cursor + 4))
                if kind == 0x32 || kind == 0x25 {
                    let offset = cursor + (kind == 0x32 ? 12 : 8)
                    for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: version >> (byte * 8)) }
                }
                cursor += length
            }
        }
    }
    struct Result {
        var isEncrypted: Bool; var hasARM64: Bool; var isDynamicLibrary: Bool
        var installName: String?; var minimumOS: String?; var dependencies: [MachODependency]
    }
    static func inspect(_ url: URL) throws -> Result { try inspect(Data(contentsOf: url, options: .mappedIfSafe)) }
    static func inspect(_ data: Data) throws -> Result {
        func word(_ offset: Int, big: Bool = false) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw WorkspaceFailure("可执行文件被截断。") }
            return data[offset..<offset+4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ((big ? 3 - $1.offset : $1.offset) * 8) }
        }
        guard data.count >= 32 else { throw WorkspaceFailure("IPA 中的可执行文件不是有效的 Mach-O。") }
        let magic = try word(0)
        var slices: [(Int, Int)] = []
        if magic == 0xbebafeca || magic == 0xcafebabe {
            let big = magic == 0xbebafeca
            let count = Int(try word(4, big: big))
            guard count > 0, count <= 32, 8 + count * 20 <= data.count else { throw WorkspaceFailure("Mach-O 架构表无效。") }
            for index in 0..<count {
                let start = Int(try word(8 + index * 20 + 8, big: big))
                let size = Int(try word(8 + index * 20 + 12, big: big))
                guard start >= 8 + count * 20, size >= 32, start <= data.count - size else { throw WorkspaceFailure("Mach-O 架构范围越界。") }
                guard !slices.contains(where: { start < $0.0 + $0.1 && $0.0 < start + size }) else { throw WorkspaceFailure("Mach-O 架构范围重叠。") }
                slices.append((start, size))
            }
        } else { slices = [(0, data.count)] }
        var encrypted = false, arm64 = false, dylib = false
        var installName: String?, minimumOS: String?, dependencies: [MachODependency] = []
        for (base, size) in slices {
            guard try word(base) == 0xfeedfacf else { throw WorkspaceFailure("目前仅支持 64 位 iOS 可执行文件。") }
            let cpu = try word(base + 4)
            arm64 = arm64 || cpu == 0x0100000c
            let fileType = try word(base + 12)
            dylib = dylib || (cpu == 0x0100000c && fileType == 6)
            let count = Int(try word(base + 16)), commandSize = Int(try word(base + 20))
            guard count > 0, count <= 32768, commandSize <= size - 32 else { throw WorkspaceFailure("Mach-O 加载命令无效。") }
            let end = base + 32 + commandSize
            var cursor = base + 32
            for _ in 0..<count {
                guard cursor <= end - 8 else { throw WorkspaceFailure("Mach-O 加载命令被截断。") }
                let kind = try word(cursor), length = Int(try word(cursor + 4))
                guard length >= 8, length % 4 == 0, cursor <= end - length else { throw WorkspaceFailure("Mach-O 加载命令长度越界。") }
                if kind == 0x2c || kind == 0x21 {
                    guard length >= 20 else { throw WorkspaceFailure("Mach-O 加密信息无效。") }
                    let cryptID = try word(cursor + 16)
                    encrypted = encrypted || cryptID != 0
                }
                if kind == 0x19 {
                    guard length >= 72 else { throw WorkspaceFailure("Mach-O 段信息无效。") }
                    let sections = Int(try word(cursor + 64))
                    guard sections <= (length - 72) / 80 else { throw WorkspaceFailure("Mach-O 段表越界。") }
                }
                if cpu == 0x0100000c, [UInt32(0xc), 0xd, 0x80000018, 0x8000001f, 0x80000023].contains(kind) {
                    guard length >= 24 else { throw WorkspaceFailure("Mach-O 动态库命令被截断。") }
                    let offset = Int(try word(cursor + 8))
                    guard offset >= 24, offset < length,
                          let terminator = data[(cursor + offset)..<(cursor + length)].firstIndex(of: 0),
                          let name = String(data: data[(cursor + offset)..<terminator], encoding: .utf8), !name.isEmpty else {
                        throw WorkspaceFailure("Mach-O 动态库路径无效。")
                    }
                    if kind == 0xd { installName = name }
                    else if !dependencies.contains(where: { $0.path == name }) { dependencies.append(MachODependency(path: name, isWeak: kind == 0x80000018)) }
                }
                if cpu == 0x0100000c, kind == 0x32 || kind == 0x25 {
                    guard length >= (kind == 0x32 ? 24 : 16) else { throw WorkspaceFailure("Mach-O 系统版本命令被截断。") }
                    let version = try word(cursor + (kind == 0x32 ? 12 : 8))
                    minimumOS = "\(version >> 16).\((version >> 8) & 255).\(version & 255)"
                }
                cursor += length
            }
            guard cursor == end else { throw WorkspaceFailure("Mach-O 加载命令总长度不一致。") }
        }
        return Result(isEncrypted: encrypted, hasARM64: arm64, isDynamicLibrary: dylib, installName: installName, minimumOS: minimumOS, dependencies: dependencies)
    }
}
