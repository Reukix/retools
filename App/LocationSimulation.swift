import Foundation
import CoreLocation
import IdeviceGateway

/// 一条保持中的定位模拟连接。
protocol DeviceLocationChannel: Sendable {
    func set(_ coordinate: CLLocationCoordinate2D) async throws
    func clear() async throws
    func close() async
}

struct LiveLocationChannel: DeviceLocationChannel {
    /// 连接对象要和会话一起存活。
    let link: LocalDeviceLink
    let session: DeviceLocationSession
    func set(_ coordinate: CLLocationCoordinate2D) async throws { try await session.set(latitude: coordinate.latitude, longitude: coordinate.longitude) }
    func clear() async throws { try await session.clear() }
    func close() async { await session.close() }
}

// MARK: - 坐标

/// 中国大陆地图（含 Apple 地图在中国的数据）使用 GCJ-02，GPS 使用 WGS-84。
/// 在地图上点选或搜索到的坐标要换成 WGS-84 再交给设备，地图上显示时再换回去。
enum ChinaCoordinate {
    private static let a = 6378245.0, ee = 0.00669342162296594323

    static func isOutsideChina(_ c: CLLocationCoordinate2D) -> Bool {
        c.longitude < 72.004 || c.longitude > 137.8347 || c.latitude < 0.8293 || c.latitude > 55.8271
    }

    private static func delta(_ c: CLLocationCoordinate2D) -> (lat: Double, lon: Double) {
        let x = c.longitude - 105.0, y = c.latitude - 35.0
        var dLat = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        dLat += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        dLat += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        dLat += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        var dLon = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        dLon += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        dLon += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        dLon += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        let radLat = c.latitude / 180.0 * .pi
        var magic = sin(radLat); magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return (dLat, dLon)
    }

    static func wgsToGcj(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard !isOutsideChina(c) else { return c }
        let d = delta(c)
        return CLLocationCoordinate2D(latitude: c.latitude + d.lat, longitude: c.longitude + d.lon)
    }

    /// 迭代反解，误差在厘米级。
    static func gcjToWgs(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard !isOutsideChina(c) else { return c }
        var wgs = c
        for _ in 0..<6 {
            let back = wgsToGcj(wgs)
            wgs = CLLocationCoordinate2D(latitude: wgs.latitude + (c.latitude - back.latitude), longitude: wgs.longitude + (c.longitude - back.longitude))
        }
        return wgs
    }
}

/// 收藏或最近使用的地点，坐标为 WGS-84（设备 GPS 坐标）。
struct SavedLocation: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

// MARK: - 保持后台运行

/// 模拟期间 Retools 切到后台也要保持连接。开启「后台定位活动」让系统不挂起 Retools，状态栏会显示定位图标。
@MainActor
final class LocationKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var session: AnyObject?

    func start() {
        manager.delegate = self
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        if session == nil { session = CLBackgroundActivitySession() }
    }

    func stop() {
        (session as? CLBackgroundActivitySession)?.invalidate()
        session = nil
    }
}

// MARK: - 状态

@MainActor
final class DeviceLocationStore: ObservableObject {
    static let shared = DeviceLocationStore()

    enum State: Equatable {
        case idle, connecting
        case simulating(SavedLocation)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var favorites: [SavedLocation] = []
    @Published private(set) var recents: [SavedLocation] = []

    private let backend: DeviceToolsBackend
    private let defaults: UserDefaults
    private var channel: DeviceLocationChannel?
    private var keepAliveTimer: Task<Void, Never>?
    private let keepAlive: LocationKeepAlive?

    /// 每隔一段时间重发一次当前位置，顺便发现连接是否断开。
    static let refreshInterval: Duration = .seconds(20)

    init(backend: DeviceToolsBackend? = nil, defaults: UserDefaults = .standard, keepAlive: Bool = true) {
        self.backend = backend ?? DeviceToolsStore.shared.backend
        self.defaults = defaults
        self.keepAlive = keepAlive ? LocationKeepAlive() : nil
        favorites = Self.load("RetoolsLocationFavorites", defaults)
        recents = Self.load("RetoolsLocationRecents", defaults)
    }

    var active: SavedLocation? { if case .simulating(let place) = state { return place }; return nil }

