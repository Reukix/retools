import Foundation
import RetoolsNative

struct RenewalAccount: Codable, Identifiable, Sendable {
    var id: String { email }
    var email: String
    var anisetteURL: String
    var teamID: String
    var teams: [DeveloperTeam]
    var lastAttempt: Date?
    var lastSuccess: Date?
    var lastResult: String = "已登录"
    var isReady: Bool { !teamID.isEmpty && teams.contains { $0.id == teamID } }
}

struct RenewalAccountWork: Sendable {
    let account: RenewalAccount
    let packages: [AppPackage]
}

enum ProjectSigningAccount {
    static func resolve(identity: SigningIdentity, packageID: UUID, hostIdentityID: UUID?, settings: RenewalSettings) throws -> RenewalAccount {
        let candidates = settings.accounts.filter { $0.isReady && $0.teamID == identity.teamID }
        let preferred = [settings.packageAccounts[packageID.uuidString], identity.id == hostIdentityID ? settings.hostAccountID : nil].compactMap { $0 }
        for id in preferred { if let account = candidates.first(where: { $0.id == id }) { return account } }
        if candidates.count == 1 { return candidates[0] }
        if candidates.isEmpty { throw WorkspaceFailure("此开发证书的描述文件仅用于其他应用。请先登录同一团队的 Apple ID，或导入匹配目标应用的描述文件。") }
        throw WorkspaceFailure("同一团队有多个 Apple ID，请在自动续签中为此应用指定签名账号后重试。")
    }
}

enum RenewalPlanner {
    static func make(settings: RenewalSettings, packages: [AppPackage], force: Bool, now: Date = Date()) throws -> [RenewalAccountWork] {
        let targets = packages.filter { settings.packageIDs.contains($0.id) && (force || RenewalController.isDue(expiry: settings.installedExpiries[$0.id.uuidString], now: now)) }
        var grouped: [String: [AppPackage]] = [:]
        var bundles = Set<String>()
        for package in targets {
            let bundle = package.signedBundleID ?? package.bundleID
            guard bundles.insert(bundle).inserted else { throw WorkspaceFailure("续签队列中有多个应用使用 \(bundle)，请为它们设置不同的 Bundle ID。") }
            let owner = settings.packageAccounts[package.id.uuidString] ?? settings.defaultAccountID
            guard let account = settings.accounts.first(where: { $0.id == owner }), account.isReady else {
                throw WorkspaceFailure("请为 \(package.name) 选择已登录的 Apple ID 和有效团队。")
            }
            grouped[owner, default: []].append(package)
        }
        return settings.accounts.compactMap { account in
            guard let packages = grouped[account.id] else { return nil }
            return RenewalAccountWork(account: account, packages: packages)
        }
    }
}

/// 应用安装到设备时实际使用的签名：证书、应用标识和授权项。
/// 下次续签时据此判断能否只更新描述文件（不重装应用）。
struct InstalledSignature: Codable, Sendable, Equatable {
    var certificate: Data
    var applicationIdentifier: String
    var entitlementKeys: [String]

    /// 从即将安装的 .app 中读取签名；读不到（例如临时签名）返回 nil，下次续签就会整包重装。
    static func read(app: URL) -> InstalledSignature? {
        guard let name = (try? ArchiveService.metadata(at: app))?["CFBundleExecutable"] as? String else { return nil }
        let executable = app.appendingPathComponent(name).path
        guard let certificate = try? RTNative.signingCertificate(ofExecutable: executable),
              let entitlements = (try? RTNative.entitlements(ofExecutable: executable)) as? [String: Any],
              let appID = entitlements["application-identifier"] as? String else { return nil }
        return InstalledSignature(certificate: certificate, applicationIdentifier: appID, entitlementKeys: entitlements.keys.sorted())
    }
    /// 新描述文件能否直接替换旧描述文件；返回阻止原因，nil 表示可以。
    func blocker(for profile: ProfileRefresh.Profile) -> String? {
        var entitlements: [String: Any] = Dictionary(uniqueKeysWithValues: entitlementKeys.map { ($0, true) })
        entitlements["application-identifier"] = applicationIdentifier
        return ProfileRefresh.blocker(profile: profile, signingCertificate: certificate, signedEntitlements: entitlements, currentExpiry: nil)
    }
}

/// 只更新描述文件时要安装的内容。
struct ProfileUpdate: Sendable {
    let uuid: String
    let data: Data
}

struct PreparedRenewal: Sendable {
    let accountID: String
    let packageID: UUID
    let name: String
    let bundleID: String
    /// 整包重装时的已签名应用；只更新描述文件时为 nil。
    let app: URL?
    /// 只更新描述文件时要安装的描述文件（主应用与各扩展）；整包重装时为空。
    let profiles: [ProfileUpdate]
    /// 整包重装时记录的新签名，安装成功后保存。
    let signature: InstalledSignature?
    /// 只更新描述文件失败时，用同一份凭据退回整包重装。
    let credentials: AppleAppCredentials?
    let expiry: Date?
    let previousExpiry: Date?
}

