import SwiftUI

/// Device-service confirmation requires observing the trusted SpringBoard
/// executable with a different PID; accepting a request is a separate state.
@MainActor
final class RespringSession: ObservableObject {
    enum Phase: Equatable { case idle, preparing, running, unavailable, stopped, submitted, confirmed, failed(String) }
    @Published private(set) var phase: Phase = .idle
    private let executionAllowed: Bool
    private let preparationDelay: Duration
    private var deviceTask: Task<DesktopRestart.Record, Error>?

    nonisolated static var platformAllowsExecution: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    init(executionAllowed: Bool = RespringSession.platformAllowsExecution,
         preparationDelay: Duration = .milliseconds(250)) {
        self.executionAllowed = executionAllowed; self.preparationDelay = preparationDelay
    }

    var isAttempting: Bool { phase == .preparing || phase == .running }

    func run(_ operation: @escaping @MainActor () async throws -> DesktopRestart.Record) async {
        guard phase == .idle else { return }
        guard executionAllowed else { phase = .unavailable; return }
        phase = .preparing
        do {
            try await Task.sleep(for: preparationDelay)
            guard phase == .preparing else { return }
            try Task.checkCancellation()
            phase = .running
            let task = Task { try await operation() }; deviceTask = task
            defer { deviceTask = nil }
            let record = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard phase == .running else { return }
            phase = record.confirmedPID != nil ? .confirmed : .submitted
        } catch is CancellationError { stop() }
        catch { fail(error.localizedDescription) }
    }

    func stop() { deviceTask?.cancel(); if isAttempting { phase = .stopped } }
    func fail(_ message: String) { if phase == .idle || isAttempting { phase = .failed(message) } }
}

struct RespringView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var renewal: RenewalController
    @StateObject private var session = RespringSession()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                if session.isAttempting { ProgressView().tint(Palette.accent).controlSize(.large) }
                else { Image(systemName: "arrow.triangle.2.circlepath").font(.largeTitle).foregroundStyle(Palette.accent) }
                Text(title).font(.headline).accessibilityIdentifier("respring.status")
                Text(message).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7))
                Button(session.isAttempting ? "停止尝试" : "关闭") {
                    if session.isAttempting { session.stop() } else { dismiss() }
                }
                .buttonStyle(.bordered).tint(Palette.accent).padding(.top, 8).accessibilityIdentifier("respring.close")
            }
            .foregroundStyle(.white).padding(32).frame(maxWidth: 440)
        }
        .interactiveDismissDisabled(session.isAttempting)
        .task { await session.run { try await DeviceToolsStore.shared.restartDesktop(renewal: renewal) } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.stop() } }
        .onChange(of: session.phase) { _, phase in AuthDiagnostics.record(stage: "注销", message: "设备服务：\(String(describing: phase))") }
        .onDisappear { session.stop() }
    }

    private var title: String {
        switch session.phase {
        case .idle, .preparing: "正在准备注销…"
        case .running: "正在尝试重启桌面…"
        case .unavailable: "请在真机上使用"
        case .stopped: "尝试已停止"
        case .submitted: "已发送注销请求"
        case .confirmed: "桌面已重新启动"
        case .failed: "注销尝试已结束"
        }
    }
    private var message: String {
        switch session.phase {
        case .idle, .preparing, .running: "设备可能短暂黑屏并返回锁定屏幕。"
        case .unavailable: "模拟器不执行注销操作。"
        case .stopped: "已停止继续尝试，已发起的系统操作可能仍会返回锁定屏幕。"
        case .submitted: "尚未观察到桌面进程重新启动。重新打开设备工具时会再次核对。"
        case .confirmed: "已观察到系统桌面进程的 PID 发生变化。"
        case .failed(let message): message
        }
    }
}
