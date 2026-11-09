import SwiftUI

// MARK: - 崩溃日志

struct DeviceCrashReportsView: View {
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var tools = DeviceToolsStore.shared
    @State private var onlySideloaded = true
    @State private var confirmClear = false

    /// 侧载应用的进程名（可执行文件名和显示名都算）。
    private var sideloadedProcesses: Set<String> {
        Set(tools.sideloadedApps.flatMap { [$0.executable, $0.name] }.filter { !$0.isEmpty })
    }
    private var visible: [DeviceCrashEntry] {
        onlySideloaded ? tools.crashReports.filter { sideloadedProcesses.contains($0.process) } : tools.crashReports
    }

    var body: some View {
        List {
            Section {
                Toggle("只看侧载应用", isOn: $onlySideloaded).accessibilityIdentifier("deviceTools.crash.filter")
            } footer: { Text("报告由系统生成，较旧的会被自动清理。删除后无法恢复。") }
            switch tools.crashPhase {
            case .failed(let message):
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
            case .idle, .loading where tools.crashReports.isEmpty:
                Section { HStack { ProgressView(); Text("正在读取崩溃日志…").foregroundStyle(.secondary) } }
            default:
                if visible.isEmpty {
                    ContentUnavailableView(onlySideloaded ? "侧载应用没有崩溃记录" : "没有崩溃日志", systemImage: "checkmark.shield")
                }
                let groups = Dictionary(grouping: visible, by: \.process).sorted { ($0.value.first?.date ?? .distantPast) > ($1.value.first?.date ?? .distantPast) }
                ForEach(groups, id: \.key) { process, entries in
                    Section("\(process) · \(entries.count)") {
                        ForEach(entries) { entry in
                            NavigationLink { DeviceCrashDetailView(entry: entry) } label: { DeviceCrashRow(entry: entry) }
                                .swipeActions { Button("删除", role: .destructive) { Task { await tools.removeCrashReports([entry], renewal: renewal) } } }
                        }
                    }
                }
            }
            if let busy = tools.busy { Section { HStack { ProgressView(); Text(busy) } } }
        }
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle("崩溃日志").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("清空") { confirmClear = true }.disabled(visible.isEmpty || tools.busy != nil).accessibilityIdentifier("deviceTools.crash.clear")
            }
        }
        .refreshable { await tools.loadCrashReports(renewal: renewal) }
        .task { await tools.loadCrashReports(renewal: renewal) }
        .confirmationDialog("删除这里列出的 \(visible.count) 份崩溃日志？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await tools.removeCrashReports(visible, renewal: renewal) } }
        } message: { Text("删除后无法恢复。") }
    }
}

