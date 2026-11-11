import Foundation
import SwiftUI
import RetoolsNative

struct DevelopmentSigningManifest: Codable {
    let bundleID: String
    let build: String
    let targetTeam: String
    let backupID: UUID
    let getTaskAllow: Bool
    var appGroup: String? = nil
    static func provisioningIdentifier(in bundle: URL, team: String) -> String? {
        guard let raw = try? Data(contentsOf: bundle.appendingPathComponent("embedded.mobileprovision")),
              let payload = try? RTNative.profilePayload(raw),
              let values = try? PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any],
              let id = (values["Entitlements"] as? [String: Any])?["application-identifier"] as? String,
              let bundleID = (try? ArchiveService.metadata(at: bundle))?["CFBundleIdentifier"] as? String,
              id == team + "." + bundleID else { return nil }
        return bundleID
    }
}

struct DevelopmentSigningView: View {
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var migration = SigningMigrationController.shared
    @State private var accountID = ""
    @State private var includeAppGroup = true
    @State private var groupStatus = HostAppGroup.inspect()
    @State private var checkingGroup = false
    var body: some View {
        Form {
            Section {
                LabeledContent("安装标识", value: "dev.retools.ios")
                LabeledContent("需要权限", value: "get-task-allow")
                Picker("Apple ID", selection: $accountID) {
                    Text("请选择账号").tag("")
                    ForEach(renewal.settings.accounts.filter(\.isReady)) { account in Text(account.email).tag(account.id) }
                }.disabled(renewal.isWorking)
                Toggle("申请 App Group", isOn: $includeAppGroup).disabled(renewal.isWorking)
                    .accessibilityIdentifier("development.appGroup")
                Button("准备 Apple ID 开发签名") { renewal.prepareDevelopmentSigning(accountID: accountID, includeAppGroup: includeAppGroup) }.disabled(accountID.isEmpty || renewal.isWorking)
                Text(renewal.developmentStatus).font(.footnote).textSelection(.enabled)
            } footer: { Text("使用所选 Apple ID 获取开发证书和描述文件。开启 App Group 时，为主应用申请独立共享容器，安装后生效；应用数据继续保存在私有沙盒。换团队时请保存恢复码，安装后粘贴恢复。") }
            Section {
                Text(groupStatus.message).accessibilityIdentifier("development.appGroupStatus")
                if let group = groupStatus.group {
                    Text(group).font(.caption.monospaced()).textSelection(.enabled)
                    Button {
                        checkingGroup = true
                        Task {
                            groupStatus = await Task.detached { HostAppGroup.check(group: group) }.value
                            checkingGroup = false
                        }
                    } label: {
                        if checkingGroup { ProgressView() } else { Text("检测 App Group 读写") }
                    }.disabled(checkingGroup || renewal.isWorking)
                }
            } header: { Text("当前安装的 App Group") } footer: {
                Text("检测只读写专用组中的临时文件，不会联系 Apple。没有组授权时仍可使用原有功能。")
            }
            if let ipa = renewal.developmentIPA {
                Section {
                    Button("复制签名资料恢复码") {
                        do { try migration.copyRecoveryCode() }
                        catch { renewal.errorMessage = error.localizedDescription }
                    }.accessibilityIdentifier("development.copyRecovery")
                    Text(migration.result.isEmpty ? "换签名团队前，请先复制恢复码并保存在自己的密码管理器中。开发版首次打开时粘贴恢复账号、证书密码和设备配对。" : migration.result).font(.footnote).foregroundStyle(Color.secondary)
                    ShareLink("导出开发签名 IPA", item: ipa)
                } header: { Text("签名包已准备") }
            }
            if renewal.isWorking { ProgressView() }
        }.scrollContentBackground(.hidden).ambientBackground().navigationTitle("Apple ID 开发签名").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                accountID = renewal.settings.accounts.contains(where: { $0.id == renewal.settings.email }) ? renewal.settings.email : renewal.settings.defaultAccountID
                renewal.inspectDevelopmentPackage()
                groupStatus = HostAppGroup.inspect()
            }
    }
}
