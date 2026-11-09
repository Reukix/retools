import SwiftUI
import ContainerControls
import RetoolsNative

@main
struct RetoolsApp: App {
    @UIApplicationDelegateAdaptor(RetoolsAppDelegate.self) private var appDelegate
    @StateObject private var store = WorkspaceStore.shared
    @StateObject private var renewal = RenewalController.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var handledLaunchAction = false
    var body: some Scene {
        WindowGroup {
            WorkspaceRoot().environmentObject(store).environmentObject(renewal).tint(Palette.accent)
                .onOpenURL { store.handleURL($0) }
                .task {
                    DocumentImportPicker.discardPicked()
                    DeviceToolsStore.discardDownloads()
                    LocalFileAccessService.discardExports()
                    renewal.attach(store)
                    SigningMigrationController.shared.inspect()
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--preview-controls") { RetoolsContainerControls.showPreview() }
                    #endif
                    installDock()
                    if !SigningMigrationController.shared.needsRecovery, await store.handleContainerControl() { return }
                    let arguments = ProcessInfo.processInfo.arguments
                    if !handledLaunchAction, arguments.contains("--open-decryption") {
                        handledLaunchAction = true; store.selectedTab = .library; store.showDecryption = true; return
                    }
                    if !handledLaunchAction, arguments.contains("--check-store-setup") || arguments.contains("--check-store-device-auth") {
                        handledLaunchAction = true
                        store.isWorking = true; store.workLabel = "正在验证商店组件与公开握手…"
                        UIApplication.shared.isIdleTimerDisabled = true
                        defer { store.isWorking = false; store.workLabel = ""; UIApplication.shared.isIdleTimerDisabled = false }
                        let deviceAuth = arguments.contains("--check-store-device-auth")
                        let path = store.paths.support.appendingPathComponent(deviceAuth ? "StoreDeviceAuthCheck.json" : "StoreSetupCheck.json")
                        var report: [String: Any] = ["checkedAt": Date().timeIntervalSince1970, "accountLoginAttempted": false, "phase": "running"]
                        try? JSONSerialization.data(withJSONObject: report,options: [.sortedKeys]).write(to: path,options: .atomic)
                        let progressTask = Task { @MainActor in
                            while !Task.isCancelled {
                                report["stage"] = StoreDownloadService.progress()
                                report["updatedAt"] = Date().timeIntervalSince1970
                                try? JSONSerialization.data(withJSONObject: report,options: [.sortedKeys]).write(to: path,options: .atomic)
                                try? await Task.sleep(for: .seconds(1))
                            }
                        }
                        defer { progressTask.cancel() }
                        do {
                            if deviceAuth { try await StoreDownloadService().verifyDeviceAuth() }
                            else { try await StoreDownloadService().verifySetup() }
                            report["phase"] = "complete"
                        }
                        catch { report["phase"] = "failed"; report["error"] = error.localizedDescription }
                        try? JSONSerialization.data(withJSONObject: report,options: [.sortedKeys]).write(to: path,options: .atomic)
                        return
                    }
                    if !handledLaunchAction, arguments.contains("--check-store-engine") {
                        handledLaunchAction = true
                        var report: [String: Any] = ["checkedAt": Date().timeIntervalSince1970, "accountLoginAttempted": false, "jitEnabled": RTNative.isJITEnabled()]
                        do {
                            try await StoreDownloadService().probe()
                            report["interpreterPassed"] = true
                            let apps = try await AppStoreCatalog.search("com.atebits.Tweetie2",country: "us",lookup: true)
                            report["publicCatalogFoundX"] = apps.contains { $0.bundleID == "com.atebits.Tweetie2" }
                            report["phase"] = "complete"
                        } catch { report["phase"] = "failed"; report["error"] = error.localizedDescription }
                        try? JSONSerialization.data(withJSONObject: report,options: [.sortedKeys]).write(to: store.paths.support.appendingPathComponent("StoreEngineCheck.json"),options: .atomic)
                        return
                    }
                    if !handledLaunchAction, arguments.contains("--check-installed-decryption-source") {
                        handledLaunchAction = true
                        await InstalledDecryptionSource.checkX(renewal: renewal, reportURL: store.paths.support.appendingPathComponent("InstalledDecryptionSourceCheck.json"))
                        return
                    }
                    if !handledLaunchAction, arguments.contains("--check-desktop-restart-support") {
                        handledLaunchAction = true
                        var report: [String: Any] = ["checkedAt": Date().timeIntervalSince1970, "terminatingSignalSent": false]
                        do {
                            let target = try await DeviceToolsStore.shared.inspectDesktopRestart(renewal: renewal)
                            report["allowed"] = true; report["pid"] = target.pid
                        } catch { report["allowed"] = false; report["error"] = error.localizedDescription }
                        do {
                            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: store.paths.support.appendingPathComponent("DesktopRestartSupport.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                        } catch { store.errorMessage = error.localizedDescription }
                        return
                    }
                    if !handledLaunchAction, arguments.contains("--check-process-reading") {
                        handledLaunchAction = true
                        await DeviceToolsStore.shared.checkProcessReading(renewal: renewal, report: store.paths.support.appendingPathComponent("ProcessReadingCheck.json"))
                        return
                    }
                    if !handledLaunchAction, arguments.contains("--renew-now") {
                        handledLaunchAction = true
                        _ = await renewal.renew(force: true)
                        return
                    }
                    let environmentAction = getenv("RETOOLS_PREPARE_DEVELOPMENT").map { String(cString: $0) } == "1"
                    if !handledLaunchAction, arguments.contains("--prepare-development-signing") || environmentAction {
                        handledLaunchAction = true
                        let index = arguments.firstIndex(of: "--signing-account")
                        let accountID = getenv("RETOOLS_SIGNING_ACCOUNT").map { String(cString: $0) } ?? index.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
                        unsetenv("RETOOLS_PREPARE_DEVELOPMENT"); unsetenv("RETOOLS_SIGNING_ACCOUNT")
                        AuthDiagnostics.record(stage: "开发签名", message: "收到本机开发工具的开发签名准备请求")
                        store.selectedTab = .settings; store.showDevelopmentSigning = true
                        renewal.prepareDevelopmentSigning(accountID: accountID, includeAppGroup: arguments.contains("--with-app-group"))
                    }
                    if !handledLaunchAction, arguments.contains("--check-app-group") {
                        handledLaunchAction = true
                        store.selectedTab = .settings; store.showDevelopmentSigning = true
                        let status: HostAppGroup.Status
                        if let group = HostAppGroup.signedIdentifier() {
                            status = await Task.detached { HostAppGroup.check(group: group) }.value
                        } else { status = HostAppGroup.inspect() }
                        do {
                            let data = try JSONEncoder().encode(status)
                            try data.write(to: store.paths.support.appendingPathComponent("AppGroupCheck.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                        } catch { store.errorMessage = error.localizedDescription }
                    }
                }
                .onChange(of: store.state.containerApps) { _, _ in installDock() }
                .onChange(of: store.state.packages) { _, _ in ExpiryPublisher.publish(store: store, renewal: renewal) }
                .onChange(of: store.isWorking) { _, busy in if !busy { RetoolsContainerControls.finishWorkbenchRequest() } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await AppSourceStore.shared.refreshIfStale() }
                        Task { await DeviceToolsStore.shared.autoMountOnLaunch(renewal: renewal) }
                        ExpiryPublisher.publish(store: store, renewal: renewal)
                        renewal.attach(store); SigningMigrationController.shared.inspect()
                        installDock()
                        if !SigningMigrationController.shared.needsRecovery {
                            Task { if !(await store.handleContainerControl()) { renewal.foregroundCheck() } }
                        }
                    } else if phase == .background {
                        DeviceToolsStore.shared.appDidEnterBackground()
                        DeviceLogStore.shared.appDidEnterBackground()
                        if renewal.isWorking { AuthDiagnostics.record(stage: "后台续签", message: "当前续签任务已进入后台，继续执行签名与安装") }
                    }
                }
        }
    }
    private func installDock() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-controls") { return }
        #endif
        guard !store.state.containerApps.isEmpty else { return }
        RetoolsContainerControls.installWorkbench(hostRoot: NSHomeDirectory(), defaults: .standard) {
            Task { await store.handleContainerControl(); if !store.isWorking { RetoolsContainerControls.finishWorkbenchRequest() } }
        }
    }
}

struct WorkspaceRoot: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var migration = SigningMigrationController.shared
    @ObservedObject private var sources = AppSourceStore.shared
    @AppStorage("RetoolsAIEnabled") private var aiEnabled = false
    var body: some View {
        TabView(selection: $store.selectedTab) {
            LibraryView().tag(WorkspaceTab.library).tabItem { Label("应用库", systemImage: "square.grid.2x2") }
            if aiEnabled { AIChatView().tag(WorkspaceTab.chat).tabItem { Label("AI", systemImage: "bubble.left.and.bubble.right") } }
            ContainersView().tag(WorkspaceTab.containers).tabItem { Label("容器", systemImage: "shippingbox") }
            // 每个标签图标都有实心版本，选中与未选中时粗细一致。
            SettingsView().tag(WorkspaceTab.settings).tabItem { Label("设置", systemImage: "gearshape") }
        }
        .onChange(of: aiEnabled) { _, enabled in
            if !enabled { AIChatStore.stopIfLoaded(); if store.selectedTab == .chat { store.selectedTab = .settings } }
        }
        .overlay {
            if store.isWorking, !store.workLabel.isEmpty, store.signingProgress == nil {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large).tint(Palette.accent)
                        Text(store.workLabel).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                        if renewal.isWorking, !renewal.activeAccounts.isEmpty {
                            RenewalAccountsProgress(renewal: renewal)
                        } else {
                            Text("大体积应用可能需要一点时间").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(26).frame(maxWidth: 360).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous)).padding(24)
                }.accessibilityIdentifier("workspace.progress")
            }
        }
        // 提示放在底部、标签栏上方：放在顶部会正好盖住导航栏标题（例如「证书管理」）。
        .overlay(alignment: .bottom) {
            ZStack {
                if let message = store.toast {
                    Label(message, systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .medium))
                        .symbolRenderingMode(.multicolor)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: message) { try? await Task.sleep(for: .seconds(3)); if store.toast == message { store.toast = nil } }
                }
            }
            .padding(.bottom, 76).allowsHitTesting(false)
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: store.toast)
        }
        .confirmationDialog("运行容器应用？", isPresented: Binding(get: { store.pendingExternalLaunch != nil }, set: { if !$0 { store.pendingExternalLaunch = nil } }), titleVisibility: .visible, presenting: store.pendingExternalLaunch) { app in
            Button("运行「\(app.name)」") { store.pendingExternalLaunch = nil; store.launch(app) }
            Button("取消", role: .cancel) { store.pendingExternalLaunch = nil }
        } message: { _ in Text("此请求来自外部链接。运行会重启 Retools 并进入该应用。") }
        .alert("软件源", isPresented: Binding(get: { sources.message != nil }, set: { if !$0 { sources.message = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(sources.message ?? "") }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .task { store.refreshStorage(); migration.inspect() }
        .sheet(isPresented: $migration.needsRecovery) { SigningRecoveryView() }
        .alert(renewal.errorTitle, isPresented: Binding(get: { renewal.errorMessage != nil }, set: { if !$0 { renewal.errorMessage = nil } }), presenting: renewal.errorMessage) { _ in
            Button("知道了", role: .cancel) { renewal.errorMessage = nil }
        } message: { Text($0) }
    }
}

/// 多账号续签时，每个账号一行：头像、当前步骤与状态（进行中 / 完成 / 有失败）。
struct RenewalAccountsProgress: View {
    @ObservedObject var renewal: RenewalController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let done = renewal.activeAccounts.filter { renewal.accountOutcome[$0] != nil }.count
            Text(renewal.activeAccounts.count > 1 ? "\(renewal.activeAccounts.count) 个账号同时准备，安装逐个进行 · 已完成 \(done)" : "续签进度")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(renewal.activeAccounts, id: \.self) { id in
                HStack(spacing: 10) {
                    Text(String(id.prefix(1)).uppercased()).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(Palette.accentGradient, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(id).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        Text(renewal.accountProgress[id] ?? "等待开始…").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 6)
                    switch renewal.accountOutcome[id] {
                    case .some(true): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .some(false): Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    case .none: ProgressView().controlSize(.small)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
