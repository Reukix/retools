import SwiftUI

@MainActor
final class StoreDownloadController: ObservableObject {
    @Published var account: StoreAccountInfo?
    @Published var apps: [StoreCatalogApp] = []
    @Published var searching = false
    @Published var busy = false
    @Published var cancelling = false
    @Published var status = ""
    @Published var error: String?
    @Published var verificationRequired = false
    let service = StoreDownloadService()
    private var searchTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var operation = ""
    private var reportURL: URL?
    private var lastReport = Date.distantPast
    private var lastReportedStatus = ""
    private func report(_ phase: String) {
        guard let reportURL else { return }
        let value: [String: Any] = ["updatedAt":Date().timeIntervalSince1970,"operation":operation,"phase":phase,"stage":status,"busy":busy,"accountReady":account != nil]
        try? JSONSerialization.data(withJSONObject: value,options: [.sortedKeys]).write(to: reportURL,options: .atomic)
        lastReport = Date(); lastReportedStatus = status
    }

    func loadAccount() async { do { account = try await service.account() } catch { self.error = error.localizedDescription } }
    func signOut() async {
        guard !busy else { return }
        do { try await service.signOut(); account = nil; verificationRequired = false } catch { self.error = error.localizedDescription }
    }
    func search(_ term: String, bundleID: Bool = false) {
        searchTask?.cancel()
        let country = AppStoreCatalog.country(storeFront: account?.storeFront)
        searching = true; error = nil
        searchTask = Task {
            defer { if !Task.isCancelled { searching = false } }
            do {
                let result = try await AppStoreCatalog.search(term, country: country, lookup: bundleID)
                try Task.checkCancellation(); apps = result
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func begin(store: WorkspaceStore, renewal: RenewalController,operation: String) throws {
        guard !busy, !store.isWorking, !renewal.isWorking, !DevicePairingCoordinator.shared.isRunning else { throw FairPlayFailure("请等待当前操作完成。") }
        busy = true; cancelling = false; store.isWorking = true; store.workLabel = ""; error = nil
        self.operation = operation; reportURL = store.paths.support.appendingPathComponent("StoreOperationStatus.json"); report("working")
        UIApplication.shared.isIdleTimerDisabled = true
        progressTask = Task {
            while !Task.isCancelled {
                if !cancelling { status = StoreDownloadService.progress() }
                if status != lastReportedStatus || Date().timeIntervalSince(lastReport)>5 { report("working") }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    private func end(store: WorkspaceStore) {
        progressTask?.cancel(); progressTask = nil; busy = false; cancelling = false
        store.isWorking = false; store.workLabel = ""; UIApplication.shared.isIdleTimerDisabled = false
        report(error == nil ? (verificationRequired ? "verificationRequired" : "complete") : "failed")
    }
    func cancel() {
        guard busy,!cancelling else { return }
        cancelling = true; status = "正在取消，已校验的组件会保留…"
        StoreDownloadService.cancel()
    }
    func login(email: String, password: String, code: String, store: WorkspaceStore, renewal: RenewalController) async -> Bool {
        do { try begin(store: store, renewal: renewal,operation: "login") } catch { self.error = error.localizedDescription; return false }
        defer { end(store: store) }
        do {
            let result = try await service.login(email: email, password: password, code: code)
            switch result {
            case .signedIn(let value): account = value; verificationRequired = false; status = "商店已登录"; return true
            case .verificationRequired: verificationRequired = true; status = "请输入 Apple 验证码"; return false
            }
        } catch { self.error = error.localizedDescription; return false }
    }
    func download(_ app: StoreCatalogApp, version: String?, store: WorkspaceStore, renewal: RenewalController) async -> URL? {
        do { try begin(store: store, renewal: renewal,operation: "download") } catch { self.error = error.localizedDescription; return nil }
        defer { end(store: store) }
        do { let file = try await service.download(app, version: version); status = "安装包及许可已下载"; return file }
        catch { self.error = error.localizedDescription; return nil }
    }
    func versions(_ app: StoreCatalogApp, store: WorkspaceStore, renewal: RenewalController) async -> [String] {
        do { try begin(store: store, renewal: renewal,operation: "versions") } catch { self.error = error.localizedDescription; return [] }
        defer { end(store: store) }
        do { return try await service.versions(app) } catch { self.error = error.localizedDescription; return [] }
    }
}

struct StoreLoginSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject var controller: StoreDownloadController
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var closeAfterCancel = false
    let onSignedIn: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Apple ID", text: $email).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password).textContentType(.password)
                } footer: {
                    Text("登录拥有目标应用的 App Store 账号。此处只保存商店会话，不会切换系统账号。首次会下载并缓存约 180 MB 的商店运行组件；已校验的组件会保留以供重试。")
                }.disabled(controller.busy || controller.verificationRequired)
                if controller.verificationRequired {
                    Section("Apple 验证码") {
                        TextField("六位验证码", text: $code).textContentType(.oneTimeCode).keyboardType(.numberPad)
                    }
                }
                if controller.busy { Section { HStack { ProgressView(); Text(controller.status.isEmpty ? "正在准备商店登录…" : controller.status) } } }
                if let error = controller.error { Section { Text(error).foregroundStyle(.orange).textSelection(.enabled) } }
                Section {
                    Button(controller.verificationRequired ? "验证并登录" : "登录 App Store") {
                        Task {
                            if await controller.login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password, code: code, store: store, renewal: renewal), !closeAfterCancel {
                                password = ""; code = ""; dismiss(); onSignedIn()
                            }
                        }
                    }.disabled(controller.busy || email.isEmpty || password.isEmpty || (controller.verificationRequired && code.count != 6))
                }
            }.navigationTitle("商店账号").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button(controller.cancelling ? "正在取消…" : "取消") {
                        if controller.busy { closeAfterCancel = true; controller.cancel() }
                        else { password = ""; code = ""; controller.verificationRequired = false; dismiss() }
                    }.disabled(controller.cancelling)
                } }
                .interactiveDismissDisabled(controller.busy)
                .onChange(of: controller.busy) { _, busy in if !busy && closeAfterCancel { password = ""; code = ""; dismiss() } }
                .onDisappear { password = ""; code = ""; controller.verificationRequired = false }
        }.tint(Palette.accent)
    }
}