enum RenewalPreparation: Sendable {
    case ready(PreparedRenewal)
    case failed(accountID: String, packageID: UUID, name: String, message: String)
}

enum RenewalPreparationEngine {
    static func prepare(_ work: RenewalAccountWork, udid: String, service: AppleAccountService,
                        workspace: WorkspaceService, paths: WorkspacePaths, installed: [String: InstalledSignature] = [:],
                        installedExpiries: [String: Date] = [:],
                        progress: @escaping @Sendable (String) async -> Void) async -> [RenewalPreparation] {
        var results: [RenewalPreparation] = []
        for package in work.packages {
            do {
                try Task.checkCancellation()
                // 还没用 Apple ID 签过的应用，与 SideStore 一样在 Bundle ID 后加上团队 ID。
                let bundleID = package.signedBundleID ?? AppleIDBundleIdentifier.resolve(original: package.bundleID, team: work.account.teamID)
                // 上次签名记下的主应用与扩展列表可直接用来取描述文件；没有记录时先解包准备。
                var plan: AppleSigningPlan?
                var bundles = package.appleBundles.flatMap { $0.first?.bundleID == bundleID ? $0 : nil }
                if bundles == nil {
                    await progress("正在准备 \(package.name)…")
                    let prepared = try await workspace.prepareAppleSigning(package.id, bundleID: bundleID)
                    plan = prepared; bundles = prepared.bundles
                }
                do {
                    await progress("正在为 \(package.name) 获取新描述文件…")
                    let credentials = try await service.appCredentials(email: work.account.email, anisetteURL: work.account.anisetteURL,
                        teamID: work.account.teamID, udid: udid, bundles: bundles ?? [])
                    try Task.checkCancellation()
                    guard let mainData = credentials.profiles[bundleID] else { throw WorkspaceFailure("Apple 未返回主应用的描述文件。") }
                    let key = package.id.uuidString
                    let allBundles = (bundles ?? []).allSatisfy { credentials.profiles[$0.bundleID] != nil }
                    if plan == nil, allBundles, !credentials.extensionsRemoved, let recorded = installed[key],
                       let profile = try? ProfileRefresh.parse(mainData), recorded.blocker(for: profile) == nil {
                        // 证书与授权都没变：主应用和扩展都只更新描述文件，不重签、不重装。
                        let updates = try (bundles ?? []).compactMap { request -> ProfileUpdate? in
                            guard let data = credentials.profiles[request.bundleID] else { return nil }
                            return ProfileUpdate(uuid: try ProfileRefresh.parse(data).uuid, data: data)
                        }
                        results.append(.ready(PreparedRenewal(accountID: work.account.id, packageID: package.id, name: package.name, bundleID: bundleID,
                            app: nil, profiles: updates, signature: recorded, credentials: credentials, expiry: profile.expiry,
                            previousExpiry: installedExpiries[key] ?? package.signedExpiresAt)))
                        continue
                    }
                    await progress("正在签名 \(package.name)…")
                    let ready: AppleSigningPlan
                    if let plan { ready = plan } else { ready = try await workspace.prepareAppleSigning(package.id, bundleID: bundleID) }
                    plan = nil  // finishAppleSigning 负责清理临时目录
                    let (app, expiry) = try await signedApp(package, plan: ready, credentials: credentials, workspace: workspace, paths: paths)
                    results.append(.ready(PreparedRenewal(accountID: work.account.id, packageID: package.id, name: package.name, bundleID: bundleID,
                        app: app, profiles: [], signature: InstalledSignature.read(app: app), credentials: nil,
                        expiry: expiry, previousExpiry: installedExpiries[key] ?? package.signedExpiresAt)))
                } catch {
                    if let plan { await workspace.discardAppleSigning(plan) }
                    throw error
                }
            } catch {
                results.append(.failed(accountID: work.account.id, packageID: package.id, name: package.name,
                    message: Task.isCancelled ? "续签已取消" : error.localizedDescription))
            }
        }
        return results
    }

    /// 按 SideStore 流程用各 bundle 的描述文件重签，并解包到临时目录供整包安装。
    static func signedApp(_ package: AppPackage, plan: AppleSigningPlan, credentials: AppleAppCredentials,
                          workspace: WorkspaceService, paths: WorkspacePaths) async throws -> (URL, Date?) {
        let state = try await workspace.finishAppleSigning(plan, credentials: credentials)
        guard let signed = state.packages.first(where: { $0.id == package.id }), let file = signed.signedFile else { throw WorkspaceFailure("没有生成续签 IPA。") }
        let root = paths.staging.appendingPathComponent(UUID().uuidString)
        do { return (try ArchiveService.unpack(paths.exports.appendingPathComponent(file), to: root), signed.signedExpiresAt) }
        catch { try? FileManager.default.removeItem(at: root); throw error }
    }
}
