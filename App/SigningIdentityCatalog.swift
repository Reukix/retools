import Foundation
import CryptoKit
import RetoolsNative

enum SigningIdentityCatalog {
    private struct Key: Hashable {
        let certificate: String
        let team: String
        let application: String
        let scope: String
    }

    // UUIDs and validity dates describe a profile revision, not a different
    // signing configuration. Permissions and device/distribution scope do.
    static func profileScope(_ profile: [String: Any]) throws -> String {
        var scope: [String: Any] = ["Entitlements": profile["Entitlements"] as? [String: Any] ?? [:]]
        for key in ["ProvisionedDevices", "Platform", "ApplicationIdentifierPrefix"] {
            if let values = profile[key] as? [String] { scope[key] = values.sorted() }
        }
        for key in ["ProvisionsAllDevices", "LocalProvision"] { scope[key] = profile[key] as? Bool ?? false }
        let data = try JSONSerialization.data(withJSONObject: canonical(scope), options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func canonical(_ value: Any) throws -> Any {
        switch value {
        case let dictionary as [String: Any]: return ["dictionary": try dictionary.mapValues(canonical)]
        case let array as [Any]: return ["array": try array.map(canonical)]
        case let data as Data: return ["data": data.base64EncodedString()]
        case let date as Date: return ["date": date.timeIntervalSinceReferenceDate]
        case let string as String: return ["string": string]
        case let number as NSNumber: return ["number": number]
        default: throw WorkspaceFailure("描述文件包含无法识别的权限值。")
        }
    }
    private static func key(_ identity: SigningIdentity) -> Key? {
        guard !identity.fingerprint.isEmpty, let scope = identity.profileScopeFingerprint else { return nil }
        return Key(certificate: identity.fingerprint.lowercased(), team: identity.teamID, application: identity.applicationIdentifier, scope: scope)
    }
    static func equivalent(_ first: SigningIdentity, _ second: SigningIdentity) -> Bool {
        guard let firstKey = key(first), let secondKey = key(second) else { return false }
        return firstKey == secondKey
    }
    private static func readScope(_ identity: SigningIdentity, paths: WorkspacePaths) -> String? {
        let file = paths.credentials.appendingPathComponent(identity.id.uuidString + "/profile.mobileprovision")
        guard let data = try? Data(contentsOf: file), let payload = try? RTNative.profilePayload(data),
              let profile = (try? PropertyListSerialization.propertyList(from: payload, format: nil)) as? [String: Any],
              (profile["TeamIdentifier"] as? [String])?.first == identity.teamID,
              (profile["Entitlements"] as? [String: Any])?["application-identifier"] as? String == identity.applicationIdentifier,
              (profile["DeveloperCertificates"] as? [Data])?.contains(where: {
                  SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() == identity.fingerprint.lowercased()
              }) == true else { return nil }
        return try? profileScope(profile)
    }
    static func usable(_ identity: SigningIdentity, paths: WorkspacePaths) -> Bool {
        let file = paths.credentials.appendingPathComponent(identity.id.uuidString + "/identity.p12")
        guard let data = try? Data(contentsOf: file), let password = try? SecureStore.password(id: identity.id),
              let details = try? RTNative.certificateDetails(data, password: password),
              let certificate = details["certificateDER"] as? Data else { return false }
        return SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined() == identity.fingerprint.lowercased()
    }
    static func normalized(_ original: WorkspaceState, paths: WorkspacePaths) -> WorkspaceState {
        var next = original
        for index in next.identities.indices where next.identities[index].profileScopeFingerprint == nil {
            next.identities[index].profileScopeFingerprint = readScope(next.identities[index], paths: paths)
        }
        let groups = Dictionary(grouping: next.identities.compactMap { identity in key(identity).map { ($0, identity) } }, by: { $0.0 })
        var replacements: [UUID: UUID] = [:]
        for group in groups.values where group.count > 1 {
            let candidates = group.map { $0.1 }.sorted {
                let firstExpiry = min($0.expiresAt, $0.certificateExpiresAt), secondExpiry = min($1.expiresAt, $1.certificateExpiresAt)
                if firstExpiry != secondExpiry { return firstExpiry > secondExpiry }
                return $0.importedAt > $1.importedAt
            }
            guard let kept = candidates.first(where: { usable($0, paths: paths) }) else { continue }
            for identity in candidates where identity.id != kept.id { replacements[identity.id] = kept.id }
        }
        next.identities.removeAll { replacements[$0.id] != nil }
        if let active = next.activeIdentityID, let replacement = replacements[active] { next.activeIdentityID = replacement }
        if let host = next.hostIdentityID, let replacement = replacements[host] { next.hostIdentityID = replacement }
        for index in next.packages.indices {
            if let selected = next.packages[index].signingOptions?.identityID, let replacement = replacements[selected],
               let identity = next.identities.first(where: { $0.id == replacement }) { next.packages[index].signingOptions?.selectIdentity(identity) }
        }
        return next
    }
    static func changed(_ first: WorkspaceState, _ second: WorkspaceState) -> Bool {
        first.identities != second.identities || first.activeIdentityID != second.activeIdentityID || first.hostIdentityID != second.hostIdentityID
    }
    static func cleanupRemoved(from previous: WorkspaceState, keeping current: WorkspaceState, paths: WorkspacePaths) {
        let retained = Set(current.identities.map(\.id))
        // Called only after the replacement and its selections are committed.
        for identity in previous.identities where !retained.contains(identity.id) {
            try? SecureStore.delete(id: identity.id)
            try? FileManager.default.removeItem(at: paths.credentials.appendingPathComponent(identity.id.uuidString))
        }
    }
}
