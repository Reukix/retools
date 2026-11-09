import SwiftUI
import MapKit

/// 定位模拟：在地图上点选、搜索或输入坐标，把整台手机的 GPS 设过去。
struct DeviceLocationView: View {
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var location = DeviceLocationStore.shared
    @ObservedObject private var tools = DeviceToolsStore.shared
    /// 中国大陆的地图用 GCJ-02 坐标，点选的位置要换成 GPS 坐标再交给设备。
    @AppStorage("RetoolsLocationChinaCorrection") private var chinaCorrection = true
    @State private var camera: MapCameraPosition = .automatic
    @State private var target: SavedLocation?
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var showPlaces = false
    @State private var showCoordinateInput = false
    @State private var latitudeText = ""
    @State private var longitudeText = ""

    private func display(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D { chinaCorrection ? ChinaCoordinate.wgsToGcj(c) : c }
    private func gps(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D { chinaCorrection ? ChinaCoordinate.gcjToWgs(c) : c }

    var body: some View {
        VStack(spacing: 0) {
            MapReader { proxy in
                Map(position: $camera) {
                    if let active = location.active, active.coordinate.latitude != target?.latitude || active.coordinate.longitude != target?.longitude {
                        Marker(active.name, systemImage: "location.fill", coordinate: display(active.coordinate)).tint(.green)
                    }
                    if let target {
                        Marker(target.name, systemImage: "mappin", coordinate: display(target.coordinate)).tint(Palette.accent)
                    }
                }
                .mapControls { MapCompass(); MapScaleView() }
                .onTapGesture { point in
                    guard let coordinate = proxy.convert(point, from: .local) else { return }
                    select(SavedLocation(name: "地图选点", latitude: gps(coordinate).latitude, longitude: gps(coordinate).longitude), recenter: false)
                    nameTarget()
                }
            }
            .overlay(alignment: .top) { searchPanel }
            controlPanel
        }
        .navigationTitle("定位模拟").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showPlaces = true } label: { Label("收藏与最近", systemImage: "star") }
                    Button { latitudeText = ""; longitudeText = ""; showCoordinateInput = true } label: { Label("输入坐标", systemImage: "number") }
                    Toggle(isOn: $chinaCorrection) { Label("中国大陆地图纠偏", systemImage: "globe.asia.australia") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear {
            if target == nil, let place = location.active ?? location.recents.first { select(place) }
        }
        .sheet(isPresented: $showPlaces) { placesSheet }
        .alert("输入坐标", isPresented: $showCoordinateInput) {
            TextField("纬度，例如 39.9087", text: $latitudeText).keyboardType(.numbersAndPunctuation)
            TextField("经度，例如 116.3975", text: $longitudeText).keyboardType(.numbersAndPunctuation)
            Button("取消", role: .cancel) {}
            Button("定位到这里") {
                guard let lat = Double(latitudeText.trimmingCharacters(in: .whitespaces)), let lon = Double(longitudeText.trimmingCharacters(in: .whitespaces)),
                      (-90...90).contains(lat), (-180...180).contains(lon) else { tools.errorMessage = "坐标格式不正确：纬度在 -90～90，经度在 -180～180。"; return }
                select(SavedLocation(name: String(format: "%.5f, %.5f", lat, lon), latitude: lat, longitude: lon))
            }
        } message: { Text("填 GPS（WGS-84）坐标，也就是大多数坐标工具给出的值。") }
        .alert("定位模拟", isPresented: Binding(get: { tools.errorMessage != nil }, set: { if !$0 { tools.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(tools.errorMessage ?? "") }
    }

    // MARK: 搜索

    private var searchPanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索地点", text: $query).submitLabel(.search).onSubmit(search).textInputAutocapitalization(.never)
                if searching { ProgressView().controlSize(.small) }
                if !query.isEmpty { Button { query = ""; results = [] } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
            }
            .padding(.horizontal, 12).padding(.vertical, 10).background(.regularMaterial, in: Capsule())
            if !results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(results.prefix(6).enumerated()), id: \.offset) { _, item in
                        Button {
                            let c = gps(Self.coordinate(of: item))
                            select(SavedLocation(name: item.name ?? "搜索结果", latitude: c.latitude, longitude: c.longitude))
                            results = []
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "未命名地点").foregroundStyle(.primary).lineLimit(1)
                                if let address = Self.address(of: item) {
                                    Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 9)
                        }
                        Divider().padding(.leading, 14)
                    }
                }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }.padding(.horizontal).padding(.top, 8)
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        Task {
            defer { searching = false }
            do { results = try await MKLocalSearch(request: request).start().mapItems }
            catch { results = []; tools.errorMessage = "没有找到「\(text)」。" }
        }
    }