    /// 开始模拟，或在模拟中换一个位置。
    func simulate(_ place: SavedLocation, renewal: RenewalController, tools: DeviceToolsStore) async {
        guard state != .connecting else { return }
        guard backend.isSample || renewal.settings.hasPairing else { state = .failed("请先在「设备配对与连接」里配对这台 iPhone，并打开回环代理。"); return }
        let previous = state
        state = .connecting
        do {
            if channel == nil {
                try await tools.ensureDeveloperImage(renewal: renewal)
                channel = try await openChannel(renewal)
            }
            do { try await channel!.set(place.coordinate) }
            catch {
                // 连接可能已经失效（例如回环代理重启），换一条新的再试一次。
                await channel?.close(); channel = try await openChannel(renewal)
                try await channel!.set(place.coordinate)
            }
            state = .simulating(place)
            remember(place)
            keepAlive?.start()
            startRefreshing()
            AuthDiagnostics.record(stage: "定位模拟", message: "已设置为 \(place.name)")
        } catch {
            // 连接关闭后设备会恢复真实位置，界面同步回到未模拟状态。
            await channel?.close(); channel = nil
            stopRefreshing(); keepAlive?.stop()
            state = .failed(error.localizedDescription)
            _ = previous
        }
    }

    /// 恢复真实位置并断开连接。
    func stop() async {
        stopRefreshing()
        if let channel { try? await channel.clear(); await channel.close() }
        channel = nil
        keepAlive?.stop()
        state = .idle
        AuthDiagnostics.record(stage: "定位模拟", message: "已恢复真实位置")
    }

    private func openChannel(_ renewal: RenewalController) async throws -> DeviceLocationChannel {
        let backend = backend
        let (host, port, udid) = (renewal.settings.hostIP, renewal.settings.remotePort, renewal.settings.deviceUDID)
        return try await DeviceToolsTimeout.run("连接定位服务", seconds: 30) { try await backend.openLocationChannel(host: host, port: port, udid: udid) }
    }

    private func startRefreshing() {
        keepAliveTimer?.cancel()
        keepAliveTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard let self, !Task.isCancelled, let place = self.active, let channel = self.channel else { return }
                do { try await channel.set(place.coordinate) }
                catch {
                    AuthDiagnostics.record(stage: "定位模拟", message: "连接中断：\(error.localizedDescription)")
                    await channel.close(); self.channel = nil
                    self.keepAlive?.stop()
                    self.state = .failed("定位模拟的连接已中断，手机已恢复真实位置。请确认回环代理开着，然后重新开始。")
                    return
                }
            }
        }
    }

    private func stopRefreshing() { keepAliveTimer?.cancel(); keepAliveTimer = nil }

    // MARK: 收藏与最近

    func isFavorite(_ place: SavedLocation) -> Bool { favorites.contains { abs($0.latitude - place.latitude) < 1e-6 && abs($0.longitude - place.longitude) < 1e-6 } }

    func toggleFavorite(_ place: SavedLocation) {
        if isFavorite(place) { favorites.removeAll { abs($0.latitude - place.latitude) < 1e-6 && abs($0.longitude - place.longitude) < 1e-6 } }
        else { favorites.insert(place, at: 0) }
        Self.save(favorites, "RetoolsLocationFavorites", defaults)
    }

    func removeFavorite(_ place: SavedLocation) {
        favorites.removeAll { $0.id == place.id }
        Self.save(favorites, "RetoolsLocationFavorites", defaults)
    }

    func rename(_ place: SavedLocation, to name: String) {
        guard let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        favorites[index].name = name
        Self.save(favorites, "RetoolsLocationFavorites", defaults)
    }

    private func remember(_ place: SavedLocation) {
        recents.removeAll { abs($0.latitude - place.latitude) < 1e-6 && abs($0.longitude - place.longitude) < 1e-6 }
        recents.insert(place, at: 0)
        recents = Array(recents.prefix(10))
        Self.save(recents, "RetoolsLocationRecents", defaults)
    }

    private static func load(_ key: String, _ defaults: UserDefaults) -> [SavedLocation] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([SavedLocation].self, from: $0) } ?? []
    }
    private static func save(_ places: [SavedLocation], _ key: String, _ defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(places), forKey: key)
    }
}
