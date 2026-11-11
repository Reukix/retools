import SwiftUI

/// 剩余有效期的显示规则：与 SideStore/AltStore 一样以天为单位，不足一天显示小时。
struct ExpiryBadgeStyle {
    let text: String
    let color: Color
    init(expiry: Date?, now: Date = Date()) {
        guard let expiry else { text = "未知"; color = .secondary; return }
        let seconds = expiry.timeIntervalSince(now)
        if seconds <= 0 { text = "已过期"; color = .red; return }
        let days = Int((seconds / 86400).rounded(.up))
        if seconds < 86400 { text = "\(max(1, Int((seconds / 3600).rounded(.up)))) 小时"; color = .red }
        else { text = "\(days) 天"; color = days <= 3 ? .orange : .green }
    }
}

/// 小号剩余天数胶囊，用在列表行里。
struct ExpiryBadge: View {
    let expiry: Date?
    var busy = false
    var action: (() -> Void)? = nil
    var body: some View {
        let style = ExpiryBadgeStyle(expiry: expiry)
        let label = HStack(spacing: 4) {
            if busy { ProgressView().controlSize(.mini).tint(style.color) }
            Text(style.text).font(.caption.weight(.bold)).monospacedDigit()
        }.foregroundStyle(style.color).padding(.horizontal, 11).padding(.vertical, 6)
            .background(style.color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(style.color.opacity(0.25), lineWidth: 1))
        if let action {
            Button(action: action) { label }.buttonStyle(.plain)
                .accessibilityLabel("剩余 \(style.text)").accessibilityHint("点按续签")
        } else { label.accessibilityLabel("剩余 \(style.text)") }
    }
}

/// SideStore 式的大号天数按钮：醒目的实心胶囊，点按续签。
struct ExpiryPill: View {
    let expiry: Date?
    var busy = false
    let action: () -> Void
    @State private var taps = 0
    var body: some View {
        let style = ExpiryBadgeStyle(expiry: expiry)
        Button { taps += 1; action() } label: {
            ZStack {
                Text(style.text).opacity(busy ? 0 : 1)
                if busy { ProgressView().controlSize(.small).tint(style.color) }
            }
            .font(.system(.subheadline, design: .rounded).weight(.heavy)).monospacedDigit()
            .foregroundStyle(style.color)
            .frame(minWidth: 72, minHeight: 34).padding(.horizontal, 10)
            .background(style.color.opacity(0.16), in: Capsule())
            .contentShape(Capsule())
        }.buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .medium), trigger: taps)
            .accessibilityLabel("剩余 \(style.text)").accessibilityHint("点按续签")
    }
}

/// Apple ID 签名并安装的应用（含 Retools 自身）。
struct SignedAppItem: Identifiable {
    let id: String
    let package: AppPackage?
    let name: String
    let version: String
    let account: String
    let expiry: Date?
    let autoRenew: Bool

    @MainActor static func all(store: WorkspaceStore, renewal: RenewalController) -> [SignedAppItem] {
        let settings = renewal.settings
        var result = [SignedAppItem(id: "host", package: nil, name: "Retools",
                                    version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                                    account: settings.hostAccountID, expiry: renewal.hostExpiry, autoRenew: settings.enabled && settings.renewHost)]
        for package in store.state.packages {
            let key = package.id.uuidString
            let installed = settings.installedExpiries[key]
            guard installed != nil || settings.packageIDs.contains(package.id) else { continue }
            result.append(SignedAppItem(id: key, package: package, name: package.name, version: package.version,
                                        account: settings.packageAccounts[key] ?? settings.defaultAccountID,
                                        expiry: installed, autoRenew: settings.enabled && settings.packageIDs.contains(package.id)))
        }
        return [result[0]] + result.dropFirst().sorted { ($0.expiry ?? .distantFuture) < ($1.expiry ?? .distantFuture) }
    }

    /// 续签单个应用；未在续签列表中的应用会先加入（使用默认账号）。
    @MainActor func refresh(with renewal: RenewalController) {
        if let package {
            if !renewal.settings.packageIDs.contains(package.id) {
                renewal.settings.packageIDs.insert(package.id)
                if renewal.settings.packageAccounts[package.id.uuidString] == nil { renewal.settings.packageAccounts[package.id.uuidString] = renewal.settings.defaultAccountID }
                renewal.save()
            }
            Task { _ = await renewal.renew(force: true, onlyPackages: [package.id], includeHost: false) }
        } else {
            // 与点按其他应用一致：点按 Retools 的天数即视为要续签它，开启自身续签。
            if !renewal.settings.renewHost { renewal.settings.renewHost = true; renewal.save() }
            Task { _ = await renewal.renew(force: true, onlyPackages: [], includeHost: true) }
        }
    }
}

