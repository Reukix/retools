import SwiftUI

struct ToolFavoritesView: View {
    @Binding var selection: [WorkspaceTool]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(selection) { tool in
                        HStack(spacing: 12) {
                            Button { selection.removeAll { $0 == tool } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(Color.secondary)
                                    .frame(minWidth: 32, minHeight: 40)
                            }.buttonStyle(.borderless)
                                .accessibilityLabel("移出常用：" + tool.title)
                                .accessibilityIdentifier("tools.favorite.remove." + tool.rawValue)
                            ToolGlyph(symbol: tool.symbol, color: tool.color, size: 32)
                            Text(tool.title).font(.subheadline.weight(.medium))
                        }
                    }
                    .onMove { source, destination in
                        var ordered = selection; ordered.move(fromOffsets: source, toOffset: destination); selection = ordered
                    }
                    if selection.isEmpty { Text("在下方添加常用工具").font(.subheadline).foregroundStyle(Color.secondary) }
                } header: {
                    HStack {
                        Text("首页显示顺序")
                        Spacer()
                        Text("\(selection.count) / \(ToolFavorites.maximumCount)")
                            .monospacedDigit().accessibilityIdentifier("tools.favorites.count")
                    }
                } footer: {
                    Text("拖动右侧调整顺序。最多显示 6 项，也可以在工具首页长按添加或移出常用。")
                }
                ForEach(ToolCategory.allCases) { category in
                    let available = WorkspaceTool.allCases.filter { $0.category == category && !selection.contains($0) }
                    if !available.isEmpty {
                        Section(category.title) {
                            ForEach(available) { tool in
                                Button { if selection.count < ToolFavorites.maximumCount { selection.append(tool) } } label: {
                                    HStack(spacing: 12) {
                                        ToolGlyph(symbol: tool.symbol, color: tool.color, size: 32)
                                        Text(tool.title).font(.subheadline).foregroundStyle(Color.primary)
                                        Spacer(minLength: 8)
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(selection.count < ToolFavorites.maximumCount ? Palette.accent : Color.secondary)
                                    }.padding(.vertical, 4).contentShape(Rectangle())
                                }.buttonStyle(.borderless).disabled(selection.count >= ToolFavorites.maximumCount)
                                    .accessibilityLabel("添加到常用：" + tool.title)
                                    .accessibilityIdentifier("tools.favorite.add." + tool.rawValue)
                            }
                        }
                    }
                }
                Section {
                    Button("恢复默认布局") { selection = ToolFavorites.defaults }
                        .accessibilityIdentifier("tools.favorites.reset")
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden).ambientBackground()
            .navigationTitle("常用工具").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("tools.favorites.done") } }
        }
    }
}
