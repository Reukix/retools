import SwiftUI

struct AIModelPickerView: View {
    @ObservedObject var chat: AIChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var selected: String { chat.configuration.endpoint(for: chat.configuration.provider).model }
    private var models: [AIAvailableModel] { chat.models.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        NavigationStack {
            List {
                if chat.models.isEmpty { ContentUnavailableView("连接接口以获取模型", systemImage: "network") }
                ForEach(models) { model in
                    Button { chat.selectModel(model.id); dismiss() } label: {
                        HStack(spacing: 14) {
                            AIModelIcon(model: model.id, name: model.title, provider: chat.configuration.provider, size: 24)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.title).foregroundStyle(Color.primary)
                                if model.title != model.id { Text(model.id).font(.caption).foregroundStyle(Color.secondary) }
                            }
                            Spacer(minLength: 4)
                            if selected == model.id { Image(systemName: "checkmark").font(.subheadline.weight(.semibold)) }
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    }.disabled(chat.isGenerating).accessibilityIdentifier("ai.model." + model.id).accessibilityValue(selected == model.id ? "已选中" : "")
                }
            }.scrollContentBackground(.hidden).background(Palette.background).searchable(text: $search, prompt: "搜索模型").navigationTitle("选择模型").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { NavigationLink { AISettingsView() } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("AI 接口设置").accessibilityIdentifier("ai.settings") }
                }
        }.tint(AIInterface.tint)
    }
}
