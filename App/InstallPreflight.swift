import Foundation

/// 安装前检查：在上传之前就把会失败的情况说清楚，而不是装到一半才报错。
enum InstallPreflight {
    /// 免费 Apple ID 同一团队最多同时安装的应用数（系统限制）。
    static let freeAccountLimit = 3
    /// 安装后留给系统的余量。
    static let margin: Int64 = 300_000_000

    /// 免费 Apple ID 的描述文件只有 7 天有效期。
    static func isFreeProfile(_ profile: DeviceProfile) -> Bool {
        guard let created = profile.created, let expires = profile.expires else { return false }
        return expires.timeIntervalSince(created) <= 7.5 * 86_400
    }

    /// 上传会在手机上暂存一份，安装时再展开一份；迁移数据还要在本机存一份备份。
    static func requiredSpace(appSize: Int64, migrationBytes: Int64) -> Int64 { appSize * 2 + migrationBytes + margin }

    /// 同一免费团队、当前已经安装的其他应用（不含即将被替换的同 Bundle ID 应用）。
    static func freeTeamApps(team: String, replacing bundleID: String, installed: [DeviceInstalledApp], profiles: [DeviceProfile]) -> [DeviceInstalledApp] {
        guard !team.isEmpty else { return [] }
        return installed.filter { app in
            app.bundleID != bundleID && app.signedTeamID == team
                && profiles.contains { $0.teamID == team && $0.matches(app: app) && isFreeProfile($0) }
        }
    }

    /// 返回阻止安装的原因；nil 表示可以继续。
    static func blocker(appSize: Int64, migrationBytes: Int64, freeSpace: Int64?, newProfile: DeviceProfile?, bundleID: String,
                        installed: [DeviceInstalledApp], profiles: [DeviceProfile]) -> String? {
        if let freeSpace {
            let needed = requiredSpace(appSize: appSize, migrationBytes: migrationBytes)
            if freeSpace < needed {
                return "手机剩余空间不足：安装\(migrationBytes > 0 ? "并迁移数据" : "")大约需要 \(needed.byteLabel)，目前只剩 \(freeSpace.byteLabel)。可以在「设备工具」里清理不用的应用或旧备份后再试。"
            }
        }
        if let profile = newProfile, isFreeProfile(profile), !installed.contains(where: { $0.bundleID == bundleID }) {
            let others = freeTeamApps(team: profile.teamID, replacing: bundleID, installed: installed, profiles: profiles)
            if others.count >= freeAccountLimit {
                return "免费 Apple ID 同一团队最多同时安装 \(freeAccountLimit) 个应用，目前已有：\(others.map(\.name).joined(separator: "、"))。请先卸载其中一个，或换一个 Apple ID 签名。"
            }
        }
        return nil
    }
}

/// 重签换了 Bundle ID 时，把旧应用的数据迁到新应用。
enum AppDataMigration {
    static let enabledKey = "RetoolsMigrateDataOnBundleChange"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// 迁移来源：上次为这个应用装过的 Bundle ID，或原始 Bundle ID。新应用已经装过（有自己的数据）时不迁移，避免覆盖。
    static func source(newBundleID: String, previous: String?, original: String, installed: [DeviceInstalledApp]) -> DeviceInstalledApp? {
        guard !installed.contains(where: { $0.bundleID == newBundleID }) else { return nil }
        for candidate in [previous, original].compactMap({ $0 }) where candidate != newBundleID {
            if let app = installed.first(where: { $0.bundleID == candidate }), app.filesAccessible { return app }
        }
        return nil
    }
}
