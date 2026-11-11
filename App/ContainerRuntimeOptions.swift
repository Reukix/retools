import Foundation

enum ContainerLoaderMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case injected, delayed, disabled
    var id: String { rawValue }
    var title: String {
        switch self { case .injected: return "正常注入"; case .delayed: return "延后加载修复组件"; case .disabled: return "关闭 TweakLoader" }
    }
    var injects: Bool { self == .injected }
    var loads: Bool { self != .disabled }
}
enum ContainerOrientation: Int, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = 0, landscape, portrait
    var id: Int { rawValue }
    var title: String { switch self { case .automatic: return "跟随应用"; case .landscape: return "横屏"; case .portrait: return "竖屏" } }
}
enum ContainerLaunchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case global, jitless, jit
    var id: String { rawValue }
    var title: String { switch self { case .global: return "跟随全局设置"; case .jitless: return "免 JIT"; case .jit: return "JIT" } }
    func resolve(_ global: ContainerExecutionMode) -> ContainerExecutionMode { switch self { case .global: return global; case .jitless: return .jitless; case .jit: return .jit } }
}
struct ContainerRuntimeOptions: Codable, Hashable, Sendable {
    var loaderMode: ContainerLoaderMode = .injected
    var spoofSDKVersion = true
    var hideLiveContainer = false
    var fixFilePicker = false
    var fixLocalNotification = false
    var useHostBundleID = false
    var legacyFilePicker = false
    var language = ""
    var orientation: ContainerOrientation = .automatic
    var classicMode = false
    var launchMode: ContainerLaunchMode = .global
    var remark = ""
    var tweakFolder = ""
    var isLocked = false
    var isHidden = false
    init() {}
    enum CodingKeys: String, CodingKey { case loaderMode, spoofSDKVersion, hideLiveContainer, fixFilePicker, fixLocalNotification, useHostBundleID, legacyFilePicker, language, orientation, classicMode, launchMode, remark, tweakFolder, isLocked, isHidden }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loaderMode = try c.decodeIfPresent(ContainerLoaderMode.self, forKey: .loaderMode) ?? loaderMode
        spoofSDKVersion = try c.decodeIfPresent(Bool.self, forKey: .spoofSDKVersion) ?? spoofSDKVersion
        hideLiveContainer = try c.decodeIfPresent(Bool.self, forKey: .hideLiveContainer) ?? hideLiveContainer
        fixFilePicker = try c.decodeIfPresent(Bool.self, forKey: .fixFilePicker) ?? fixFilePicker
        fixLocalNotification = try c.decodeIfPresent(Bool.self, forKey: .fixLocalNotification) ?? fixLocalNotification
        useHostBundleID = try c.decodeIfPresent(Bool.self, forKey: .useHostBundleID) ?? useHostBundleID
        legacyFilePicker = try c.decodeIfPresent(Bool.self, forKey: .legacyFilePicker) ?? legacyFilePicker
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
        orientation = try c.decodeIfPresent(ContainerOrientation.self, forKey: .orientation) ?? orientation
        classicMode = try c.decodeIfPresent(Bool.self, forKey: .classicMode) ?? classicMode
        launchMode = try c.decodeIfPresent(ContainerLaunchMode.self, forKey: .launchMode) ?? launchMode
        remark = try c.decodeIfPresent(String.self, forKey: .remark) ?? remark
        tweakFolder = try c.decodeIfPresent(String.self, forKey: .tweakFolder) ?? tweakFolder
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? isLocked
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? isHidden
    }
    func validate() throws {
        guard language.count <= 64, !language.contains("/"), !language.contains("\\"), !language.contains("\0"), remark.count <= 500 else {
            throw WorkspaceFailure("语言标识无效或备注超过 500 个字符。")
        }
        if !tweakFolder.isEmpty { try ArchiveService.validate(path: tweakFolder) }
    }
}

struct ContainerDataOptions: Codable, Hashable, Sendable {
    var isolateAppGroup = true
    var spoofIdentifierForVendor = true
    var identifierForVendor: UUID?
}