    // MARK: 底部面板

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            status
            if let target {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name).font(.headline).lineLimit(1)
                        Text(String(format: "%.6f, %.6f", target.latitude, target.longitude)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer(minLength: 6)
                    Button { location.toggleFavorite(target) } label: {
                        Image(systemName: location.isFavorite(target) ? "star.fill" : "star").font(.title3).foregroundStyle(location.isFavorite(target) ? .yellow : .secondary)
                    }.accessibilityLabel("收藏")
                }
            } else {
                Text("在地图上点一下、搜索地点，或从右上角输入坐标。").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    guard let target else { return }
                    Task { await location.simulate(target, renewal: renewal, tools: tools) }
                } label: {
                    Label(location.active == nil ? "模拟到这里" : "移到这里", systemImage: "location.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Palette.accent).controlSize(.large)
                .disabled(target == nil || location.state == .connecting).accessibilityIdentifier("location.simulate")
                if location.active != nil {
                    Button { Task { await location.stop() } } label: { Label("停止", systemImage: "stop.fill") }
                        .buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("location.stop")
                }
            }
            Text("模拟期间状态栏会显示定位图标，Retools 会在后台保持连接。停止、关闭回环代理或重启手机都会恢复真实位置。系统会把这种位置标记为「软件模拟」，检查这个标记的应用能识别出来。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding().bottomBarBackground()
    }

    @ViewBuilder private var status: some View {
        switch location.state {
        case .idle: Label("未模拟，使用真实位置", systemImage: "location.slash").font(.subheadline).foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(tools.developerImageStep ?? "正在连接定位服务…").font(.subheadline) }
        case .simulating(let place): Label("正在模拟：\(place.name)", systemImage: "location.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange).lineLimit(4)
        }
    }

    // MARK: 收藏与最近

    private var placesSheet: some View {
        NavigationStack {
            List {
                if !location.favorites.isEmpty {
                    Section("收藏") {
                        ForEach(location.favorites) { place in placeRow(place) }
                            .onDelete { $0.map { location.favorites[$0] }.forEach(location.removeFavorite) }
                    }
                }
                if !location.recents.isEmpty {
                    Section("最近") { ForEach(location.recents) { place in placeRow(place) } }
                }
                if location.favorites.isEmpty && location.recents.isEmpty {
                    ContentUnavailableView("还没有收藏的地点", systemImage: "star", description: Text("选好地点后点星标即可收藏。"))
                }
            }
            .navigationTitle("收藏与最近").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showPlaces = false } } }
        }
    }

    private func placeRow(_ place: SavedLocation) -> some View {
        Button { select(place); showPlaces = false } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).foregroundStyle(.primary)
                Text(String(format: "%.5f, %.5f", place.latitude, place.longitude)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 地图接口（iOS 26 起有新的写法）

    private static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(iOS 26, *) { return item.location.coordinate }
        return item.placemark.coordinate
    }

    private static func address(of item: MKMapItem) -> String? {
        if #available(iOS 26, *) { return item.address?.shortAddress ?? item.address?.fullAddress }
        return item.placemark.title
    }

    private static func placeName(_ location: CLLocation) async -> String? {
        if #available(iOS 26, *) {
            guard let item = try? await MKReverseGeocodingRequest(location: location)?.mapItems.first else { return nil }
            return item.name ?? item.address?.shortAddress
        }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        return placemark?.name ?? placemark?.locality
    }

    private func select(_ place: SavedLocation, recenter: Bool = true) {
        target = place
        if recenter { camera = .region(MKCoordinateRegion(center: display(place.coordinate), latitudinalMeters: 1500, longitudinalMeters: 1500)) }
    }

    /// 给地图选点补一个地名。
    private func nameTarget() {
        guard let place = target else { return }
        Task {
            guard let name = await Self.placeName(CLLocation(latitude: place.latitude, longitude: place.longitude)), target?.id == place.id else { return }
            target?.name = name
        }
    }
}
