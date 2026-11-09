import Foundation

enum RenewalScheduling {
    static func confirmsInstall(expectedProfile: String, expectedReceipt: String?, currentProfile: String?, currentReceipt: String?) -> Bool {
        guard let receipt = expectedReceipt, !receipt.isEmpty else { return false }
        return expectedProfile == currentProfile && receipt == currentReceipt
    }
    static func nextEligible(settings: RenewalSettings, now: Date = Date()) -> Date {
        guard let attempt = settings.lastAttempt else { return now }
        let succeeded = settings.lastAttemptSucceeded == true || settings.lastSuccess.map { $0 >= attempt } == true
        let interval = succeeded ? 6 * 3600.0 : min(6 * 3600, 15 * 60 * pow(2, Double(min(5, max(0, settings.failureCount - 1)))))
        return attempt.addingTimeInterval(interval)
    }
    static func nextRequest(settings: RenewalSettings, now: Date = Date()) -> Date {
        let retrying = settings.lastAttempt != nil && settings.lastAttemptSucceeded != true && (settings.lastSuccess ?? .distantPast) < settings.lastAttempt!
        return max(now.addingTimeInterval(15 * 60), retrying ? nextEligible(settings: settings, now: now) : now.addingTimeInterval(6 * 3600))
    }
}
