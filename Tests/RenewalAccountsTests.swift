import XCTest
@testable import LiveContainerSwiftUI

final class RenewalAccountsTests: XCTestCase {
    private func account(_ name: String) -> RenewalAccount {
        RenewalAccount(email: "\(name)@example.invalid", anisetteURL: "https://example.invalid", teamID: name,
            teams: [DeveloperTeam(id: name, name: name, type: "Individual")])
    }
    private func package(_ name: String) -> AppPackage {
        AppPackage(id: UUID(), name: name, bundleID: "dev.test.\(name)", version: "1", build: "1", minimumOS: "17",
            fileName: "test.ipa", byteCount: 1, isEncrypted: false, importedAt: Date())
    }
    func testAutoRenewBlockerReportsFirstMissingRequirement() {
        var settings = RenewalSettings()
        XCTAssertEqual(settings.autoRenewBlocker, "未登录 Apple ID")
        settings.accounts = [account("A")]
        XCTAssertEqual(settings.autoRenewBlocker, "缺少设备配对")
        settings.hasPairing = true
        XCTAssertEqual(settings.autoRenewBlocker, "未选择续签目标")
        settings.renewHost = true
        XCTAssertNil(settings.autoRenewBlocker)
        settings.renewHost = false; settings.packageIDs = [UUID()]
        XCTAssertNil(settings.autoRenewBlocker)
    }
    func testPruneRemovesRecordsOfDeletedPackagesOnly() {
        var settings = RenewalSettings()
        let kept = UUID(), removed = UUID()
        settings.packageIDs = [kept, removed]
        settings.packageAccounts = [kept.uuidString: "a", removed.uuidString: "b"]
        settings.installedExpiries = [kept.uuidString: Date(), removed.uuidString: Date(), UUID().uuidString: Date()]
        let signature = InstalledSignature(certificate: Data([1, 2, 3]), applicationIdentifier: "T.app", entitlementKeys: ["application-identifier"])
        settings.installedSignatures = [kept.uuidString: signature, removed.uuidString: signature]
        XCTAssertTrue(settings.tracks(removed))
        XCTAssertTrue(settings.prune(keeping: [kept]))
        XCTAssertEqual(settings.packageIDs, [kept])
        XCTAssertEqual(Set(settings.packageAccounts.keys), [kept.uuidString])
        XCTAssertEqual(Set(settings.installedExpiries.keys), [kept.uuidString])
        XCTAssertEqual(Set(settings.installedSignatures.keys), [kept.uuidString])
        XCTAssertFalse(settings.tracks(removed))
        XCTAssertFalse(settings.prune(keeping: [kept]), "没有残留时不应报告改动")
    }
    func testLegacyAccountMigrationKeepsSelectionAndAssignments() {
        var settings = RenewalSettings(), app = package("old")
        let owner = account("first")
        settings.email = " FIRST@example.invalid "; settings.teams = owner.teams; settings.teamID = owner.teamID
        settings.packageIDs = [app.id]; settings.installedExpiries[app.id.uuidString] = .distantFuture
        settings.migrateAccounts()
        XCTAssertEqual(settings.accounts.map(\.id), [owner.id])
        XCTAssertEqual(settings.packageAccounts[app.id.uuidString], owner.id)
        XCTAssertEqual(settings.installedExpiries[app.id.uuidString], .distantFuture)
        settings.migrateAccounts(); XCTAssertEqual(settings.accounts.count, 1)
    }
    func testPlannerSeparatesTwoAccountsAndDoesNotDuplicateTargets() throws {
        let first = account("first"), second = account("second"), a = package("one"), b = package("two")
        var settings = RenewalSettings(); settings.accounts = [first, second]; settings.defaultAccountID = first.id
        settings.packageIDs = [a.id, b.id]; settings.packageAccounts[b.id.uuidString] = second.id
        let work = try RenewalPlanner.make(settings: settings, packages: [a, b], force: true)
        XCTAssertEqual(work.count, 2)
        XCTAssertEqual(work[0].account.teamID, "first"); XCTAssertEqual(work[0].packages.map(\.id), [a.id])
        XCTAssertEqual(work[1].account.teamID, "second"); XCTAssertEqual(work[1].packages.map(\.id), [b.id])
        settings.installedExpiries[a.id.uuidString] = .distantFuture
        XCTAssertEqual(try RenewalPlanner.make(settings: settings, packages: [a, b], force: false).flatMap(\.packages).map(\.id), [b.id])
    }
    func testPlannerRejectsMissingOwnerAndDuplicateBundleInstallations() throws {
        let first = account("first"), a = package("one")
        var b = package("two"), settings = RenewalSettings()
        settings.accounts = [first]; settings.defaultAccountID = first.id; settings.packageIDs = [a.id, b.id]
        settings.packageAccounts[a.id.uuidString] = ""
        XCTAssertThrowsError(try RenewalPlanner.make(settings: settings, packages: [a,b], force: true))
        settings.packageAccounts[a.id.uuidString] = first.id; b.bundleID = a.bundleID
        XCTAssertThrowsError(try RenewalPlanner.make(settings: settings, packages: [a,b], force: true))
    }
    func testProjectSigningResolvesSelectedCertificatesAccountWithoutCrossingTeams() throws {
        let owner = account("first"), other = account("second"), app = package("project")
        let identity = SigningIdentity(id: UUID(), name: "Development", teamID: owner.teamID, profileName: "Retools", applicationIdentifier: owner.teamID + ".dev.retools.ios", expiresAt: .distantFuture, certificateExpiresAt: .distantFuture, fingerprint: "test", importedAt: Date())
        var settings = RenewalSettings(); settings.accounts = [other, owner]; settings.defaultAccountID = other.id
        XCTAssertEqual(try ProjectSigningAccount.resolve(identity: identity, packageID: app.id, hostIdentityID: nil, settings: settings).id, owner.id)
        var shared = account("shared"); shared.teamID = owner.teamID; shared.teams = owner.teams
        settings.accounts.append(shared)
        XCTAssertThrowsError(try ProjectSigningAccount.resolve(identity: identity, packageID: app.id, hostIdentityID: nil, settings: settings))
        settings.hostAccountID = owner.id
        XCTAssertEqual(try ProjectSigningAccount.resolve(identity: identity, packageID: app.id, hostIdentityID: identity.id, settings: settings).id, owner.id)
        settings.packageAccounts[app.id.uuidString] = shared.id
        XCTAssertEqual(try ProjectSigningAccount.resolve(identity: identity, packageID: app.id, hostIdentityID: nil, settings: settings).id, shared.id)
        settings.accounts = [other]
        XCTAssertThrowsError(try ProjectSigningAccount.resolve(identity: identity, packageID: app.id, hostIdentityID: identity.id, settings: settings))
    }
    func testResettingOneAccountDoesNotChangeAnotherAccountsState() async throws {
        let a = "test.\(UUID().uuidString.lowercased())@example.invalid", b = "test.\(UUID().uuidString.lowercased())@example.invalid"
        defer { try? SecureStore.deleteData(key: "apple.state.\(a)"); try? SecureStore.deleteData(key: "apple.state.\(b)") }
        let first = ["anisette_state": "first-adi", "retools_auth": "first-token", "certificate": "first-key"]
        let second = ["anisette_state": "second-adi", "retools_auth": "second-token", "certificate": "second-key"]
        try SecureStore.saveData(JSONEncoder().encode(first), key: "apple.state.\(a)")
        let secondData = try JSONEncoder().encode(second)
        try SecureStore.saveData(secondData, key: "apple.state.\(b)")
        try await AppleAccountService().resetAnisette(email: a)
        let reset = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(SecureStore.data(key: "apple.state.\(a)")))
        XCTAssertNil(reset["retools_auth"]); XCTAssertEqual(reset["certificate"], "first-key")
        XCTAssertEqual(try SecureStore.data(key: "apple.state.\(b)"), secondData)
    }
    @MainActor
    func testPairingPresentationUsesNotificationWhenIslandOrPermissionUnavailable() {
        XCTAssertTrue(PairingPresentation.prefersIsland(isPhone: true, topInset: 62, activitiesEnabled: true))
        XCTAssertFalse(PairingPresentation.prefersIsland(isPhone: true, topInset: 47, activitiesEnabled: true))
        XCTAssertFalse(PairingPresentation.prefersIsland(isPhone: true, topInset: 62, activitiesEnabled: false))
        XCTAssertFalse(PairingPresentation.prefersIsland(isPhone: false, topInset: 62, activitiesEnabled: true))
    }
    func testCertificatePermissionPreservesFalseAndUnknownEntitlements() {
        let entries = CertificatePermission.entries(["get-task-allow": false, "keychain-access-groups": ["TEAM.*"], "custom.capability": ["level": 2]])
        XCTAssertEqual(entries.first(where: { $0.id == "get-task-allow" })?.enabled, false)
        XCTAssertEqual(entries.first(where: { $0.id == "keychain-access-groups" })?.value, "TEAM.*")
        XCTAssertTrue(entries.first(where: { $0.id == "custom.capability" })?.value.contains("2") == true)
    }

    func testAppleIDSigningAppendsTeamLikeSideStore() {
        XCTAssertEqual(AppleIDBundleIdentifier.resolve(original: "app.swiftgram.ios", team: "TESTTEAM01"), "app.swiftgram.ios.TESTTEAM01")
        // 已用本团队标识签过的继续沿用；换团队后重新生成。
        XCTAssertEqual(AppleIDBundleIdentifier.resolve(original: "app.swiftgram.ios", team: "TESTTEAM01", previous: "app.swiftgram.ios.TESTTEAM01"), "app.swiftgram.ios.TESTTEAM01")
        XCTAssertEqual(AppleIDBundleIdentifier.resolve(original: "app.swiftgram.ios", team: "NEWTEAM123", previous: "app.swiftgram.ios.TESTTEAM01"), "app.swiftgram.ios.NEWTEAM123")
        XCTAssertEqual(AppleIDBundleIdentifier.resolve(original: "app.swiftgram.ios", team: "TESTTEAM01", previous: "com.other.TESTTEAM01"), "app.swiftgram.ios.TESTTEAM01")
        // 用户填写的标识与已带团队 ID 的标识保持不变。
        XCTAssertEqual(AppleIDBundleIdentifier.resolve(original: "app.swiftgram.ios", team: "TESTTEAM01", custom: "com.me.regram"), "com.me.regram")
        XCTAssertEqual(AppleIDBundleIdentifier.resolve(original: "com.me.app.TESTTEAM01", team: "TESTTEAM01"), "com.me.app.TESTTEAM01")
    }
}
