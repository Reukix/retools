import SwiftUI

struct DeviceConnectionView: View {
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var pairing = DevicePairingCoordinator.shared
    @State private var showImporter = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
            ToolPageIntro(tool: .connection, title: renewal.connectionVerified ? "设备连接已就绪" : "连接这台 iPhone", detail: "依次准备回环、配对和连接验证。已保存的配对记录可以继续使用。")
            Section {
                ToolMetrics(items: [("配对记录", renewal.settings.hasPairing ? "已保存" : "未配置"), ("设备服务", renewal.connectionVerified ? "已连接" : (renewal.isVerifyingConnection ? "验证中" : "待验证"))])
            }
            Section {
                Label("外部代理提供本地回环", systemImage: "network")
                Text("先在代理软件中启用 10.7.0.1 的回环映射，再为这台 iPhone 建立配对。Retools 不创建 VPN。").font(.footnote).foregroundStyle(Color.secondary)
            } header: { Text("01 · 回环通路") }
            Section {
                LabeledContent("配对记录", value: renewal.settings.hasPairing ? "已保存" : "尚未配置")
                if #available(iOS 27.0, *) {
                    Button(pairing.isRunning ? "正在配对这台 iPhone…" : (renewal.settings.hasPairing ? "重新配对这台 iPhone" : "配对这台 iPhone")) { renewal.startDevicePairing() }
                        .disabled(pairing.isRunning || renewal.isWorking).accessibilityIdentifier("device.pair")
                } else { Text("此系统可导入已有的配对文件。").font(.footnote).foregroundStyle(Color.secondary) }
                if pairing.isRunning || pairing.error != nil {
                    Text(pairing.status).font(.footnote).textSelection(.enabled)
                    if let pin = pairing.pin {
                        Text(pin).font(.system(size: 32, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        Button("复制配对码") { UIPasteboard.general.string = pin }
                    }
                    if pairing.isRunning { Button("取消配对", role: .cancel) { pairing.cancel() } }
                }
                Button { showImporter = true } label: { Label("导入已有配对文件", systemImage: "square.and.arrow.down") }
                    .disabled(pairing.isRunning || renewal.isWorking)
            } header: { Text("02 · 设备配对") } footer: { Text("系统配对完成后自动保存。放入 Retools 文件夹的单份有效配对文件也会自动导入。") }
            Section {
                HStack(spacing: 8) {
                    if renewal.isVerifyingConnection { ProgressView().controlSize(.small) }
                    else { Image(systemName: renewal.connectionVerified ? "checkmark.circle.fill" : (renewal.connectionCheckFailed ? "exclamationmark.circle" : "link")) }
                    Text(renewal.deviceConnectionStatus).textSelection(.enabled)
                }.foregroundStyle(renewal.connectionVerified ? .green : (renewal.connectionCheckFailed ? .orange : .secondary))
                Button { renewal.testConnection() } label: { ToolActionLabel(title: renewal.connectionVerified ? "重新检测连接" : "检测设备连接", symbol: "link") }.disabled(!renewal.settings.hasPairing || renewal.isWorking || pairing.isRunning).accessibilityIdentifier("device.check")
                if let port = renewal.discoveredDevicePort { LabeledContent("已使用端口", value: String(port)) }
                Text("连接前自动发现 Remote Pairing 服务，并用配对记录验证广播身份；最终通过设备服务读取身份确认连接。").font(.footnote).foregroundStyle(Color.secondary)
            } header: { Text("03 · 连接验证") }
            Section {
                DisclosureGroup("高级连接参数") {
                    TextField("回环设备 IP", text: $renewal.settings.hostIP).keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("备用 Remote Pairing 端口", value: $renewal.settings.remotePort, format: .number.grouping(.never)).keyboardType(.numberPad)
                    Text("自动发现不可用时才使用备用端口。Lockdown 配对使用相应设备服务端口。").font(.footnote).foregroundStyle(Color.secondary)
                }.disabled(renewal.isWorking || pairing.isRunning)
            }
            if renewal.isWorking { Section { HStack { ProgressView(); Text(renewal.status) } } }
        }.toolListStyle().navigationTitle("设备配对与连接").navigationBarTitleDisplayMode(.inline)
            .task { await renewal.importDiscoveredPairing(); await renewal.verifyConnectionIfNeeded() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await renewal.verifyConnectionIfNeeded() } }
            }
            .onDisappear { renewal.save() }
            .onChange(of: renewal.settings.hostIP) { _, _ in renewal.invalidateDeviceConnection() }
            .onChange(of: renewal.settings.remotePort) { _, _ in renewal.invalidateDeviceConnection() }
            .sheet(isPresented: $showImporter) {
                DocumentImportPicker(isPresented: $showImporter) { result in
                    switch result {
                    case .success(let url): renewal.importPairing(url)
                    case .failure(let error): renewal.errorTitle = "配对文件导入失败"; renewal.errorMessage = error.localizedDescription
                    }
                }
            }
    }
}
