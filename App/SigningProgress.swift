import Foundation

/// 证书签名流程的各个阶段，界面按此顺序逐项展示。
enum SigningStage: Int, CaseIterable, Comparable, Sendable {
    case credentials, unpack, configure, inject, sign, pack, save, install

    var title: String {
        switch self {
        case .credentials: "准备签名证书"
        case .unpack: "解压 IPA"
        case .configure: "应用项目配置"
        case .inject: "注入插件"
        case .sign: "签名可执行文件"
        case .pack: "打包 IPA"
        case .save: "保存签名输出"
        case .install: "安装到设备"
        }
    }
    var symbol: String {
        switch self {
        case .credentials: "checkmark.seal"
        case .unpack: "shippingbox"
        case .configure: "slider.horizontal.3"
        case .inject: "puzzlepiece.extension"
        case .sign: "signature"
        case .pack: "archivebox"
        case .save: "tray.and.arrow.down"
        case .install: "iphone.and.arrow.forward"
        }
    }
    static func < (lhs: SigningStage, rhs: SigningStage) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct SigningEvent: Sendable {
    var stage: SigningStage
    /// 0...1；为 nil 时界面显示不定进度。
    var fraction: Double?
    var detail: String?
    var skipped = false
}

/// 从签名服务（后台 actor、原生签名线程）向界面转发进度。按时间节流，阶段变化总是立即转发。
final class SigningReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStage: SigningStage?
    private var lastEmit = Date.distantPast
    private let deliver: @Sendable (SigningEvent) -> Void
    init(_ deliver: @escaping @Sendable (SigningEvent) -> Void) { self.deliver = deliver }

    func report(_ stage: SigningStage, fraction: Double? = nil, detail: String? = nil) {
        emit(SigningEvent(stage: stage, fraction: fraction.map { min(1, max(0, $0)) }, detail: detail))
    }
    func skip(_ stage: SigningStage, detail: String) {
        emit(SigningEvent(stage: stage, fraction: 1, detail: detail, skipped: true))
    }
    private func emit(_ event: SigningEvent) {
        lock.lock()
        let now = Date()
        let changed = lastStage != event.stage || event.skipped || event.fraction == 1
        guard changed || now.timeIntervalSince(lastEmit) >= 0.05 else { lock.unlock(); return }
        lastStage = event.stage; lastEmit = now
        lock.unlock()
        deliver(event)
    }
}

/// 一次签名任务在界面上的状态。
@MainActor
final class SigningProgressModel: ObservableObject, Identifiable {
    enum StepState: Equatable { case pending, running, done, skipped, failed }
    enum Outcome: Equatable { case running, succeeded(String), failed(String) }

    let id = UUID()
    let appName: String
    let stages: [SigningStage]
    @Published private(set) var states: [SigningStage: StepState] = [:]
    @Published private(set) var details: [SigningStage: String] = [:]
    @Published private(set) var current: SigningStage?
    @Published private(set) var fraction: Double?
    @Published private(set) var outcome: Outcome = .running
    @Published private(set) var log: [String] = []
    let startedAt = Date()
    @Published private(set) var finishedAt: Date?
    var exportURL: URL?

    init(appName: String, install: Bool) {
        self.appName = appName
        stages = SigningStage.allCases.filter { install || $0 != .install }
        for stage in stages { states[stage] = .pending }
    }

    /// 已完成的整体比例：已完成阶段加上当前阶段的进度。
    var overall: Double {
        let finished = stages.filter { [.done, .skipped].contains(states[$0]) }.count
        let partial = current.map { states[$0] == .running ? (fraction ?? 0) : 0 } ?? 0
        return min(1, (Double(finished) + partial) / Double(max(1, stages.count)))
    }

    func apply(_ event: SigningEvent) {
        guard outcome == .running, stages.contains(event.stage) else { return }
        // 进度经异步转发，可能晚于下一阶段到达；已经过去的阶段不再回退。
        if let current, event.stage < current, !event.skipped { return }
        if [.done, .skipped].contains(states[event.stage]), !event.skipped { return }
        // 推进到新阶段时，之前仍在进行或未开始的阶段视为完成。
        for stage in stages where stage < event.stage && [.pending, .running].contains(states[stage]) { states[stage] = .done }
        if event.skipped {
            states[event.stage] = .skipped
            if let detail = event.detail { details[event.stage] = detail }
            if current == event.stage { current = nil; fraction = nil }
            return
        }
        if current != event.stage, let detail = event.detail { append("\(event.stage.title)：\(detail)") }
        else if current != event.stage { append(event.stage.title) }
        current = event.stage; states[event.stage] = .running; fraction = event.fraction
        if let detail = event.detail { details[event.stage] = detail }
    }
    func succeed(_ message: String) {
        for stage in stages where [.pending, .running].contains(states[stage]) { states[stage] = .done }
        current = nil; fraction = nil; outcome = .succeeded(message); finishedAt = Date(); append(message)
    }
    func fail(_ message: String) {
        if let current { states[current] = .failed } else if let first = stages.first(where: { states[$0] == .pending }) { states[first] = .failed }
        fraction = nil; outcome = .failed(message); finishedAt = Date(); append("失败：" + message)
    }
    private func append(_ line: String) {
        let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        log.append("\(stamp)  \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
