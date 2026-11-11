// Retools integration, 2026-11-11. iPadn sources remain GPL-2.0-or-later.
import SwiftUI
import UIKit
#if DEBUG
import ZIPFoundation
#endif

public enum StorePackageAction: Sendable {
    case importToLibrary, prepareDecryption, installOnDevice
}

private final class ResourceMarker: NSObject {}

@MainActor
public enum StoreBrowserRuntime {
    nonisolated static var resourceBundle: Bundle { Bundle(for: ResourceMarker.self) }
    public nonisolated static var backgroundSessionIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "app.local.iPadn") + ".store-browser.downloads"
    }
    private static var loaded: ToolStore?
    static var store: ToolStore {
        if let loaded { return loaded }
        let value: ToolStore
        #if DEBUG
        if LocalResources.isPreview {
            let app = StoreApp(id: "preview-1", name: "商店功能预览", bundleID: "example.store", version: "1.0")
            var jobs = [DownloadJob(app: app, status: .paused)]
            if let completed = try? makePreviewArchive() { jobs.append(completed) }
            value = ToolStore(downloadManager: DownloadManager(previewJobs: jobs))
            value.prepareVisualPreview()
            if ProcessInfo.processInfo.arguments.contains("--store-browser-download-preview") { value.prepareAccountPreview() }
            if ProcessInfo.processInfo.arguments.contains("--store-browser-light") { value.settings.appearance = "light" }
            if ProcessInfo.processInfo.arguments.contains("--store-browser-dark") { value.settings.appearance = "dark" }
        } else { value = ToolStore() }
        #else
        value = ToolStore()
        #endif
        loaded = value
        return value
    }
    #if DEBUG
    static func makePreviewArchive(app: StoreApp? = nil, version: String? = nil) throws -> DownloadJob {
        var app = app ?? StoreApp(id: "preview-ipa", name: "版本安装预览", bundleID: "com.retools.storepreview", version: "1.0")
        if let version { app.version = version }
        let filename = app.id == "preview-ipa" ? "Retools-Store-Preview.ipa" : "Store-Preview-" + UUID().uuidString + ".ipa"
        let file = LocalResources.packages.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        let archive = try Archive(url: file, accessMode: .create)
        let info: [String: Any] = ["CFBundleIdentifier": app.bundleID, "CFBundleExecutable": "Preview", "CFBundleDisplayName": app.name, "CFBundleShortVersionString": app.version, "CFBundleVersion": "1", "CFBundleSupportedPlatforms": ["iPhoneOS"], "UIDeviceFamily": [1, 2]]
        let metadata = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        let files = [("Payload/Preview.app/Info.plist", metadata), ("Payload/Preview.app/Preview", Data([0xcf, 0xfa, 0xed, 0xfe]))]
        for (path, data) in files {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { offset, size in
                data.subdata(in: Int(offset)..<min(data.count, Int(offset) + size))
            }
        }
        return DownloadJob(app: app, status: .completed, localFilename: filename)
    }
    #endif
    public nonisolated static func registerBackgroundChecks() { UpdateCheckScheduler.register() }
    public static func handleBackgroundEvents(completion: @escaping () -> Void) {
        store.downloads.backgroundCompletion = completion
    }
    public static func didEnterBackground() {
        guard let loaded, !LocalResources.isPreview else { return }
        loaded.apple.saveLiveCookies()
        if loaded.settings.updateNotifications || loaded.settings.watchNotifications {
            UpdateCheckScheduler.schedule()
        } else { UpdateCheckScheduler.cancel() }
    }
}

@MainActor
enum AppContainer { static var shared: ToolStore { StoreBrowserRuntime.store } }

private struct StoreModalKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var storeIsModal: Bool {
        get { self[StoreModalKey.self] }
        set { self[StoreModalKey.self] = newValue }
    }
}

private struct StorePackageHandlerKey: EnvironmentKey {
    static let defaultValue: (@MainActor (URL, StorePackageAction) async throws -> Void)? = nil
}
private struct StoreInstallationSettingsKey: EnvironmentKey {
    static let defaultValue: AnyView? = nil
}
extension EnvironmentValues {
    var storeInstallationSettings: AnyView? {
        get { self[StoreInstallationSettingsKey.self] }
        set { self[StoreInstallationSettingsKey.self] = newValue }
    }
    var storePackageHandler: (@MainActor (URL, StorePackageAction) async throws -> Void)? {
        get { self[StorePackageHandlerKey.self] }
        set { self[StorePackageHandlerKey.self] = newValue }
    }
}

/// Store content embedded in the Retools workbench navigation stack.
@MainActor
public struct StoreBrowserView: View {
    @StateObject private var store = StoreBrowserRuntime.store
    private let initialSearch: String?
    private let installationSettings: AnyView?
    private let onPackage: @MainActor (URL, StorePackageAction) async throws -> Void

    public init(initialSearch: String? = nil, installationSettings: AnyView? = nil, onPackage: @escaping @MainActor (URL, StorePackageAction) async throws -> Void) {
        self.initialSearch = initialSearch
        self.installationSettings = installationSettings
        self.onPackage = onPackage
    }
    public var body: some View {
        RootView()
        .environmentObject(store)
        .environmentObject(store.apple)
        .environmentObject(store.downloads)
        .environmentObject(store.signer)
        .environment(\.storePackageHandler, onPackage)
        .environment(\.storeInstallationSettings, installationSettings)
        .tint(Color.primary)
        .toggleStyle(TintedSwitchToggleStyle())
        .task {
            if let initialSearch, !initialSearch.isEmpty { store.tab = 0; store.search(initialSearch) }
        }
    }
}

struct StorePackageButtons: View {
    let file: URL
    @Environment(\.storePackageHandler) private var handler
    @EnvironmentObject private var store: ToolStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.storeIsModal) private var isModal
    @State private var busy = false

    var body: some View {
        if file.pathExtension.lowercased() == "ipa", handler != nil {
            Button("安装到本机", systemImage: "arrow.down.app") { perform(.installOnDevice) }
                .disabled(busy).accessibilityIdentifier("storeBrowser.installVersion")
            Button("导入 Retools 应用库", systemImage: "square.stack.3d.up") { perform(.importToLibrary) }
                .disabled(busy).accessibilityIdentifier("storeBrowser.importLibrary")
            Button("准备解密助手", systemImage: "lock.open") { perform(.prepareDecryption) }
                .disabled(busy).accessibilityIdentifier("storeBrowser.prepareDecryption")
        }
    }
    private func perform(_ action: StorePackageAction) {
        guard let handler, !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                guard file.resolvingSymlinksInPath().deletingLastPathComponent() == LocalResources.packages.resolvingSymlinksInPath(),
                      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    throw ToolError.message("下载文件已移除，请重新下载。")
                }
                if action != .importToLibrary, isModal {
                    dismiss()
                    // Finish the system sheet dismissal before another workbench route is presented.
                    try await Task.sleep(for: .milliseconds(350))
                }
                try await handler(file, action)
                if action == .importToLibrary { store.infoMessage = "已导入 Retools 应用库，原下载文件已保留" }
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
}
