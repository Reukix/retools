import Foundation

enum ContainerExecutionMode: String, CaseIterable, Identifiable {
    case jitless, jit
    var id: String { rawValue }
    var title: String { self == .jitless ? "免 JIT" : "JIT" }
}

enum WorkspaceTab: String, CaseIterable {
    case library, chat, containers, tools, settings
    var title: String {
        switch self { case .library: return "应用库"; case .chat: return "AI"; case .containers: return "容器"; case .tools: return "工具"; case .settings: return "设置" }
    }
    var symbol: String {
        switch self { case .library: return "square.grid.2x2"; case .chat: return "bubble.left.and.bubble.right"; case .containers: return "shippingbox"; case .tools: return "wrench.and.screwdriver"; case .settings: return "gearshape" }
    }
}

struct AppPackage: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var bundleID: String
    var version: String
    var build: String
    var minimumOS: String
    var fileName: String
    var iconFile: String?
    var byteCount: Int64
    var isEncrypted: Bool
    var importedAt: Date
    var signedFile: String?
    var signedAt: Date?
    var signedExpiresAt: Date?
    var signedBundleID: String?
    /// 上次用 Apple ID 签名时主应用与扩展的申请内容；续签时直接取描述文件，不必重新解包。
    var appleBundles: [AppleBundleRequest]?
    var pluginIDs: [UUID]?
    var pluginInjections: [PluginInjection]?
    var embeddedLibraries: [EmbeddedLibrary]?
    var embeddedLibraryInspectionVersion: Int?
    var signingOptions: PackageSigningOptions?
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file) }
}

struct DataContainer: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var options: ContainerDataOptions?
    var folderName: String { id.uuidString }
}

struct ContainerApp: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var packageID: UUID
    var name: String
    var bundleID: String
    var version: String
    var folder: String
    var iconFile: String?
    var containers: [DataContainer]
    var selectedContainerID: UUID
    var installedAt: Date
    var lastLaunched: Date?
    var signedFingerprint: String?
    var signedRuntimeRevision: Int?
    var pluginIDs: [UUID]?
    var pluginInjections: [PluginInjection]?
    var runtimeOptions: ContainerRuntimeOptions?
    var selectedContainer: DataContainer? { containers.first { $0.id == selectedContainerID } }
}

struct EmbeddedLibrary: Codable, Hashable, Identifiable, Sendable {
    var path: String
    var byteCount: Int64
    var isFramework: Bool
    var linkedBy: [String]
    var weakLinkedBy: [String]
    var isPresent: Bool
    var minimumOS: String?
    var dependencies: [MachODependency]
    var pluginEvidence: [EmbeddedPluginEvidence]?
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var linkageLabel: String { linkedBy.isEmpty ? "随包携带" : (linkedBy.count == weakLinkedBy.count ? "已链接 · 弱链接" : "已链接") }
    var isInjectedPlugin: Bool { !(pluginEvidence ?? []).isEmpty && !isInjectionSupport }
    var isInjectionSupport: Bool { Self.isInjectionSupport(path: path) }
    static func isInjectionSupport(path: String) -> Bool {
        let base = (((path as NSString).lastPathComponent) as NSString).deletingPathExtension.lowercased()
        let unversioned = String(base.split(separator: ".").first ?? Substring(base))
        let support = Set(["libsubstrate", "substrate", "cydiasubstrate", "libsubstitute", "substitute", "libellekit", "ellekit", "libhooker", "loadcontrol", "tweakloader", "retoolspluginloader", "sideloadfixer", "sideloadfixerlol", "sideloadkeychainfix"])
        return support.contains(unversioned) || base.hasPrefix("libswift") || base.hasPrefix("libclang_rt")
    }
}
enum EmbeddedPluginEvidence: String, Codable, Hashable, Sendable {
    case appendedLoadCommand, loaderManifest, tweakFilter, loaderDirectory
    var title: String { switch self { case .appendedLoadCommand: return "追加的加载命令"; case .loaderManifest: return "插件加载清单"; case .tweakFilter: return "插件匹配配置"; case .loaderDirectory: return "插件加载器目录" } }
}

