import SwiftUI

struct AISettingsView: View {
    @ObservedObject private var chat = AIChatStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var keys: [String: String] = [:]
    @State private var loaded = false
    @State private var connecting = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var error: String?
    private var scope: String? { (try? AIEndpoint.models(address, provider: .openAI))?.absoluteString }
    private var apiKey: Binding<String> {
        Binding(get: { scope.flatMap { keys[$0] } ?? "" }, set: { if let scope { keys[scope] = $0 } })
    }
    private var currentEndpoint: AIEndpointSettings { chat.configuration.endpoint(for: chat.configuration.provider) }
    private var currentScope: String? { (try? AIEndpoint.models(currentEndpoint.address, provider: .openAI))?.absoluteString }
    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("https://your-api-endpoint.com/v1", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("ai.address")
                    if !address.isEmpty { Button { address = "" } label: { Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44) }.buttonStyle(.borderless).accessibilityLabel("清空 API 地址").accessibilityIdentifier("ai.address.clear") }
                }
                SecureField("API Key", text: apiKey).textContentType(.oneTimeCode).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().disabled(scope == nil).accessibilityIdentifier("ai.key")
            } header: { Text("连接 AI 服务") } footer: { Text("只需地址和密钥。保存时自动识别接口、读取可用模型并设置初始模型，后缀会自动补全。") }
            if connecting {
                Section { HStack(spacing: 12) { ProgressView(); Text("正在获取可用模型…").font(.subheadline) } }.accessibilityIdentifier("ai.models.loading")
            } else if currentScope == scope, let models = currentEndpoint.availableModels, !models.isEmpty {
                Section {
                    LabeledContent("接口", value: chat.configuration.provider.title)
                    LabeledContent("可用模型", value: "\(models.filter(\.usable).count) 个").accessibilityIdentifier("ai.models.count")
                    LabeledContent("当前模型", value: models.first { $0.id == currentEndpoint.model }?.title ?? currentEndpoint.model)
                } header: { Text("已连接") } footer: { Text("模型可以在对话页顶部切换，后续更新模型列表可再次保存。") }
            }
            if let scope {
                Section {
                    Text(scope).font(.system(.caption, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("ai.endpointPreview")
                } header: { Text("模型列表地址") }
            }
            let saved = AIProvider.allCases.filter { chat.configuration.endpoint(for: $0).availableModels?.isEmpty == false }
            if saved.count > 1 {
                Section("已保存的接口") {
                    ForEach(saved) { provider in
                        Button {
                            address = chat.configuration.endpoint(for: provider).address
                            loadSavedKey()
                        } label: {
                            HStack { Text(provider.title); Spacer(); Text(URL(string: chat.configuration.endpoint(for: provider).address)?.host ?? "").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("ai.settings.error") } }
            Section { Text("密钥保存在设备钥匙串。读取模型仅访问你填写的服务，不会发送对话或生成内容。").font(.footnote).foregroundStyle(.secondary) }
        }.scrollContentBackground(.hidden).background(Palette.background).disabled(chat.isGenerating || connecting).navigationTitle("AI 接口").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { connectionTask?.cancel(); dismiss() }.tint(AIInterface.tint) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { connect() }.tint(AIInterface.tint).disabled(chat.isGenerating || connecting || scope == nil).accessibilityIdentifier("ai.settings.save") }
            }
            .onAppear { guard !loaded else { return }; loaded = true; address = currentEndpoint.address; loadSavedKey() }
            .onChange(of: scope) { _, _ in loadSavedKey() }
            .onDisappear { connectionTask?.cancel() }
            .tint(AIInterface.tint)
    }
    private func loadSavedKey() {
        guard let scope, keys[scope] == nil else { return }
        for provider in [chat.configuration.provider] + AIProvider.allCases.filter({ $0 != chat.configuration.provider }) {
            let endpoint = chat.configuration.endpoint(for: provider)
            if (try? AIEndpoint.models(endpoint.address, provider: .openAI).absoluteString) == scope {
                do { keys[scope] = try chat.key(provider: provider, address: endpoint.address) }
                catch { self.error = error.localizedDescription }
                return
            }
        }
    }
    private func connect() {
        guard !connecting, scope != nil else { return }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines), key = apiKey.wrappedValue
        connecting = true; error = nil
        connectionTask = Task {
            defer { connecting = false }
            do {
                try await chat.connectInterface(address: address, key: key); dismiss()
            } catch is CancellationError { }
            catch { self.error = AuthDiagnostics.sanitized(error.localizedDescription, secrets: [key]) }
        }
    }
}
