import Foundation

enum ToolCategory: String, CaseIterable, Identifiable, Hashable {
    case files, device, developer
    var id: String { rawValue }
    var title: String {
        switch self { case .files: "文件与应用"; case .device: "设备管理"; case .developer: "开发调试" }
    }
}

enum WorkspaceTool: String, CaseIterable, Codable, Identifiable, Hashable {
    case files = "localFiles", decryption, storeDownload, plugins, fileBackups
    case apps, profiles, backups, crashes, logs, deviceInfo, connection, overview = "device"
    case processes, location, runtime, developerImage
    var id: String { rawValue }
    var accessibilityID: String { "tools." + rawValue }
    var category: ToolCategory {
        switch self {
        case .files, .decryption, .storeDownload, .plugins, .fileBackups: .files
        case .apps, .profiles, .backups, .crashes, .logs, .deviceInfo, .connection, .overview: .device
        case .processes, .location, .runtime, .developerImage: .developer
        }
    }
    var title: String {
        switch self {
        case .files: "本机文件"
        case .decryption: "应用砸壳"
        case .storeDownload: "商店下载"
        case .plugins: "插件管理"
        case .fileBackups: "文件备份"
        case .apps: "设备应用"
        case .profiles: "描述文件"
        case .backups: "应用数据备份"
        case .crashes: "崩溃日志"
        case .logs: "实时日志"
        case .deviceInfo: "设备信息"
        case .connection: "配对与连接"
        case .overview: "设备总览"
        case .processes: "进程管理"
        case .location: "定位模拟"
        case .runtime: "容器运行设置"
        case .developerImage: "开发者镜像"
        }
    }
    var detail: String {
        switch self {
        case .files: "编辑、导入与管理文件"
        case .decryption: "下载与准备解密助手"
        case .storeDownload: "搜索、历史版本、已购与多地区比价"
        case .plugins: "管理 dylib、deb 等签名插件"
        case .fileBackups: "查看并导出文件修改前的备份"
        case .apps: "查看和管理已安装应用"
        case .profiles: "查看有效期、清理与恢复"
        case .backups: "备份、导出与恢复应用数据"
        case .crashes: "查看崩溃与内存异常记录"
        case .logs: "接收和筛选设备运行日志"
        case .deviceInfo: "系统、存储空间与电池信息"
        case .connection: "设备配对与回环连接配置"
        case .overview: "设备工具与系统操作"
        case .processes: "查看进程与资源占用"
        case .location: "选择地点并模拟设备位置"
        case .runtime: "JIT、运行证书与容器检测"
        case .developerImage: "挂载状态与自动挂载设置"
        }
    }
    var symbol: String {
        switch self {
        case .files: "folder.fill"
        case .decryption: "lock.open.fill"
        case .storeDownload: "bag.fill"
        case .plugins: "puzzlepiece.extension.fill"
        case .fileBackups: "clock.arrow.circlepath"
        case .apps: "square.grid.2x2.fill"
        case .profiles: "doc.badge.gearshape"
        case .backups: "externaldrive.badge.timemachine"
        case .crashes: "exclamationmark.bubble.fill"
        case .logs: "waveform.path"
        case .deviceInfo: "iphone"
        case .connection: "network"
        case .overview: "slider.horizontal.3"
        case .processes: "cpu"
        case .location: "location.fill"
        case .runtime: "shippingbox.fill"
        case .developerImage: "externaldrive.fill.badge.plus"
        }
    }
    private var keywords: String {
        switch self {
        case .files: "worse_query wq 路径 目录 读写 文本 plist 文件管理 容器文件"
        case .decryption: "decrypt fairplay ipa app store 商店 下载 解密 脱壳 砸殼"
        case .storeDownload: "ipadn app store ipa pkg 下载 历史版本 已购 多账号 关注 比价"
        case .plugins: "plugin dylib deb framework 注入"
        case .fileBackups: "backup 还原 恢复 修改 删除 文件"
        case .apps: "app installed bundle id 卸载 安装列表 应用列表"
        case .profiles: "profile mobileprovision 到期 清理 签名"
        case .backups: "backup restore 存档 迁移 还原"
        case .crashes: "crash ips 分析 闪退 内存"
        case .logs: "syslog console 控制台 调试"
        case .deviceInfo: "info udid 序列号 电量 健康 容量"
        case .connection: "pairing loopback vpn 回环 网络 连接 配对"
        case .overview: "设备工具 注销 重启 桌面"
        case .processes: "process pid cpu 内存 结束进程"
        case .location: "location gps 地图 经纬度 定位"
        case .runtime: "jit 免jit 运行模式 签名 证书"
        case .developerImage: "ddi developer disk image jit 镜像 挂载 开发者"
        }
    }
    func matches(_ query: String) -> Bool {
        let haystack = [title, detail, keywords].joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { haystack.localizedCaseInsensitiveContains(String($0)) }
    }
}

enum ToolFavorites {
    static let storageKey = "RetoolsFavoriteTools"
    static let maximumCount = 6
    static let defaults: [WorkspaceTool] = [.files, .decryption, .apps, .processes]
    static var defaultValue: String { encode(defaults) }
    static func decode(_ value: String) -> [WorkspaceTool] {
        guard let bytes = value.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: bytes) else { return defaults }
        var seen = Set<WorkspaceTool>()
        let valid = ids.compactMap(WorkspaceTool.init(rawValue:)).filter { seen.insert($0).inserted }
        return ids.isEmpty ? [] : valid.isEmpty ? defaults : Array(valid.prefix(maximumCount))
    }
    static func encode(_ tools: [WorkspaceTool]) -> String {
        var seen = Set<WorkspaceTool>()
        let ids = tools.filter { seen.insert($0).inserted }.prefix(maximumCount).map(\.rawValue)
        return (try? JSONEncoder().encode(ids)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