private struct DeviceCrashRow: View {
    let entry: DeviceCrashEntry
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind == .crash ? "exclamationmark.octagon" : (entry.kind == .memory ? "memorychip" : "gauge.with.dots.needle.67percent"))
                .foregroundStyle(entry.kind == .crash ? .red : .orange).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date?.formatted(date: .abbreviated, time: .shortened) ?? entry.name).lineLimit(1)
                Text("\(entry.kindTitle) · \(entry.size.byteLabel)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DeviceCrashDetailView: View {
    let entry: DeviceCrashEntry
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var tools = DeviceToolsStore.shared
    @State private var detail: DeviceCrashDetail?
    @State private var file: URL?
    @State private var failure: String?
    @State private var showRaw = false

    var body: some View {
        List {
            if let failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
            if let detail {
                Section {
                    info("应用", detail.appName)
                    info("Bundle ID", detail.bundleID)
                    info("版本", detail.version)
                    info("系统", detail.osVersion)
                    info("时间", entry.date?.formatted(date: .abbreviated, time: .standard) ?? "")
                }
                if !detail.exception.isEmpty || !detail.termination.isEmpty {
                    Section("原因") {
                        if !detail.exception.isEmpty { Text(detail.exception).font(.callout.monospaced()).textSelection(.enabled) }
                        if !detail.termination.isEmpty { Text(detail.termination).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                if !detail.frames.isEmpty {
                    Section("崩溃线程 \(detail.crashedThread.map(String.init) ?? "")") {
                        ForEach(Array(detail.frames.enumerated()), id: \.offset) { _, frame in
                            Text(frame).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                        }
                    }
                }
                Section {
                    DisclosureGroup("完整报告", isExpanded: $showRaw) {
                        Text(detail.text.prefix(60_000)).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
            } else if failure == nil {
                HStack { ProgressView(); Text("正在读取…").foregroundStyle(.secondary) }
            }
        }
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle(entry.process).navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
        .toolbar {
            if let file { ToolbarItem(placement: .primaryAction) { ShareLink(item: file) { Image(systemName: "square.and.arrow.up") } } }
        }
        .task {
            guard detail == nil else { return }
            do { let result = try await tools.crashDetail(entry, renewal: renewal); detail = result.detail; file = result.file }
            catch { failure = "无法读取：\(error.localizedDescription)" }
        }
    }

    @ViewBuilder private func info(_ title: String, _ value: String) -> some View {
        if !value.isEmpty { LabeledContent(title) { Text(value).font(.footnote).multilineTextAlignment(.trailing).textSelection(.enabled) } }
    }
}

// MARK: - 实时日志

struct DeviceLogConsoleView: View {
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var logs = DeviceLogStore.shared
    @ObservedObject private var tools = DeviceToolsStore.shared
    @State private var follow = true
    @State private var share: SigningProjectShare?

    var body: some View {
        let lines = logs.visible
        VStack(spacing: 0) {
            filterBar
            if let failure = logs.failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    .padding(.horizontal).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollViewReader { proxy in
                List(lines) { line in DeviceLogRow(line: line).listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)) }
                    .listStyle(.plain)
                    .overlay {
                        if lines.isEmpty {
                            ContentUnavailableView(logs.isRunning ? "等待日志…" : "实时日志", systemImage: "text.alignleft",
                                                   description: Text(logs.isRunning ? "有新日志时会显示在这里。" : "点右上角开始，读取这台 iPhone 的系统与应用日志。"))
                        }
                    }
                    .onChange(of: lines.last?.id) { _, id in
                        guard follow, !logs.paused, let id else { return }
                        proxy.scrollTo(id, anchor: .bottom)
                    }
            }
            statusBar(count: lines.count)
        }
        .background(AmbientBackground())
        .navigationTitle("实时日志").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Toggle("自动滚动到最新", isOn: $follow)
                    Button { if let url = try? logs.export() { share = SigningProjectShare(urls: [url]) } } label: { Label("导出当前结果", systemImage: "square.and.arrow.up") }
                        .disabled(lines.isEmpty)
                    Button(role: .destructive) { logs.clear() } label: { Label("清空", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
                Button { logs.isRunning ? logs.stop() : logs.start(renewal: renewal) } label: {
                    Image(systemName: logs.isRunning ? "stop.fill" : "play.fill")
                }.accessibilityIdentifier("deviceTools.logs.toggle")
            }
        }
        .sheet(item: $share) { SigningProjectShareSheet(urls: $0.urls) }
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("筛选内容、进程或子系统", text: $logs.query).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !logs.query.isEmpty { Button { logs.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
            }
            .padding(.horizontal, 12).padding(.vertical, 9).background(.thinMaterial, in: Capsule())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("仅错误", selected: logs.errorsOnly) { logs.errorsOnly.toggle() }
                    Menu {
                        Button("全部进程") { logs.process = nil }
                        let sideloaded = tools.sideloadedApps.map(\.executable).filter { !$0.isEmpty }
                        if !sideloaded.isEmpty {
                            Section("侧载应用") { ForEach(sideloaded, id: \.self) { name in Button(name) { logs.process = name } } }
                        }
                        Section("最近出现") { ForEach(logs.processes.prefix(20), id: \.self) { name in Button(name) { logs.process = name } } }
                    } label: { chipLabel(logs.process ?? "全部进程", selected: logs.process != nil, symbol: "chevron.down") }
                    chip(logs.paused ? "继续显示" : "暂停显示", selected: logs.paused) { logs.paused.toggle() }
                }
            }
        }.padding(.horizontal).padding(.vertical, 8)
    }

    private func statusBar(count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(logs.isRunning ? (logs.paused ? Color.orange : Color.green) : Color.secondary).frame(width: 7, height: 7)
            Text(logs.isRunning ? (logs.paused ? "已暂停显示" : "正在接收") : "未连接")
            Spacer()
            Text("显示 \(count) / \(logs.lines.count) 条" + (logs.dropped > 0 ? "，跳过 \(logs.dropped)" : "")).monospacedDigit()
        }
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 8).bottomBarBackground()
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, selected: selected, symbol: nil) }.buttonStyle(.plain)
    }
    private func chipLabel(_ title: String, selected: Bool, symbol: String?) -> some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            if let symbol { Image(systemName: symbol).font(.caption2.weight(.bold)) }
        }
        .font(.footnote.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 6)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.thinMaterial), in: Capsule())
    }
}

private struct DeviceLogRow: View {
    let line: DeviceLogLine
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(line.date.formatted(.dateTime.hour().minute().second())).monospacedDigit()
                Text(line.process).fontWeight(.semibold).lineLimit(1)
                if line.level != 0 { Text(line.levelTitle).foregroundStyle(line.isError ? .red : .secondary) }
                if !line.subsystem.isEmpty { Text(line.subsystem).foregroundStyle(.tertiary).lineLimit(1) }
            }.font(.caption2).foregroundStyle(.secondary)
            Text(line.message).font(.caption.monospaced()).foregroundStyle(line.isError ? Color.red : Color.primary).lineLimit(8).textSelection(.enabled)
        }
    }
}