/// SideStore 风格的应用卡片。
struct SignedAppCard: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var renewal = RenewalController.shared
    let item: SignedAppItem
    var busy = false
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if item.package == nil { BrandMark(size: 58) }
            else { AppIcon(name: item.name, url: store.iconURL(item.package?.iconFile), size: 58) }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.headline).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle)
                Label(footnote, systemImage: "calendar")
                    .font(.caption).foregroundStyle(Palette.tertiaryText).lineLimit(1)
            }
            Spacer(minLength: 8)
            ExpiryPill(expiry: item.expiry, busy: busy, action: refresh)
                .disabled(renewal.isWorking || store.isWorking)
                .accessibilityIdentifier("expiry.badge.\(item.id)")
        }.workspaceCard(padding: 14)
    }
    private var subtitle: String { item.version.isEmpty ? (item.autoRenew ? "自动续签" : "手动续签") : "v\(item.version) · " + (item.autoRenew ? "自动续签" : "手动续签") }
    private var footnote: String {
        guard let expiry = item.expiry else { return item.package == nil ? "未检测到描述文件" : "等待首次续签安装" }
        return "到期 " + expiry.formatted(.dateTime.month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

/// 「我的应用」区块：标题、全部续签按钮和卡片列表。应用库与有效期页共用。
struct SignedAppsSection: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var renewal = RenewalController.shared
    @State private var refreshing: String?
    @State private var successes = 0
    @State private var failures = 0
    var title = "Apple ID 签名"
    var limit: Int? = nil
    var onShowAll: (() -> Void)? = nil

    var body: some View {
        let items = SignedAppItem.all(store: store, renewal: renewal)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if let onShowAll {
                    Button(action: onShowAll) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(title).font(.title3.weight(.bold)).foregroundStyle(Color.primary)
                            Text("\(items.count)").font(.subheadline.weight(.semibold)).foregroundStyle(Color.secondary)
                            Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(Palette.tertiaryText)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("library.expiry").accessibilityHint("查看全部应用有效期")
                } else {
                    Text(title).font(.title3.weight(.bold))
                    Text("\(items.count)").font(.subheadline.weight(.semibold)).foregroundStyle(Color.secondary)
                }
                Spacer()
                Button {
                    refreshing = "all"; Task { _ = await renewal.renew(force: true) }
                } label: {
                    HStack(spacing: 5) {
                        if refreshing == "all" && renewal.isWorking { ProgressView().controlSize(.mini).tint(.white) }
                        else { Image(systemName: "arrow.clockwise") }
                        Text("全部续签")
                    }.font(.subheadline.weight(.semibold))
                }.buttonStyle(GradientCapsuleButtonStyle()).disabled(renewal.isWorking || store.isWorking)
                    .accessibilityIdentifier("expiry.refreshAll")
            }
            ForEach(limit.map { Array(items.prefix($0)) } ?? items) { item in
                SignedAppCard(item: item, busy: refreshing == item.id && renewal.isWorking) {
                    refreshing = item.id; item.refresh(with: renewal)
                }
            }
            if let limit, items.count > limit, let onShowAll {
                Button(action: onShowAll) {
                    Text("查看全部 \(items.count) 个").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 36)
                }.buttonStyle(.plain).foregroundStyle(Palette.accent)
            }
            if renewal.isWorking, !renewal.status.isEmpty {
                Label(renewal.status, systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(Color.secondary)
            }
        }
        .onChange(of: renewal.isWorking) { _, working in
            guard !working, refreshing != nil else { return }
            refreshing = nil
            if renewal.errorMessage == nil, renewal.settings.lastAttemptSucceeded == true {
                successes += 1; store.toast = "续签完成"
            } else { failures += 1 }
        }
        .sensoryFeedback(.success, trigger: successes)
        .sensoryFeedback(.error, trigger: failures)
    }
}

/// 已安装应用的有效期一览，可逐个或全部续签。
struct AppExpiryView: View {
    @ObservedObject private var renewal = RenewalController.shared
    @Environment(\.dismiss) private var dismiss
    var showsDone = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    let blocked = renewal.settings.enabled ? renewal.autoRenewBlocker : nil
                    Image(systemName: !renewal.settings.enabled ? "pause.circle.fill" : (blocked == nil ? "arrow.triangle.2.circlepath.circle.fill" : "exclamationmark.circle.fill"))
                        .font(.title2).foregroundStyle(!renewal.settings.enabled ? Color.secondary : (blocked == nil ? Palette.accent : Color.orange))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(!renewal.settings.enabled ? "自动续签已关闭" : (blocked.map { "自动续签暂停：" + $0 } ?? "自动续签已开启")).font(.subheadline.weight(.semibold))
                        Text(lastLine).font(.caption).foregroundStyle(Color.secondary).lineLimit(1)
                    }
                }.padding(.horizontal, 4)
                SignedAppsSection(title: "我的应用")
                Text("点按天数续签单个应用；续签需要已配对这台 iPhone 并开启回环代理。").font(.footnote).foregroundStyle(Color.secondary).padding(.horizontal, 4)
                // 与 AltStore「我的应用」相同的入口：查看已注册的 App ID 与剩余名额。
                ForEach(renewal.settings.accounts.filter(\.isReady)) { account in
                    NavigationLink { AppleAppIDsView(account: account) } label: {
                        HStack {
                            Label(renewal.settings.accounts.count > 1 ? "\(account.email) 的 App ID" : "查看 App ID", systemImage: "app.badge.checkmark")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Palette.tertiaryText)
                        }.contentShape(Rectangle()).workspaceCard(padding: 15)
                    }.buttonStyle(.plain).accessibilityIdentifier("expiry.appIDs.\(account.id)")
                }
            }.padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .ambientBackground()
        .navigationTitle("应用有效期").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private var lastLine: String {
        let settings = renewal.settings
        guard let attempt = settings.lastAttempt else { return "尚未运行续签" }
        return "上次 " + attempt.formatted(.relative(presentation: .named)) + " · " + (settings.lastAttemptSucceeded == false ? "未成功" : settings.lastResult)
    }
}
