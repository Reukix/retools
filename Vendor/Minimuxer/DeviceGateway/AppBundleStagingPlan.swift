import Foundation

/// Retools: normalize filesystem aliases before deriving AFC-relative names.
public struct AppBundleStagingPlan {
    public struct Entry {
        public let source: URL
        public let relativePath: String
        public let isDirectory: Bool
    }
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }
    public let entries: [Entry]
    public let infoData: Data
    public let bundleID: String
    public init(appURL: URL, bundleID: String) throws {
        let root = appURL.standardizedFileURL.resolvingSymlinksInPath()
        guard appURL.pathExtension == "app", bundleID.count < 256,
              bundleID.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else { throw Failure(message: "待安装的应用路径或标识无效。") }
        let infoURL = root.appendingPathComponent("Info.plist")
        let values = try infoURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) < 1_048_576 else { throw Failure(message: "待安装应用缺少有效的根 Info.plist。") }
        infoData = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              executable == (executable as NSString).lastPathComponent,
              FileManager.default.fileExists(atPath: root.appendingPathComponent(executable).path) else {
            throw Failure(message: "待安装应用的 Bundle ID 或主程序不完整，未上传应用。")
        }
        self.bundleID = bundleID
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in failure = error; return false }) else { throw Failure(message: "无法枚举待安装应用。") }
        var files: [Entry] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw Failure(message: "应用包含不支持的链接或特殊文件。") }
            files.append(Entry(source: file, relativePath: try Self.relativePath(file, root: root), isDirectory: values.isDirectory == true))
        }
        if let failure { throw failure }
        guard files.contains(where: { $0.relativePath == "Info.plist" && !$0.isDirectory }) else { throw Failure(message: "应用安装清单缺少根 Info.plist。") }
        entries = files.sorted {
            let a = $0.relativePath.split(separator: "/").count, b = $1.relativePath.split(separator: "/").count
            if a != b { return a < b }
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.relativePath < $1.relativePath
        }
    }
    public static func relativePath(_ file: URL, root: URL) throws -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { throw Failure(message: "应用文件不在安装目录中。") }
        return String(path.dropFirst(base.count + 1))
    }
    public func validateUploadedInfo(_ data: Data) throws {
        guard data == infoData, let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], info["CFBundleIdentifier"] as? String == bundleID else {
            throw Failure(message: "安装暂存目录的 Info.plist 与本地签名包不一致，已停止安装，请重试续签。")
        }
    }
}
