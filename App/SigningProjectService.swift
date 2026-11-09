import Foundation
import ImageIO
import CoreGraphics
import RetoolsNative

struct SigningProjectInspection: Sendable {
    let dependencies: [MachODependency]
    let executable: String
}

enum SigningProjectService {
    static func normalizedIcon(_ data: Data) throws -> Data {
        guard data.count <= 8_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw WorkspaceFailure("请选择小于 8 MB 的有效图片。") }
        return try png(image, side: 1024)
    }
    private static func png(_ image: CGImage, side: Int) throws -> Data {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WorkspaceFailure("无法生成应用图标。") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let scale = max(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2, width: width, height: height))
        let data = NSMutableData()
        guard let output = context.makeImage(), let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw WorkspaceFailure("无法编码应用图标。") }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { throw WorkspaceFailure("无法保存应用图标。") }
        return data as Data
    }
    static func apply(_ options: PackageSigningOptions, package: AppPackage, to app: URL, paths: WorkspacePaths, keepExtensions: Bool = false) throws {
        try options.validate(for: package)
        var info = try ArchiveService.metadata(at: app)
        let originalID = info["CFBundleIdentifier"] as? String ?? package.bundleID
        info["CFBundleIdentifier"] = options.identifier(for: package)
        if keepExtensions { try renameExtensions(in: app, from: originalID, to: options.identifier(for: package)) }
        if !options.displayName.isEmpty {
            info["CFBundleDisplayName"] = options.displayName; info["CFBundleName"] = options.displayName
            for folder in try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil) where folder.pathExtension == "lproj" {
                let file = folder.appendingPathComponent("InfoPlist.strings")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                guard var strings = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] else { throw WorkspaceFailure("无法修改本地化应用名称。") }
                strings["CFBundleDisplayName"] = options.displayName; strings["CFBundleName"] = options.displayName
                try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0).write(to: file, options: .atomic)
            }
        }
        if !options.version.isEmpty { info["CFBundleShortVersionString"] = options.version }
        info["UIFileSharingEnabled"] = options.fileSharing; info["LSSupportsOpeningDocumentsInPlace"] = options.fileSharing
        if options.removeURLSchemes { info.removeValue(forKey: "CFBundleURLTypes") }
        if options.gameMode != .original {
            info["GCSupportsGameMode"] = options.gameMode == .enabled
            info["LSSupportsGameMode"] = options.gameMode == .enabled
        }
        let originalIcons = info["CFBundleIcons"] as? [String: Any] ?? [:]
        let originalPrimary = originalIcons["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
        let ipadPrimary = (info["CFBundleIcons~ipad"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
        let assetName = originalPrimary["CFBundleIconName"] as? String ?? info["CFBundleIconName"] as? String ?? ipadPrimary["CFBundleIconName"] as? String
        if options.iconFile != nil || options.repairWhiteIcon {
            let data: Data?
            if let iconFile = options.iconFile { data = try Data(contentsOf: paths.icons.appendingPathComponent(iconFile)) }
            else { data = ArchiveService.icon(at: app, info: info) }
            guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw WorkspaceFailure("没有找到可重建的 PNG 图标，请先设置自定义图标。") }
            for (name, side) in [("RetoolsIcon60x60@2x.png", 120), ("RetoolsIcon60x60@3x.png", 180), ("RetoolsIcon76x76@2x.png", 152), ("RetoolsIcon83.5x83.5@2x.png", 167)] { try png(image, side: side).write(to: app.appendingPathComponent(name), options: .atomic) }
            info["CFBundleIconFiles"] = ["RetoolsIcon60x60", "RetoolsIcon76x76", "RetoolsIcon83.5x83.5"]
            info.removeValue(forKey: "CFBundleIconName"); info.removeValue(forKey: "CFBundleIconFile")
            for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
                var icons = info[key] as? [String: Any] ?? [:], primary = icons["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
                primary["CFBundleIconFiles"] = info["CFBundleIconFiles"]
                primary.removeValue(forKey: "CFBundleIconName")
                if options.iconFile == nil, options.repairDarkIcon, let assetName, FileManager.default.fileExists(atPath: app.appendingPathComponent("Assets.car").path) { primary["CFBundleIconName"] = assetName }
                icons["CFBundlePrimaryIcon"] = primary; info[key] = icons
            }
        } else if options.repairDarkIcon, let assetName, FileManager.default.fileExists(atPath: app.appendingPathComponent("Assets.car").path) {
            for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
                var icons = info[key] as? [String: Any] ?? [:], primary = icons["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
                primary["CFBundleIconName"] = assetName; icons["CFBundlePrimaryIcon"] = primary; info[key] = icons
            }
        }
        if !options.minimumOS.isEmpty { info["MinimumOSVersion"] = options.minimumOS }
        let removed = (keepExtensions ? [] : ["PlugIns", "Extensions"]) + (options.removeWatch ? ["Watch", "WatchKit", "com.apple.WatchPlaceholder"] : [])
        for name in removed where FileManager.default.fileExists(atPath: app.appendingPathComponent(name).path) { try FileManager.default.removeItem(at: app.appendingPathComponent(name)) }
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: app.appendingPathComponent("Info.plist"), options: .atomic)
    }
    /// 保留扩展时，扩展的 Bundle ID 必须以主应用的 ID 为前缀，否则系统拒绝安装。
    /// 主应用改名后，把扩展里旧的前缀换成新的；不以旧 ID 开头的扩展保持原样。
    static func renameExtensions(in app: URL, from oldID: String, to newID: String) throws {
        guard oldID != newID else { return }
        for folder in ["PlugIns", "Extensions"] {
            let root = app.appendingPathComponent(folder)
            guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for appex in items where appex.pathExtension == "appex" {
                let plist = appex.appendingPathComponent("Info.plist")
                var info = try ArchiveService.metadata(at: appex)
                guard let id = info["CFBundleIdentifier"] as? String, id.hasPrefix(oldID + ".") else { continue }
                info["CFBundleIdentifier"] = newID + id.dropFirst(oldID.count)
                try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: plist, options: .atomic)
            }
        }
    }
    static func inject(_ entries: [PluginInjection], in app: URL, namespace: UUID) throws {
        guard !entries.isEmpty else { return }
        var libraries: [String] = [], weak: [NSNumber] = []
        let routed = entries.filter { $0.signingTarget == .loader }
        var insertedLoader = false
        for entry in entries {
            if entry.signingTarget == .loader {
                if !insertedLoader {
                    let root = app.appendingPathComponent("Frameworks/RetoolsPlugins-" + namespace.uuidString)
                    let source = Bundle.main.bundleURL.appendingPathComponent("Frameworks/RetoolsPluginLoader.framework")
                    let destination = root.appendingPathComponent("RetoolsPluginLoader.dylib")
                    guard FileManager.default.fileExists(atPath: source.appendingPathComponent("RetoolsPluginLoader").path) else { throw WorkspaceFailure("当前安装包缺少 Retools Loader，请更新 Retools 后重试。") }
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.copyItem(at: source.appendingPathComponent("RetoolsPluginLoader"), to: destination)
                    let manifest: [[String: Any]] = routed.map { ["path": PluginService.loadPath($0, namespace: namespace), "optional": $0.loadKind == .optional] }
                    try JSONSerialization.data(withJSONObject: ["version": 1, "entries": manifest], options: .sortedKeys).write(to: root.appendingPathComponent("RetoolsPlugins.json"), options: .atomic)
                    libraries.append("@executable_path/Frameworks/RetoolsPlugins-\(namespace.uuidString)/RetoolsPluginLoader.dylib"); weak.append(NSNumber(value: false))
                    insertedLoader = true
                }
            } else {
                libraries.append("@executable_path/" + PluginService.loadPath(entry, namespace: namespace)); weak.append(NSNumber(value: entry.loadKind == .optional))
            }
        }
        let info = try ArchiveService.metadata(at: app)
        try RTNative.injectLibraries(libraries, weak: weak, intoExecutable: app.appendingPathComponent(info["CFBundleExecutable"] as! String).path)
    }
    static func patchMinimumOS(_ version: String, in app: URL) throws {
        guard !version.isEmpty else { return }
        let value = try PackageSigningOptions.versionNumber(version)
        guard let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let file as URL in files where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let handle = try FileHandle(forReadingFrom: file); let head = try handle.read(upToCount: 4); try handle.close()
            guard let head, [Data([0xcf,0xfa,0xed,0xfe]), Data([0xca,0xfe,0xba,0xbe]), Data([0xbe,0xba,0xfe,0xca])].contains(head) else { continue }
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
            var data = try Data(contentsOf: file); try MachOInspector.setMinimumOS(value, in: &data)
            try data.write(to: file, options: .atomic)
            if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
        }
    }
}
