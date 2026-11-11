import SwiftUI

/// 与 AltStore 的「App ID」页相同：列出团队已注册的 App ID（每个应用和应用扩展各占一个）、
/// 对应的应用、剩余天数，以及还能注册多少个。只读，不会注册或删除。
struct AppleAppIDsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var renewal = RenewalController.shared
    let account: RenewalAccount
    @State private var list: AppleAppIDList?
    @State private var loading = false
    @State private var failure: String?

    private var isFree: Bool { list?.teamType == "free" }
    private var maximum: Int? { list?.maximum ?? (isFree ? 10 : nil) }

    var body: some View {
        List {
            if let list {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(list.appIDs.count)").font(.system(size: 40, weight: .bold, design: .rounded))
                            if let maximum { Text("/ \(maximum)").font(.title3.weight(.semibold)).foregroundStyle(Color.secondary) }
                            Spacer()
                            if let available = list.available {
                                Text("还能注册 \(max(0, available)) 个").font(.subheadline.weight(.semibold))
                                    .foregroundStyle(available > 0 ? Color.green : Color.orange)
                            }
                        }
                        if let maximum, maximum > 0 {
                            ProgressView(value: Double(min(list.appIDs.count, maximum)), total: Double(maximum)).tint(list.appIDs.count >= maximum ? .orange : Palette.accent)
                        }
                        Text(account.email + " · " + account.teamID + (isFree ? " · 免费账号" : "")).font(.caption).foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle)
                    }.padding(.vertical, 4)
                } footer: {
                    Text(isFree
                         ? "每个应用和应用扩展都需要单独的 App ID。免费账号最多同时持有 10 个，每个在注册 7 天后到期，到期后名额才会释放，不能提前删除。名额不够时，签名会只保留主应用、移除扩展。"
                         : "每个应用和应用扩展都需要单独的 App ID。")
                }
                Section {
                    if list.appIDs.isEmpty { Text("还没有注册 App ID").foregroundStyle(Color.secondary) }
                    ForEach(list.appIDs) { appID in AppleAppIDRow(appID: appID, owner: owner(of: appID.identifier)) }
                } header: { Text("App ID · \(list.appIDs.count)") }
            } else if let failure {
                Section { Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            } else {
                Section { HStack { ProgressView(); Text("正在读取 App ID…").foregroundStyle(Color.secondary) } }
            }
        }
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle("App ID").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { if loading && list != nil { ProgressView() } } }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do { list = try await renewal.appIDs(for: account); failure = nil }
        catch { failure = error.localizedDescription }
    }

    /// App ID 对应的本地应用：应用库中 Apple ID 签过的应用及其扩展，或 Retools 自身。
    private func owner(of identifier: String) -> String? {
        for package in store.state.packages {
            if let bundles = package.appleBundles, let index = bundles.firstIndex(where: { $0.bundleID == identifier }) {
                return index == 0 ? package.name : package.name + " · 扩展"
            }
            if package.signedBundleID == identifier { return package.name }
        }
        if let host = Bundle.main.bundleIdentifier, identifier == host || identifier.hasPrefix(host + ".") || identifier.hasSuffix("." + host) {
            return identifier == host ? "Retools" : "Retools · 扩展"
        }
        return nil
    }
}

private struct AppleAppIDRow: View {
    let appID: AppleAppID
    let owner: String?
    private var daysLeft: Int? {
        appID.expiresAt.map { Int(ceil($0.timeIntervalSinceNow / 86_400)) }
    }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: owner?.contains("扩展") == true ? "puzzlepiece.extension.fill" : "app.fill")
                .font(.title3).foregroundStyle(owner == nil ? Color.secondary : Palette.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(appID.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(appID.identifier).font(.caption.monospaced()).foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text(owner ?? "不是 Retools 签名的应用").font(.caption).foregroundStyle(owner == nil ? .tertiary : .secondary)
            }
            Spacer(minLength: 6)
            if let daysLeft {
                VStack(spacing: 1) {
                    Text(daysLeft <= 0 ? "已到期" : "\(daysLeft)").font(.headline.monospacedDigit()).foregroundStyle(daysLeft <= 1 ? .orange : .primary)
                    if daysLeft > 0 { Text("天").font(.caption2).foregroundStyle(Color.secondary) }
                }.frame(minWidth: 40)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(appID.name)，\(appID.identifier)" + (daysLeft.map { $0 <= 0 ? "，已到期" : "，还剩 \($0) 天" } ?? ""))
    }
}
