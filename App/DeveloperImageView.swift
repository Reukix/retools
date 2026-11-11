import SwiftUI

struct DeveloperImageView: View {
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var tools = DeviceToolsStore.shared
    @AppStorage(DeveloperDiskImage.autoMountKey) private var autoMount = true
    @State private var downloaded = DeveloperDiskImage.isDownloaded()
    @State private var confirmDelete = false

    var body: some View {
        List {
            ToolPageIntro(tool: .developerImage, title: "开发服务准备", detail: "定位模拟、资源取样与 JIT 等操作使用开发者镜像。")
            Section {
                ToolMetrics(items: [("设备挂载", tools.developerImageMounted.map { $0 ? "已挂载" : "未挂载" } ?? "待检查"), ("本地镜像", downloaded ? "已下载" : "未下载")])
                if let step = tools.developerImageStep {
                    HStack(spacing: 10) { ProgressView(); Text(step).font(.subheadline) }
                }
                Button {
                    Task { await tools.mountDeveloperImage(renewal: renewal); downloaded = DeveloperDiskImage.isDownloaded() }
                } label: {
                    ToolActionLabel(title: tools.developerImageMounted == true ? "检查挂载状态" : "挂载开发者镜像", symbol: "externaldrive.badge.plus")
                }.disabled(tools.developerImageStep != nil || tools.busy != nil).accessibilityIdentifier("deviceTools.ddi.mount")
            } header: { Text("当前状态") } footer: { Text("设备重启后需要重新挂载。首次下载约 \(DeveloperDiskImage.approximateSize.byteLabel)。") }
            Section {
                Toggle("需要时自动挂载", isOn: $autoMount).accessibilityIdentifier("deviceTools.ddi.auto")
            } header: { Text("自动化") } footer: { Text("执行具体开发操作时检查并挂载，打开工具页面不会触发挂载。") }
            Section {
                NavigationLink { DeviceConnectionView() } label: {
                    Label { LabeledContent("设备配对与连接", value: renewal.connectionSummary) } icon: { Image(systemName: "network") }
                }
                ToolNotice(title: "开启开发者模式", detail: "在系统「设置 → 隐私与安全性 → 开发者模式」中开启。挂载时需要联网向 Apple 申请本机签名。", symbol: "checkmark.shield")
            } header: { Text("准备条件") }
            if downloaded {
                Section {
                    Button("删除已下载的镜像", role: .destructive) { confirmDelete = true }
                        .disabled(tools.developerImageStep != nil)
                } footer: { Text("释放本地空间，后续挂载时会重新下载。") }
            }
        }
        .toolListStyle()
        .navigationTitle("开发者镜像").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除本地开发者镜像？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除镜像", role: .destructive) { tools.deleteDownloadedDeveloperImage(); downloaded = DeveloperDiskImage.isDownloaded() }
        }
        .alert("开发者镜像", isPresented: Binding(get: { tools.errorMessage != nil }, set: { if !$0 { tools.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(tools.errorMessage ?? "") }
    }
}
