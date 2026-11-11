import Foundation
import RetoolsNative

enum LocalFileArea: String, CaseIterable, Identifiable, Codable {
    case application, appGroup, appExtension, daemon, systemGroup, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .application: "应用数据"
        case .appGroup: "App Group"
        case .appExtension: "扩展数据"
        case .daemon: "内部守护进程"
        case .systemGroup: "系统共享组"
        case .system: "系统数据"
        }
    }
    static func of(_ target: LocalFileTarget) -> Self {
        let path = target.root.path
        if path.contains("/PluginKitPlugin/") { return .appExtension }
        if path.contains("/InternalDaemon/") { return .daemon }
        if path == LocalFileTarget.appGroupParent || path.contains("/AppGroup/") { return .appGroup }
        if path.contains("/SystemGroup/") { return .systemGroup }
        if path == "/private/var/containers/Data/System" { return .system }
        return .application
    }
}

struct LocalFileContainer: Identifiable, Hashable, Codable, Sendable {
    let path: String
    var name: String
    var identifier: String
    var id: String { path }
    var area: LocalFileArea { (try? LocalFileTarget(path)).map(LocalFileArea.of) ?? .application }
    var title: String { name.isEmpty ? (identifier.isEmpty ? (path as NSString).lastPathComponent : identifier) : name }

    static func parse(_ value: [String: String]) -> Self? {
        guard let path = value["path"], let target = try? LocalFileTarget(path), target.components.isEmpty else { return nil }
        return Self(path: target.root.path, name: value["name"] ?? "", identifier: value["identifier"] ?? "")
    }
}

@MainActor
final class LocalFileCatalog: ObservableObject {
    @Published private(set) var containers: [LocalFileContainer] = []
    @Published private(set) var loading = false
    @Published private(set) var scanning = false
    @Published private(set) var cursor: UInt64 = 0
    @Published private(set) var upperBound: UInt64 = 0
    @Published private(set) var message: String?
    private var scanTask: Task<Void, Never>?
    private let cache: URL
    var scanComplete: Bool { upperBound > 0 && cursor > upperBound }

    init(cache: URL = WorkspacePaths().support.appendingPathComponent("LocalFileCatalog.json")) {
        self.cache = cache
        if let bytes = try? Data(contentsOf: cache), let saved = try? JSONDecoder().decode([LocalFileContainer].self, from: bytes) {
            containers = saved.compactMap { LocalFileContainer.parse(["path": $0.path, "name": $0.name, "identifier": $0.identifier]) }
        }
    }

    func merge(_ values: [LocalFileContainer]) {
        var records = Dictionary(containers.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for var value in values {
            if let previous = records[value.path] {
                if value.name.isEmpty { value.name = previous.name }
                if value.identifier.isEmpty { value.identifier = previous.identifier }
            }
            records[value.path] = value
        }
        containers = records.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if let bytes = try? JSONEncoder().encode(containers) { try? bytes.write(to: cache, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }

    private struct Batch: Sendable {
        let containers: [LocalFileContainer]
        let cursor: UInt64
        let upperBound: UInt64
    }
    private nonisolated static func read(scan: Bool, cursor: UInt64 = 0, upperBound: UInt64 = 0) throws -> Batch {
        let value = try RTNative.localFileCatalog(scan: scan, cursor: cursor, upperBound: upperBound)
        return Batch(containers: (value["containers"] as? [[String: String]] ?? []).compactMap(LocalFileContainer.parse),
                     cursor: (value["cursor"] as? NSNumber)?.uint64Value ?? 0,
                     upperBound: (value["upperBound"] as? NSNumber)?.uint64Value ?? 0)
    }

    func discover() async {
        guard !loading, !scanning else { return }
        loading = true; defer { loading = false }
        do {
            let batch = try await Task.detached(priority: .utility) { try Self.read(scan: false) }.value
            merge(batch.containers); message = nil
        } catch { message = error.localizedDescription }
    }

    func startScan() {
        guard !scanning, !loading else { return }
        if scanComplete { cursor = 0; upperBound = 0 }
        scanning = true; message = nil
        scanTask = Task {
            defer { scanning = false; scanTask = nil }
            do {
                while !Task.isCancelled {
                    let start = cursor, bound = upperBound
                    let batch = try await Task.detached(priority: .utility) { try Self.read(scan: true, cursor: start, upperBound: bound) }.value
                    try Task.checkCancellation()
                    guard batch.upperBound > 0, batch.cursor > start else { throw WorkspaceFailure("系统未提供可继续的目录扫描范围。") }
                    merge(batch.containers); cursor = batch.cursor; upperBound = batch.upperBound
                    if scanComplete { break }
                    try await Task.sleep(for: .milliseconds(60))
                }
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }
    func stopScan() { scanTask?.cancel() }
}
