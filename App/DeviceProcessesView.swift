import SwiftUI
import IdeviceGateway

/// 正在运行的进程；CPU、内存采样与解除内存上限需要开发者镜像。
struct DeviceProcessesView: View {
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var tools = DeviceToolsStore.shared
    @AppStorage("RetoolsProcessesAppsOnly") private var appsOnly = true
    @State private var sort = Sort.memory
    @State private var query = ""
    @State private var pendingKill: DeviceProcessInfo?
    @State private var notice: String?

    enum Sort: String, CaseIterable, Identifiable {
        case memory = "内存", cpu = "CPU", name = "名称"
        var id: String { rawValue }
    }

    private var visible: [DeviceProcessInfo] {
        let filtered = tools.processes.filter { process in
            guard !appsOnly || process.isApplication else { return false }
            guard !query.isEmpty else { return true }
            let label = tools.label(for: process)
            return label.title.localizedCaseInsensitiveContains(query) || (label.detail?.localizedCaseInsensitiveContains(query) ?? false)
                || process.executablePath.localizedCaseInsensitiveContains(query) || "\(process.pid)" == query
        }
        switch sort {
        case .memory: return filtered.sorted { ($0.memory ?? -1) > ($1.memory ?? -1) }
        case .cpu: return filtered.sorted { ($0.cpu ?? -1) > ($1.cpu ?? -1) }
        case .name: return filtered.sorted { tools.label(for: $0).title.localizedStandardCompare(tools.label(for: $1).title) == .orderedAscending }
        }
    }

    var body: some View {
        List {
            ToolPageIntro(tool: .processes, title: "运行中的进程", detail: "按资源占用排序，点开进程持续监控 CPU 与内存。")
            Section {
                ToolMetrics(items: [("当前显示", "\(visible.count)"), ("占用数据", tools.loadingProcessUsage ? "更新中" : (tools.processes.contains { $0.memory != nil } ? "已采样" : "未采样"))])
                Toggle("只看应用", isOn: $appsOnly)
                Picker("排序", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            }
            if let notice { Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green).font(.footnote) } }
            if case .failed(let message) = tools.processPhase {
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
            }
            if tools.processes.isEmpty, tools.processPhase == .idle || tools.processPhase == .loading {
                Section { HStack { ProgressView(); Text(tools.developerImageStep ?? "正在读取进程…").foregroundStyle(Color.secondary) } }
            } else {
                Section {
                    ForEach(visible) { process in
                        NavigationLink { DeviceProcessDetailView(process: process) } label: { row(process) }
                            .accessibilityIdentifier("deviceTools.process.\(process.pid)")
                            .swipeActions { Button("结束", role: .destructive) { pendingKill = process } }
                            .contextMenu {
                                Button { Task { if await tools.liftMemoryLimit(process, renewal: renewal) { notice = "系统已确认解除「\(tools.label(for: process).title)」的内存上限，持续到它退出。点进去可以实时查看内存。" } } } label: {
                                    Label("解除内存上限", systemImage: "memorychip")
                                }
                                Button(role: .destructive) { pendingKill = process } label: { Label("结束进程", systemImage: "xmark.octagon") }
                                Button { UIPasteboard.general.string = "\(process.pid)" } label: { Label("复制 PID", systemImage: "doc.on.doc") }
                            }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if tools.loadingProcessUsage {
                            HStack { ProgressView(); Text("正在更新 CPU／内存…") }
                                .accessibilityIdentifier("processes.loadingUsage")
                        }
                        if let note = tools.usageNote {
                            Text(note).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        Text("共 \(visible.count) 个\(appsOnly ? "应用" : "进程")。点进去可以实时查看占用；长按可以解除内存上限：系统不再因为内存占用过高而结束它，适合模拟器、游戏类应用。")
                    }
                }
            }
            if visible.isEmpty, tools.processPhase == .ready {
                ContentUnavailableView("没有匹配的进程", systemImage: "cpu", description: Text("尝试搜索其他名称，或关闭「只看应用」。"))
            }
            if let busy = tools.busy { Section { HStack { ProgressView(); Text(busy) } } }
        }
        .searchable(text: $query, prompt: "名称或 PID")
        .toolListStyle()
        .navigationTitle("进程").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await tools.loadProcesses(renewal: renewal) } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(tools.processPhase == .loading)
            }
        }
        .refreshable { await tools.loadProcesses(renewal: renewal) }
        .task {
            await tools.loadProcesses(renewal: renewal)
            await tools.loadApps(renewal: renewal)
            let ids = Set(tools.processes.compactMap { tools.label(for: $0).bundleID })
            await tools.loadIcons(for: (tools.apps + tools.systemApps).filter { ids.contains($0.bundleID) }, renewal: renewal)
        }
        .modifier(DeviceProcessAlert(pending: $pendingKill, tools: tools) { process in
            Task {
                if await tools.kill(process, renewal: renewal) {
                    notice = "已结束「\(tools.label(for: process).title)」（PID \(process.pid)）。"
                }
            }
        })
    }

    private func row(_ process: DeviceProcessInfo) -> some View {
        let label = tools.label(for: process)
        return HStack(spacing: 12) {
            DeviceProcessIcon(label: label)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(label.title).font(.body.weight(.medium)).lineLimit(1)
                    if let detail = label.detail { Text(detail).font(.caption).foregroundStyle(Color.secondary).lineLimit(1) }
                    if tools.liftedLimits[process.pid] != nil { StatusPill(title: "已解除上限", color: .green) }
                }
                HStack(spacing: 10) {
                    if let memory = process.memory { Text(memory.byteLabel).foregroundStyle(memory > 1_000_000_000 ? .orange : .secondary) }
                    if let cpu = process.cpu { Text(String(format: "CPU %.1f%%", cpu)).foregroundStyle(cpu > 50 ? .orange : .secondary) }
                    Text(DeviceProcessIcon.kindTitle(label.kind))
                }.font(.caption.monospacedDigit()).foregroundStyle(Color.secondary)
            }
        }
    }
}

