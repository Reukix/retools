import SwiftUI

/// 工具详情页的紧凑摘要；操作与筛选仍由各工具按用途组织。
struct ToolPageIntro: View {
    let tool: WorkspaceTool
    let title: String
    let detail: String
    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 13) {
                ToolGlyph(symbol: tool.symbol, color: tool.color, size: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline).foregroundStyle(Color.primary)
                    Text(detail).font(.subheadline).foregroundStyle(Color.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 4)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        .accessibilityIdentifier("toolPage." + tool.rawValue + ".summary")
    }
}

struct ToolMetrics: View {
    let items: [(String, String)]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(items.indices, id: \.self) { index in
                    metric(items[index]).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(items.indices, id: \.self) { index in metric(items[index]) }
            }
        }.padding(.vertical, 5)
    }
    private func metric(_ item: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.1).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit().fixedSize().foregroundStyle(Color.primary)
            Text(item.0).font(.caption).foregroundStyle(Color.secondary).fixedSize()
        }.accessibilityElement(children: .combine)
    }
}

struct ToolActionLabel: View {
    let title: String
    let symbol: String
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Label(title, systemImage: symbol).labelStyle(TightLabelStyle())
            .font(.body.weight(.semibold)).foregroundStyle(isEnabled ? Palette.accent : Color.secondary.opacity(0.55))
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(Rectangle())
    }
}

struct ToolNotice: View {
    let title: String
    let detail: String
    var symbol = "info.circle"
    var color: Color = .secondary
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary)
                Text(detail).font(.footnote).foregroundStyle(Color.secondary).textSelection(.enabled)
            }
        } icon: { Image(systemName: symbol).foregroundStyle(color) }
        .padding(.vertical, 3)
    }
}

extension View {
    func toolListStyle() -> some View {
        listStyle(.insetGrouped).listSectionSpacing(18)
            .scrollContentBackground(.hidden).ambientBackground()
    }
}
