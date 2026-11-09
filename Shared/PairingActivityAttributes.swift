import ActivityKit
import Foundation

struct PairingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var pin: String?
        var deadline: Date
        var finished = false
        var succeeded = false
    }
    let sessionID: UUID
}
