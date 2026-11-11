import Foundation
import CryptoKit
import SwiftUI
import RetoolsNative

enum SigningMigration {
    struct Payload: Codable {
        let bundleID: String
        let targetTeam: String
        let workspace: WorkspaceState
        let renewal: RenewalSettings
        let passwords: [String: String]
        let accountData: [String: Data]
        let credentialFiles: [String: Data]
    }
    struct Envelope: Codable {
        let version: Int
        let id: UUID
        let targetTeam: String
        let sealed: Data
    }
    static func seal(_ payload: Payload) throws -> (Envelope, String) {
        let key = SymmetricKey(size: .bits256)
        let data = try JSONEncoder().encode(payload)
        guard data.count <= 20_000_000 else { throw WorkspaceFailure("签名资料备份过大，请先清理不再使用的证书。") }
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw WorkspaceFailure("无法创建加密的签名资料备份。") }
        let code = "RTM1-" + key.withUnsafeBytes { Data($0).base64EncodedString() }
        return (Envelope(version: 1, id: UUID(), targetTeam: payload.targetTeam, sealed: combined), code)
    }
    static func open(_ envelope: Envelope, code: String, bundleID: String, team: String) throws -> Payload {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard envelope.version == 1, envelope.sealed.count <= 20_100_000, trimmed.hasPrefix("RTM1-"),
              let key = Data(base64Encoded: String(trimmed.dropFirst(5))), key.count == 32 else { throw WorkspaceFailure("恢复码或备份格式无效。") }
        let payload: Payload
        do {
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: SymmetricKey(data: key))
            payload = try JSONDecoder().decode(Payload.self, from: bytes)
        } catch { throw WorkspaceFailure("恢复码不正确，或签名资料备份已损坏。") }
        guard payload.bundleID == bundleID, payload.targetTeam == team, envelope.targetTeam == team else {
            throw WorkspaceFailure("这份备份不属于当前开发签名。请先安装已准备的开发签名版本。")
        }
        return payload
    }
    static func backup(state: WorkspaceState, renewal: RenewalSettings, targetTeam: String, paths: WorkspacePaths) throws -> Envelope {
        var passwords: [String: String] = [:], credentials: [String: Data] = [:], accounts: [String: Data] = [:]
        for identity in state.identities {
            passwords[identity.id.uuidString] = try SecureStore.password(id: identity.id)
            for file in ["identity.p12", "profile.mobileprovision"] {
                let relative = identity.id.uuidString + "/" + file
                credentials[relative] = try Data(contentsOf: paths.credentials.appendingPathComponent(relative))
            }
        }
        let emails = Set(renewal.accounts.map(\.email) + [renewal.email]).filter { !$0.isEmpty }
        for key in emails.map({ "apple.state.\($0.lowercased())" }) + ["device.pairing", "device.host.irk"] {
            if let value = try SecureStore.data(key: key) { accounts[key] = value }
        }
        let payload = Payload(bundleID: Bundle.main.bundleIdentifier ?? "dev.retools.ios", targetTeam: targetTeam,
            workspace: state, renewal: renewal, passwords: passwords, accountData: accounts, credentialFiles: credentials)
        let (envelope, code) = try seal(payload)
        let url = paths.support.appendingPathComponent("Migration/vault.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SecureStore.saveData(Data(code.utf8), key: "migration.recovery.\(envelope.id.uuidString)")
        try JSONEncoder().encode(envelope).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var directory = url.deletingLastPathComponent(), values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return envelope
    }
    static func restore(_ payload: Payload, paths: WorkspacePaths) throws {
        try paths.createDirectories()
        // Validate every destination before writing any file or keychain item.
        let identityIDs = Set(payload.workspace.identities.map { $0.id.uuidString })
        for name in payload.credentialFiles.keys {
            let parts = name.split(separator: "/")
            guard parts.count == 2, identityIDs.contains(String(parts[0])), ["identity.p12", "profile.mobileprovision"].contains(String(parts[1])) else { throw WorkspaceFailure("签名资料包含无效的证书路径。") }
        }
        for key in payload.accountData.keys {
            guard key.hasPrefix("apple.state.") || ["device.pairing", "device.host.irk"].contains(key) else { throw WorkspaceFailure("签名资料包含无效的钥匙串项目。") }
        }
        for key in payload.passwords.keys { guard identityIDs.contains(key), UUID(uuidString: key) != nil else { throw WorkspaceFailure("签名资料中的证书身份无效。") } }
        for (name, data) in payload.credentialFiles {
            let url = paths.credentials.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        for (id, password) in payload.passwords {
            let uuid = UUID(uuidString: id)!
            if (try? SecureStore.password(id: uuid)) == nil { try SecureStore.save(password: password, id: uuid) }
        }
        for (key, data) in payload.accountData where try SecureStore.data(key: key) == nil { try SecureStore.saveData(data, key: key) }
        var workspace = (try? JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: paths.state))) ?? payload.workspace
        for identity in payload.workspace.identities where !workspace.identities.contains(where: { $0.id == identity.id }) { workspace.identities.append(identity) }
        workspace.hostIdentityID = payload.workspace.hostIdentityID
        if workspace.activeIdentityID == nil { workspace.activeIdentityID = payload.workspace.activeIdentityID }
        try JSONEncoder().encode(workspace).write(to: paths.state, options: .atomic)
        let settingsFile = paths.support.appendingPathComponent("renewal.json")
        var renewal = (try? JSONDecoder().decode(RenewalSettings.self, from: Data(contentsOf: settingsFile))) ?? payload.renewal
        for account in payload.renewal.accounts where !renewal.accounts.contains(where: { $0.id == account.id }) { renewal.accounts.append(account) }
        if renewal.defaultAccountID.isEmpty { renewal.defaultAccountID = payload.renewal.defaultAccountID }
        if renewal.hostAccountID.isEmpty { renewal.hostAccountID = payload.renewal.hostAccountID }
        renewal.hasPairing = try SecureStore.data(key: "device.pairing") != nil
        if renewal.deviceUDID.isEmpty { renewal.deviceUDID = payload.renewal.deviceUDID }
        try JSONEncoder().encode(renewal).write(to: settingsFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

@MainActor
final class SigningMigrationController: ObservableObject {
    static let shared = SigningMigrationController()
    @Published var needsRecovery = false
    @Published var result = ""
    @Published var isRestoring = false
    private var envelope: SigningMigration.Envelope?
    func inspect() {
        let paths = WorkspacePaths()
        guard let data = try? Data(contentsOf: paths.support.appendingPathComponent("Migration/vault.json")),
              let envelope = try? JSONDecoder().decode(SigningMigration.Envelope.self, from: data),
              RTNative.hostTeamIdentifier() == envelope.targetTeam,
              !FileManager.default.fileExists(atPath: paths.support.appendingPathComponent("Migration/restored-\(envelope.id.uuidString)").path) else { return }
        self.envelope = envelope; needsRecovery = true
    }
    func copyRecoveryCode() throws {
        let paths = WorkspacePaths()
        let data = try Data(contentsOf: paths.support.appendingPathComponent("Migration/vault.json"))
        let envelope = try JSONDecoder().decode(SigningMigration.Envelope.self, from: data)
        guard let value = try SecureStore.data(key: "migration.recovery.\(envelope.id.uuidString)"), let code = String(data: value, encoding: .utf8) else { throw WorkspaceFailure("当前签名无法读取恢复码。") }
        UIPasteboard.general.setItems([["public.utf8-plain-text": code]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(2 * 3600)])
        let ready: [String: String] = ["backupID": envelope.id.uuidString, "status": "recovery-code-copied"]
        try JSONEncoder().encode(ready).write(to: paths.support.appendingPathComponent("Migration/ready.json"), options: .atomic)
        result = "恢复码已复制。请保存在自己的密码管理器中；安装开发版后可粘贴恢复。"
    }
    func restore(code: String) {
        guard !isRestoring, let envelope, let team = RTNative.hostTeamIdentifier() else { return }
        isRestoring = true
        Task {
            defer { isRestoring = false }
            do {
                let payload = try SigningMigration.open(envelope, code: code, bundleID: Bundle.main.bundleIdentifier ?? "dev.retools.ios", team: team)
                try SigningMigration.restore(payload, paths: WorkspacePaths())
                try await WorkspaceStore.shared.reloadAfterMigration()
                RenewalController.shared.reloadAfterMigration()
                try Data("restored".utf8).write(to: WorkspacePaths().support.appendingPathComponent("Migration/restored-\(envelope.id.uuidString)"), options: .atomic)
                result = "签名资料、账号会话和设备配对已恢复"; needsRecovery = false
            } catch { result = error.localizedDescription }
        }
    }
}

struct SigningRecoveryView: View {
    @ObservedObject private var migration = SigningMigrationController.shared
    @State private var code = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("开发签名已安装。粘贴之前保存的恢复码，把签名证书、Apple ID 会话和配对记录恢复到新签名的钥匙串中。")
                    SecureField("恢复码", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                    PasteButton(payloadType: String.self) { values in if let value = values.first { migration.restore(code: value) } }
                    Text("点击粘贴即可使用本机剪贴板中的恢复码恢复，无需发送给任何人。").font(.footnote).foregroundStyle(Color.secondary)
                    Button("恢复签名资料") { migration.restore(code: code); code = "" }.disabled(code.isEmpty || migration.isRestoring)
                }
                if !migration.result.isEmpty { Section { Text(migration.result) } }
                if migration.isRestoring { ProgressView() }
            }.navigationTitle("恢复签名资料").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("稍后恢复") { migration.needsRecovery = false } }
        }
    }
}