struct SigningIdentity: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var teamID: String
    var profileName: String
    var applicationIdentifier: String
    var expiresAt: Date
    var certificateExpiresAt: Date
    var fingerprint: String
    var importedAt: Date
    var profileScopeFingerprint: String?
    var isExpired: Bool { min(expiresAt, certificateExpiresAt) <= Date() }
    var daysRemaining: Int { max(0, Calendar.current.dateComponents([.day], from: Date(), to: min(expiresAt, certificateExpiresAt)).day ?? 0) }
    func supports(bundleID: String) -> Bool {
        let prefix = teamID + "."
        guard applicationIdentifier.hasPrefix(prefix) else { return false }
        let pattern = String(applicationIdentifier.dropFirst(prefix.count))
        if pattern == "*" { return !bundleID.isEmpty }
        if pattern.hasSuffix(".*") { return bundleID.hasPrefix(String(pattern.dropLast())) && bundleID.count > pattern.count - 1 }
        // Exact signing identities are retained independently of CFBundleIdentifier.
        return !pattern.isEmpty && !bundleID.isEmpty
    }
}

struct Activity: Identifiable, Codable, Sendable {
    var id = UUID()
    var title: String
    var detail: String
    var date = Date()
    var symbol: String
}

struct WorkspaceState: Codable, Sendable {
    var schemaVersion = 1
    var packages: [AppPackage] = []
    var identities: [SigningIdentity] = []
    var activeIdentityID: UUID?
    var hostIdentityID: UUID?
    /// 仍然存在的容器证书；引用的证书被删除后视为「跟随当前签名证书」。
    var validHostIdentityID: UUID? { hostIdentityID.flatMap { id in identities.contains { $0.id == id } ? id : nil } }
    var containerApps: [ContainerApp] = []
    var activities: [Activity] = []
    var plugins: [PluginRecord] = []
    init() {}
    enum CodingKeys: String, CodingKey { case schemaVersion, packages, identities, activeIdentityID, hostIdentityID, containerApps, activities, plugins }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        packages = try values.decodeIfPresent([AppPackage].self, forKey: .packages) ?? []
        identities = try values.decodeIfPresent([SigningIdentity].self, forKey: .identities) ?? []
        activeIdentityID = try values.decodeIfPresent(UUID.self, forKey: .activeIdentityID)
        hostIdentityID = try values.decodeIfPresent(UUID.self, forKey: .hostIdentityID)
        containerApps = try values.decodeIfPresent([ContainerApp].self, forKey: .containerApps) ?? []
        activities = try values.decodeIfPresent([Activity].self, forKey: .activities) ?? []
        plugins = try values.decodeIfPresent([PluginRecord].self, forKey: .plugins) ?? []
    }
}

struct PluginRecord: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case dylib, deb, framework }
    var id: UUID
    var name: String
    var kind: Kind
    var sourceFileName: String
    var executablePaths: [String]
    var fingerprint: String
    var byteCount: Int64
    var importedAt: Date
    var binaries: [PluginBinary]?
    var resourceCount: Int?
}
enum PluginTarget: Hashable, Sendable { case package(UUID), container(UUID) }

struct MachODependency: Codable, Hashable, Identifiable, Sendable {
    var path: String
    var isWeak: Bool
    var id: String { path }
}
struct PluginBinary: Codable, Hashable, Identifiable, Sendable {
    var path: String
    var byteCount: Int64
    var installName: String?
    var minimumOS: String?
    var dependencies: [MachODependency]
    var bundleFilters: [String]
    var executableFilters: [String]
    var id: String { path }
}
enum PluginLoadKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case required, optional
    var id: String { rawValue }
    var title: String { self == .required ? "必须加载" : "可选加载（弱链接）" }
}
struct PluginInjection: Codable, Hashable, Identifiable, Sendable {
    var pluginID: UUID
    var path: String
    var loadKind: PluginLoadKind = .required
    var signingTarget: PluginSigningTarget?
    var id: String { pluginID.uuidString + ":" + path }
}

enum PluginSigningTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case executable, loader
    var id: String { rawValue }
    var title: String { self == .executable ? "主程序直接注入" : "通过 Retools Loader" }
}

struct WorkspaceFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct WorkspacePaths: Sendable {
    var documents: URL
    var support: URL
    init(documents: URL? = nil, support: URL? = nil) {
        self.documents = documents ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.support = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Retools")
    }
    var library: URL { documents.appendingPathComponent("Retools/Library") }
    var exports: URL { documents.appendingPathComponent("Retools/Exports") }
    var icons: URL { support.appendingPathComponent("Icons") }
    var credentials: URL { support.appendingPathComponent("Credentials") }
    var plugins: URL { support.appendingPathComponent("Plugins") }
    var tweaks: URL { documents.appendingPathComponent("Tweaks") }
    var applications: URL { documents.appendingPathComponent("Applications") }
    var data: URL { documents.appendingPathComponent("Data/Application") }
    var staging: URL { support.appendingPathComponent("Staging") }
    var state: URL { support.appendingPathComponent("workspace.json") }
    func createDirectories() throws {
        for url in [library, exports, icons, credentials, plugins, tweaks, applications, data, staging] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
