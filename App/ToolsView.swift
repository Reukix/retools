import SwiftUI
import IPadnKit

/// 工具首页只读取已知状态；连接、挂载与数据加载由目标页面按需处理。
struct ToolsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var renewal: RenewalController
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var device = DeviceToolsStore.shared
    @AppStorage(ToolFavorites.storageKey) private var favoriteData = ToolFavorites.defaultValue
    @State private var path: [WorkspaceTool] = []
    @State private var query = ""
    @State private var category: ToolCategory?
    @State private var customize = false
    @FocusState private var searchFocused: Bool

    private var favorites: [WorkspaceTool] { ToolFavorites.decode(favoriteData) }
    private var browsingAll: Bool { category == nil && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var favoriteColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: typeSize.isAccessibilitySize ? 1 : sizeClass == .regular ? (favorites.count > 4 ? 3 : 4) : 2)
    }
    private var favoriteBinding: Binding<[WorkspaceTool]> {
        Binding(get: { favorites }, set: { favoriteData = ToolFavorites.encode($0) })
    }
    private func items(in group: ToolCategory) -> [WorkspaceTool] {
        WorkspaceTool.allCases.filter {
            $0.category == group && $0.matches(query) &&
            (!browsingAll || !favorites.contains($0)) &&
            (searching || ($0 != .connection && $0 != .overview))
        }
    }
    private var groups: [ToolCategory] {
        ToolCategory.allCases.filter { group in
            (category == nil || category == group) && (!items(in: group).isEmpty || (!searching && group == .device))
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    searchAndFilters
                    if browsingAll { favoritesSection }
                    if groups.isEmpty {
                        ContentUnavailableView {
                            Label("没有找到工具", systemImage: "magnifyingglass")
                        } description: {
                            Text("换个关键词，或切换到全部分类。")
                        } actions: {
                            Button("清除筛选") { query = ""; category = nil; searchFocused = false }
                                .buttonStyle(.bordered)
                        }.accessibilityIdentifier("tools.emptySearch")
                    } else {
                        ForEach(groups) { group in toolSection(group) }
                    }
                }
                .padding(.horizontal, sizeClass == .regular ? 28 : 20)
                .padding(.top, 6).padding(.bottom, 24)
                .frame(maxWidth: 1040).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .ambientBackground().navigationTitle("工具")
            .navigationDestination(for: WorkspaceTool.self) { destination($0) }
            .onChange(of: store.showDecryption, initial: true) { _, value in
                if value { path = [.decryption]; store.showDecryption = false }
            }
            .sheet(isPresented: $customize) { ToolFavoritesView(selection: favoriteBinding) }

        }
    }

    private var searchAndFilters: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.body.weight(.medium)).foregroundStyle(Color.secondary).accessibilityHidden(true)
                TextField("搜索工具", text: $query)
                    .font(.subheadline).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                    .accessibilityIdentifier("tools.search")
                if !query.isEmpty {
                    Button { query = ""; searchFocused = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.secondary).frame(minWidth: 32, minHeight: 32)
                    }.buttonStyle(.plain).accessibilityLabel("清除搜索").accessibilityIdentifier("tools.search.clear")
                }
            }
            .padding(.horizontal, 14).frame(minHeight: 50)
            .background(Palette.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.border))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filter("全部", value: nil)
                    ForEach(ToolCategory.allCases) { filter($0.title, value: $0) }
                }
            }.contentMargins(.vertical, 1)
        }
    }
    private func filter(_ title: String, value: ToolCategory?) -> some View {
        let selected = category == value
        return Button { category = value; searchFocused = false } label: {
            Text(title).font(.subheadline.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? (scheme == .dark ? Palette.accentLight : Palette.accentDeep) : Color.secondary)
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(selected ? Palette.accent.opacity(0.12) : Palette.surface.opacity(0.6), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Palette.accent.opacity(0.16) : Color.clear))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("tools.category." + (value?.rawValue ?? "all"))
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("常用工具").font(.title3.weight(.bold))
                Spacer()
                Button { customize = true } label: {
                    Group {
                        if typeSize.isAccessibilitySize { Text("自定").font(.caption.weight(.semibold)) }
                        else { Label("自定", systemImage: "slider.horizontal.3").font(.subheadline.weight(.medium)) }
                    }.frame(minHeight: 44)
                }.buttonStyle(.plain).foregroundStyle(Color.secondary).accessibilityIdentifier("tools.favorites.edit")
            }
            if favorites.isEmpty {
                Button { customize = true } label: {
                    HStack(spacing: 12) {
                        ToolGlyph(symbol: "star", color: Palette.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("添加常用工具").font(.headline).foregroundStyle(Color.primary)
                            Text("把最常用的入口放在这里").font(.caption).foregroundStyle(Color.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus").foregroundStyle(Palette.accent)
                    }.padding(16).workspaceCard(padding: 0)
                }.buttonStyle(.plain)
            } else {
                LazyVGrid(columns: favoriteColumns, alignment: .leading, spacing: 12) {
                    ForEach(favorites) { tool in
                        Button { open(tool) } label: { FavoriteToolTile(tool: tool) }
                            .buttonStyle(.plain).accessibilityIdentifier(tool.accessibilityID).accessibilityValue("常用工具")
                            .contextMenu { favoriteAction(tool) }
                    }
                }
            }
        }
    }

    private func toolSection(_ group: ToolCategory) -> some View {
        let tools = items(in: group)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.title).font(.title3.weight(.bold))
                Spacer()
                if group == .device, !searching {
                    Button { open(.overview) } label: {
                        HStack(spacing: 4) {
                            Text("总览")
                            if !typeSize.isAccessibilitySize { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)) }
                        }.font(typeSize.isAccessibilitySize ? .caption : .subheadline).frame(minHeight: 44)
                    }.buttonStyle(.plain).foregroundStyle(Color.secondary)
                        .accessibilityIdentifier(browsingAll && favorites.contains(.overview) ? "tools.device.overview" : WorkspaceTool.overview.accessibilityID)
                } else if searching {
                    Text("\(tools.count) 项").font(.caption).foregroundStyle(Color.secondary)
                }
            }
            VStack(spacing: 0) {
                if group == .device, !searching {
                    connectionRow
                    if !tools.isEmpty { Divider().padding(.leading, 66) }
                }
                ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                    Button { open(tool) } label: { ToolListRow(tool: tool, value: value(for: tool)) }
                        .buttonStyle(.plain).accessibilityIdentifier(tool.accessibilityID)
                        .contextMenu { favoriteAction(tool) }
                    if index < tools.count - 1 { Divider().padding(.leading, 66) }
                }
            }
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Palette.border))
        }
    }

    private var connectionRow: some View {
        Button { open(.connection) } label: {
            HStack(spacing: 12) {
                ToolGlyph(symbol: "network", color: .teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("设备连接").font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                    Text(connectionDetail).font(.caption).foregroundStyle(Color.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if renewal.isVerifyingConnection { ProgressView().controlSize(.small) }
                else {
                    Text(renewal.connectionSummary).font(.caption.weight(.medium))
                        .foregroundStyle(renewal.connectionVerified ? Color.green : renewal.connectionCheckFailed ? Color.orange : Color.secondary)
                }
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Palette.tertiaryText)
            }.padding(16).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityIdentifier(browsingAll && favorites.contains(.connection) ? "tools.connection.status" : WorkspaceTool.connection.accessibilityID)
    }
    private var connectionDetail: String {
        if renewal.isVerifyingConnection { return "正在验证已保存的连接" }
        if renewal.connectionVerified { return "回环连接已验证" }
        if !renewal.settings.hasPairing { return "配置后管理设备应用与日志" }
        if renewal.connectionCheckFailed { return "点此检查配对和回环连接" }
        return "已有配对记录，操作时检查连接"
    }
    private func value(for tool: WorkspaceTool) -> String? {
        switch tool {
        case .plugins: return store.state.plugins.isEmpty ? nil : "\(store.state.plugins.count) 个"
        case .apps: return device.appsPhase == .ready ? "\(device.apps.count) 个" : nil
        case .profiles: return device.profilesPhase == .ready ? "\(device.profiles.count) 份" : nil
        case .runtime: return store.containerMode.title
        case .developerImage: return device.developerImageMounted.map { $0 ? "已挂载" : "未挂载" }
        default: return nil
        }
    }
    private func open(_ tool: WorkspaceTool) {
        searchFocused = false
        path.append(tool)
    }
    @ViewBuilder private func favoriteAction(_ tool: WorkspaceTool) -> some View {
        if favorites.contains(tool) {
            Button { favoriteBinding.wrappedValue = favorites.filter { $0 != tool } } label: { Label("移出常用", systemImage: "star.slash") }
        } else {
            Button { favoriteBinding.wrappedValue = favorites + [tool] } label: { Label("添加到常用", systemImage: "star") }
                .disabled(favorites.count >= ToolFavorites.maximumCount)
        }
    }
    @ViewBuilder private func destination(_ tool: WorkspaceTool) -> some View {
        switch tool {
        case .files: LocalFilesView()
        case .decryption: DecryptionView()
        case .storeDownload: StoreBrowserHostView()
        case .plugins: PluginManagerView()
        case .fileBackups: LocalFileBackupsView()
        case .apps: DeviceAppsView()
        case .profiles: DeviceProfilesView()
        case .backups: AppDataBackupsView()
        case .crashes: DeviceCrashReportsView()
        case .logs: DeviceLogConsoleView()
        case .deviceInfo: DeviceInfoView()
        case .connection: DeviceConnectionView()
        case .overview: DeviceToolsView()
        case .processes: DeviceProcessesView()
        case .location: DeviceLocationView()
        case .runtime: ContainerRuntimeSettingsView()
        case .developerImage: DeveloperImageView()
        }
    }
}

extension WorkspaceTool {
    var color: Color {
        switch self {
        case .files, .fileBackups: .blue
        case .decryption, .storeDownload: Palette.accent
        case .plugins, .runtime: .purple
        case .apps, .profiles: .indigo
        case .backups: .teal
        case .crashes: .orange
        case .logs, .processes: .teal
        case .deviceInfo, .connection, .overview: .secondary
        case .location: .green
        case .developerImage: .indigo
        }
    }
}

struct ToolGlyph: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 38
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.48, weight: .medium)).symbolRenderingMode(.hierarchical)
            .foregroundStyle(color).frame(width: size, height: size)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }
}

private struct FavoriteToolTile: View {
    let tool: WorkspaceTool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ToolGlyph(symbol: tool.symbol, color: tool.color)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.tertiaryText).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.title).font(.body.weight(.semibold)).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                Text(tool.detail).font(.caption).foregroundStyle(Color.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading).padding(16)
        .background {
            RoundedRectangle(cornerRadius: 21).fill(Palette.surface)
                .overlay(alignment: .topLeading) {
                    LinearGradient(colors: [tool.color.opacity(0.065), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .clipShape(RoundedRectangle(cornerRadius: 21))
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(tool.color.opacity(0.13)))
        .shadow(color: Palette.shadow.opacity(0.45), radius: 10, x: 0, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 21))
    }
}

private struct ToolListRow: View {
    let tool: WorkspaceTool
    var value: String?
    var body: some View {
        HStack(spacing: 12) {
            ToolGlyph(symbol: tool.symbol, color: tool.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                Text(tool.detail).font(.caption).foregroundStyle(Color.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let value { Text(value).font(.caption).foregroundStyle(Color.secondary).fixedSize() }
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Palette.tertiaryText).accessibilityHidden(true)
        }.padding(16).contentShape(Rectangle())
    }
}