/// 单个进程：每 3 秒读取一次 CPU 和内存，记录峰值；用来确认解除内存上限是否生效。
struct DeviceProcessDetailView: View {
    let process: DeviceProcessInfo
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var tools = DeviceToolsStore.shared
    @State private var usage: DeviceProcessUsage?
    @State private var peak: Int64 = 0
    @State private var samples: [Int64] = []
    @State private var exited = false
    @State private var failure: String?
    @State private var pendingKill: DeviceProcessInfo?

    private var lifted: Date? { tools.liftedLimits[process.pid] }

    var body: some View {
        List {
            Section {
                let label = tools.label(for: process)
                HStack(spacing: 14) {
                    DeviceProcessIcon(label: label, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label.title).font(.headline)
                        Text([DeviceProcessIcon.kindTitle(label.kind), label.detail].compactMap { $0 }.joined(separator: " · ")).font(.subheadline).foregroundStyle(Color.secondary)
                    }
                }.padding(.vertical, 4)
                LabeledContent("PID", value: "\(process.pid)")
                if !process.executablePath.isEmpty {
                    LabeledContent("路径") { Text(process.executablePath).font(.caption.monospaced()).multilineTextAlignment(.trailing).textSelection(.enabled) }
                }
                LabeledContent("状态") {
                    Text(exited ? "已退出" : "运行中").foregroundStyle(exited ? .red : .green)
                        .accessibilityIdentifier("process.status")
                }
            }
            Section {
                LabeledContent("CPU", value: usage?.cpu.map { String(format: "%.1f%%", $0) } ?? "—")
                LabeledContent("内存", value: usage?.memory.map(\.byteLabel) ?? "—")
                LabeledContent("监控期间峰值", value: peak > 0 ? peak.byteLabel : "—")
                if samples.count > 1 { MemorySparkline(values: samples).frame(height: 54).padding(.vertical, 4) }
                if let failure { Text(failure).font(.footnote).foregroundStyle(.orange) }
            } header: { Text("实时占用（每 3 秒）") }
            Section {
                if let lifted {
                    Label("已解除内存上限，系统已确认", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("解除于 " + lifted.formatted(date: .omitted, time: .shortened) + "，持续到这个进程退出。").font(.caption).foregroundStyle(Color.secondary)
                } else {
                    Button { Task { _ = await tools.liftMemoryLimit(process, renewal: renewal) } } label: { Label("解除内存上限", systemImage: "memorychip") }
                        .disabled(exited || tools.busy != nil).accessibilityIdentifier("process.liftLimit")
                }
            } header: { Text("内存上限") } footer: {
                Text("系统收到请求后会回复是否接受，显示「系统已确认」就表示它接受了。系统没有提供读取当前上限的接口，所以可以这样验证效果：让应用继续使用，看这里的内存。占用涨到平时会闪退的程度（同类应用通常在 2～3 GB 以上）后应用仍然运行，就说明解除生效了。")
            }
            if !exited {
                Section {
                    Button("结束进程", role: .destructive) { pendingKill = process }
                        .disabled(tools.busy != nil).accessibilityIdentifier("process.terminate")
                }
            }
        }
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle(tools.label(for: process).title).navigationBarTitleDisplayMode(.inline)
        .task { await monitor() }
        .modifier(DeviceProcessAlert(pending: $pendingKill, tools: tools) { target in
            Task {
                if await tools.kill(target, renewal: renewal) { exited = true; usage = nil; failure = nil }
            }
        })
    }

