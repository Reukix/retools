import SwiftUI
import UniformTypeIdentifiers
import RetoolsNative

struct RenewalView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var broker = TwoFactorBroker.shared
    @AppStorage(ExpiryNotifications.enabledKey) private var expiryNotifications = true
    @AppStorage(RenewalController.pruneProfilesKey) private var pruneProfiles = true
    @State private var password = ""
    @State private var confirmForget = false
    @State private var requested = false
    @State private var successes = 0
    @State private var failures = 0

    private var settings: RenewalSettings { renewal.settings }
    private var hasAccount: Bool { settings.accounts.contains(where: \.isReady) }
    private var canRenew: Bool { hasAccount && settings.hasPairing && (!settings.packageIDs.isEmpty || settings.renewHost) }
    private var hostAccount: RenewalAccount? { settings.accounts.first { $0.id == settings.hostAccountID } ?? settings.accounts.first { $0.id == settings.defaultAccountID } }

    var body: some View {
        Form {
            Section { statusCard.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)) }
            targetsSection
            accountsSection
            Section {
                NavigationLink { RenewalConnectionView() } label: {
                    LabeledContent {
                        Text(renewal.connectionSummary).foregroundStyle(renewal.connectionVerified ? Color.green : (renewal.connectionCheckFailed ? Color.orange : Color.secondary))
                    } label: { Label("连接与验证服务", systemImage: "network") }
                }.accessibilityIdentifier("renewal.connection")
            } footer: { Text("设备配对、外部代理回环与 Anisette 验证服务。") }
            Section {
                Text(renewal.backgroundStatus).font(.footnote).foregroundStyle(.secondary)
                if let date = settings.lastAttempt { InfoRow(title: "最近尝试", value: date.formatted(date: .abbreviated, time: .shortened)) }
                if let date = settings.lastSuccess { InfoRow(title: "最近成功", value: date.formatted(date: .abbreviated, time: .shortened)) }
                if settings.failureCount > 0 { InfoRow(title: "连续失败", value: "\(settings.failureCount) 次") }
                Text(settings.lastResult).font(.footnote).textSelection(.enabled)
            } header: { Text("执行记录") }
        }
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle("Apple ID 自动续签").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
        .disabled(renewal.isWorking && broker.prompt == nil)
        .task { await renewal.verifyConnectionIfNeeded() }
        .onDisappear { renewal.save() }
        .onChange(of: renewal.settings.enabled) { _, _ in renewal.save() }
        .onChange(of: renewal.settings.renewHost) { _, _ in renewal.save() }
        .onChange(of: renewal.settings.teamID) { _, _ in renewal.save() }
        .onChange(of: renewal.isWorking) { _, working in
            guard !working, requested else { return }
            requested = false
            if renewal.errorMessage == nil, settings.lastAttemptSucceeded == true { successes += 1; store.toast = "续签完成" } else { failures += 1 }
        }
        .sensoryFeedback(.success, trigger: successes)
        .sensoryFeedback(.error, trigger: failures)
        .sheet(item: $broker.prompt) { prompt in TwoFactorSheet(prompt: prompt).disabled(false).interactiveDismissDisabled() }
        .confirmationDialog("退出 Apple ID？", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("移除本地登录会话", role: .destructive) { renewal.forgetAccount() }
        } message: { Text("仅退出当前账号。分配给它的应用需重新选择签名账号，其他账号保持登录。") }
    }

    // MARK: 状态卡

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                BrandMark(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hostAccount?.email ?? "未登录 Apple ID").font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(teamLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                ExpiryBadge(expiry: renewal.hostExpiry)
            }
            VStack(alignment: .leading, spacing: 8) {
                statusLine("calendar", title: "Retools 到期", value: renewal.hostExpiry.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "未检测到描述文件")
                statusLine("clock.arrow.circlepath", title: "下次续签", value: nextRenewalText)
                statusLine(settings.lastAttemptSucceeded == false ? "exclamationmark.triangle" : "checkmark.circle", title: "上次结果", value: lastResultText)
            }
            HStack(spacing: 8) {
                readiness("Apple ID", ok: hasAccount)
                readiness("设备配对", ok: settings.hasPairing)
                readiness("自动续签", ok: settings.enabled && renewal.autoRenewBlocker == nil)
            }
            Button { requested = true; Task { _ = await renewal.renew(force: true) } } label: {
                HStack(spacing: 8) {
                    if renewal.isWorking { ProgressView().tint(.white) } else { Image(systemName: "arrow.clockwise") }
                    Text(renewal.isWorking ? (renewal.status.isEmpty ? "正在续签…" : renewal.status) : "立即续签").lineLimit(1)
                }.font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48).foregroundStyle(.white)
                    .background(canRenew || renewal.isWorking ? AnyShapeStyle(Palette.accentGradient) : AnyShapeStyle(Color.secondary.opacity(0.35)), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }.buttonStyle(.plain).disabled(!canRenew || renewal.isWorking).accessibilityIdentifier("renewal.renewNow")
            if !canRenew, !renewal.isWorking {
                Text(missingHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.workspaceCard(padding: 18).accessibilityElement(children: .contain)
    }
    private var teamLine: String {
        guard let account = hostAccount else { return "登录后即可自动续签" }
        let team = account.teams.first { $0.id == account.teamID }
        return team.map { "\($0.name) · \($0.id)" } ?? account.teamID
    }
    private var nextRenewalText: String {
        guard settings.enabled else { return "自动续签已关闭" }
        if let blocker = renewal.autoRenewBlocker { return blocker + "，暂不会续签" }
        guard settings.renewHost else { return "按应用到期时间自动处理" }
        guard let expiry = renewal.hostExpiry else { return "打开 Retools 时检查" }
        let due = expiry.addingTimeInterval(-2 * 24 * 3600)
        if due <= Date() { return "已进入续签窗口，打开 Retools 时自动续签" }
        return due.formatted(date: .abbreviated, time: .shortened) + " 起"
    }
    private var lastResultText: String {
        guard let attempt = settings.lastAttempt else { return "尚未运行" }
        return attempt.formatted(.relative(presentation: .named)) + " · " + settings.lastResult
    }
    private var missingHint: String {
        if !hasAccount { return "先在下方登录 Apple ID。" }
        if !settings.hasPairing { return "先在下方完成设备配对，并开启外部代理回环。" }
        return "在「续签目标」中开启 Retools 自身或至少一个应用。"
    }
    private func statusLine(_ symbol: String, title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(Palette.accent).frame(width: 18)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.subheadline).multilineTextAlignment(.trailing).lineLimit(2)
        }
    }
    private func readiness(_ title: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
            Text(title).lineLimit(1).fixedSize()
        }
            .font(.caption.weight(.medium)).foregroundStyle(ok ? Color.green : Color.secondary)
            .padding(.horizontal, 9).padding(.vertical, 6).background((ok ? Color.green : Color.secondary).opacity(0.1), in: Capsule())
            .accessibilityElement(children: .combine).accessibilityLabel("\(title)：\(ok ? "已就绪" : "未完成")")
    }

    // MARK: 续签目标

    private var targetsSection: some View {
        Section {
            Toggle("自动续签", isOn: $renewal.settings.enabled).disabled(!settings.enabled && (!hasAccount || !settings.hasPairing))
            Toggle(isOn: $expiryNotifications) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("到期与续签通知")
                    Text("到期前 1 天和到期时提醒；后台续签完成或失败时通知").font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("renewal.notifications")
                .onChange(of: expiryNotifications) { _, _ in ExpiryPublisher.publish(store: store, renewal: renewal) }
            Toggle(isOn: $pruneProfiles) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("续签后清理旧描述文件")
                    Text("同一个 App ID 只保留新装的那份；删除前留副本，可在「设备工具 → 描述文件」恢复").font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("renewal.pruneProfiles")
            HStack(spacing: 12) {
                BrandMark(size: 34)
                Toggle(isOn: $renewal.settings.renewHost) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Retools 自身")
                        Text("需与当前安装同一开发者团队").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ExpiryBadge(expiry: renewal.hostExpiry)
            }
            if settings.renewHost {
                Picker("Retools 续签账号", selection: $renewal.settings.hostAccountID) {
                    Text("请选择同团队账号").tag("")
                    ForEach(settings.accounts) { account in Text(account.email).tag(account.id) }
                }
            }
            ForEach(store.state.packages.filter { !$0.isEncrypted }) { package in
                let key = package.id.uuidString
                HStack(spacing: 12) {
                    AppIcon(name: package.name, url: store.iconURL(package.iconFile), size: 34)
                    Toggle(isOn: Binding(get: { renewal.settings.packageIDs.contains(package.id) }, set: {
                        if $0 {
                            renewal.settings.packageIDs.insert(package.id)
                            if renewal.settings.packageAccounts[key] == nil { renewal.settings.packageAccounts[key] = renewal.settings.defaultAccountID }
                        } else { renewal.settings.packageIDs.remove(package.id) }
                        renewal.save()
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(package.name).lineLimit(1)
                            Text(package.signedBundleID ?? package.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if let expiry = settings.installedExpiries[key] { ExpiryBadge(expiry: expiry) }
                }
                if settings.packageIDs.contains(package.id) {
                    Picker("\(package.name) 的账号", selection: Binding(get: { renewal.settings.packageAccounts[key] ?? renewal.settings.defaultAccountID }, set: { renewal.settings.packageAccounts[key] = $0 })) {
                        Text("请选择账号").tag("")
                        ForEach(settings.accounts) { account in Text(account.email).tag(account.id) }
                    }
                }
            }
            if store.state.packages.isEmpty { Text("导入 IPA 后，可把应用加入续签队列。所选应用会签名并安装到桌面。").font(.footnote).foregroundStyle(.secondary) }
            NavigationLink { AppExpiryView() } label: { Label("查看全部有效期", systemImage: "calendar.badge.clock") }.accessibilityIdentifier("renewal.expiry")
        } header: { Text("续签目标") } footer: {
            Text("到期前 2 天自动续签；打开 Retools 时也会检查。")
        }
    }

    // MARK: 账号

    @ViewBuilder private var accountsSection: some View {
        if !settings.accounts.isEmpty {
            Section {
                ForEach(settings.accounts) { account in
                    Button { renewal.selectAccount(account.id) } label: {
                        HStack {
                            Image(systemName: settings.email == account.id ? "checkmark.circle.fill" : "person.crop.circle").foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.email).foregroundStyle(.primary)
                                Text(renewal.accountProgress[account.id] ?? account.lastResult).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }.accessibilityIdentifier("apple.account.\(account.id)")
                }
                // 与 AltStore 相同：查看每个账号已注册的 App ID（应用与扩展各占一个）及剩余名额。
                ForEach(settings.accounts.filter(\.isReady)) { account in
                    NavigationLink { AppleAppIDsView(account: account) } label: {
                        Label(settings.accounts.count > 1 ? "\(account.email) 的 App ID" : "查看 App ID", systemImage: "app.badge.checkmark")
                    }.accessibilityIdentifier("apple.appIDs.\(account.id)")
                    NavigationLink { AppleCertificatesView(account: account) } label: {
                        Label(settings.accounts.count > 1 ? "\(account.email) 的开发证书" : "开发证书", systemImage: "seal")
                    }.accessibilityIdentifier("apple.certificates.\(account.id)")
                }
                Button("添加另一个 Apple ID", systemImage: "person.badge.plus") { renewal.addAccount() }.accessibilityIdentifier("apple.addAccount")
                Picker("默认续签账号", selection: $renewal.settings.defaultAccountID) {
                    ForEach(settings.accounts) { account in Text(account.email).tag(account.id) }
                }
            } header: { Text("已登录账号 · \(settings.accounts.count)") } footer: {
                Text("可为每个续签应用指定账号。")
            }
        }
        Section {
            TextField("Apple ID", text: $renewal.settings.email).keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("apple.username")
                .disabled(!settings.teams.isEmpty)
            if settings.teams.isEmpty {
                SecureField("Apple ID 密码", text: $password).textContentType(.password).accessibilityIdentifier("apple.password")
                Button("登录 Apple ID") { renewal.login(password: password); password = "" }.disabled(password.isEmpty || settings.email.isEmpty).accessibilityIdentifier("apple.login")
            } else {
                Picker("开发者团队", selection: $renewal.settings.teamID) {
                    ForEach(settings.teams) { team in Text("\(team.name) (\(team.id))").tag(team.id) }
                }
                Button("重新登录（保留签名私钥）") {
                    renewal.settings.teams = []; renewal.settings.teamID = ""; renewal.save()
                }
                Button("退出 Apple ID", role: .destructive) { confirmForget = true }
            }
        } header: { Text(settings.accounts.isEmpty ? "登录 Apple ID" : "当前账号") } footer: {
            Text("直接连接 Apple 登录，不保存密码；会话与签名私钥存于钥匙串。")
        }
    }
}

/// 一次性配置：设备配对、回环与 Anisette 验证服务。
struct RenewalConnectionView: View {
    @EnvironmentObject private var renewal: RenewalController
    private var settings: RenewalSettings { renewal.settings }
    var body: some View {
        Form {
            Section {
                NavigationLink { AppleVerificationSettingsView() } label: {
                    LabeledContent("验证服务与诊断", value: URL(string: settings.anisetteURL)?.host ?? "自定义")
                }
                Button("检测 Apple ID 验证服务") { renewal.checkAppleService() }.accessibilityIdentifier("apple.checkService")
                Label(renewal.appleServiceResult, systemImage: renewal.appleServiceVerified ? "checkmark.circle.fill" : "network").font(.footnote).foregroundStyle(renewal.appleServiceVerified ? .green : .secondary).textSelection(.enabled).accessibilityIdentifier("apple.serviceResult")
            } header: { Text("登录辅助服务") } footer: { Text("默认使用 SideStore 的 Anisette v3 服务，也可填写自己的 HTTPS 服务。检测不提交 Apple ID 或密码；账号验证与验证码直接交给 Apple。") }
            Section {
                NavigationLink { DeviceConnectionView() } label: { Label("设备配对与连接", systemImage: "iphone.radiowaves.left.and.right") }.accessibilityIdentifier("settings.deviceConnection")
                LabeledContent("配对记录", value: settings.hasPairing ? "已保存" : "尚未配置")
                Text(renewal.deviceConnectionStatus).font(.footnote).foregroundStyle(.secondary)
            } header: { Text("外部代理的本地回环") } footer: {
                Text("外部代理提供回环。iOS 27 可在系统中配对并自动保存，也支持自动导入 Retools 文件夹中的配对记录。")
            }
        }
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle("连接与验证服务").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
    }
}

struct TwoFactorSheet: View {
    let prompt: TwoFactorBroker.TwoFactorPrompt
    @State private var code = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(prompt.text).font(.system(size: 14))
                    if !prompt.requiresMethodSelection {
                        TextField("六位验证码", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                            .onChange(of: code) { _, value in code = String(value.filter { "0123456789".contains($0) }.prefix(6)) }
                    }
                }
                if !prompt.requiresMethodSelection {
                    Section { Button("验证") { TwoFactorBroker.shared.answer(action: "code", code: code); code = "" }.disabled(code.count != 6) }
                }
                Section {
                    if !prompt.requiresMethodSelection { Button(prompt.isSMS ? "重新发送短信验证码" : "重新发送设备验证码") { TwoFactorBroker.shared.answer(action: "resend") } }
                    Button("发送到受信任设备") { TwoFactorBroker.shared.answer(action: "devices") }
                    ForEach(prompt.numbers, id: \.id) { number in Button("发送短信到 \(number.number)") { TwoFactorBroker.shared.answer(action: "sms", id: number.id) } }
                }
            }.navigationTitle("Apple ID 双重认证").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消登录") { TwoFactorBroker.shared.answer(action: "cancel") } } }
        }
    }
}