    private func monitor() async {
        usage = DeviceProcessUsage(cpu: process.cpu, memory: process.memory)
        if let memory = process.memory { peak = memory; samples = [memory] }
        while !Task.isCancelled, !exited {
            do {
                if let value = try await tools.usage(of: process.pid, renewal: renewal) {
                    usage = value; failure = nil
                    if let memory = value.memory { peak = max(peak, memory); samples = Array((samples + [memory]).suffix(60)) }
                } else {
                    exited = true
                    if lifted != nil { failure = "进程已经退出。如果是在内存上涨时退出的，说明解除没有生效，或者它触到了整机内存的极限。" }
                }
            } catch is DeviceToolsBusy {
                // 上一次读取还没返回，这一轮跳过。
            } catch { failure = "读取失败：\(error.localizedDescription)" }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}

/// A centered system alert avoids anchoring a destructive confirmation to the scrolled list.
/// The same presenter keeps service failures visible on the detail page.
private struct DeviceProcessAlert: ViewModifier {
    @Binding var pending: DeviceProcessInfo?
    @ObservedObject var tools: DeviceToolsStore
    let terminate: (DeviceProcessInfo) -> Void

    func body(content: Content) -> some View {
        let target = pending
        content.alert(target.map { "结束「\(tools.label(for: $0).title)」？" } ?? "进程", isPresented: Binding(
            get: { pending != nil || tools.errorMessage != nil },
            set: { if !$0 { pending = nil; tools.errorMessage = nil } }
        )) {
            if let target {
                Button("结束进程", role: .destructive) { terminate(target) }
                Button("取消", role: .cancel) {}
            } else {
                Button("好", role: .cancel) {}
            }
        } message: {
            if let target {
                Text(target.isApplication ? "应用里没有保存的内容会丢失。"
                     : "这是系统进程，结束后系统通常会自动重新启动它；个别进程被结束可能导致手机短暂卡顿或注销。")
            } else { Text(tools.errorMessage ?? "") }
        }
    }
}

/// 内存走势的简单折线。
private struct MemorySparkline: View {
    let values: [Int64]
    var body: some View {
        GeometryReader { geometry in
            let high = Double(values.max() ?? 1), low = Double(values.min() ?? 0)
            let span = max(high - low, high * 0.05, 1)
            Path { path in
                for (index, value) in values.enumerated() {
                    let x = geometry.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                    let y = geometry.size.height * (1 - CGFloat((Double(value) - low) / span))
                    index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
            }.stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

/// 进程图标：对应到已安装应用时用应用图标（扩展加一个角标），否则用系统符号。
struct DeviceProcessIcon: View {
    let label: DeviceProcessLabel
    var size: CGFloat = 34

    static func kindTitle(_ kind: DeviceProcessLabel.Kind) -> String {
        switch kind { case .app: "应用"; case .appExtension: "扩展"; case .systemApp: "系统应用"; case .daemon: "后台进程" }
    }

    var body: some View {
        Group {
            if let bundleID = label.bundleID {
                DeviceAppIcon(bundleID: bundleID, size: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).fill(.quaternary)
                    .overlay { Image(systemName: label.kind == .daemon ? "gearshape" : "app").font(.system(size: size * 0.45)).foregroundStyle(Color.secondary) }
                    .frame(width: size, height: size)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if label.kind == .appExtension {
                Image(systemName: "puzzlepiece.extension.fill").font(.system(size: size * 0.32)).foregroundStyle(.white)
                    .padding(2).background(Palette.accent, in: Circle()).offset(x: 3, y: 3)
            }
        }
    }
}
