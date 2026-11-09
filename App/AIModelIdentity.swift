import SwiftUI

enum AIModelBrand: String, CaseIterable, Sendable {
    case openAI = "openai", claude, gemini, deepSeek = "deepseek", qwen, xAI = "xai", meta, mistral

    var assetName: String { "ai.brand." + rawValue }
    static let assetBundle = Bundle(for: AIModelAssetBundle.self)

    static func resolve(model: String, name: String? = nil, provider: AIProvider? = nil) -> AIModelBrand? {
        // The transport protocol is not the model's brand: compatible gateways serve many families.
        let leaf = model.split(separator: "/").last.map(String.init) ?? model
        for candidate in [leaf, name, model].compactMap({ $0 }) {
            let words = Set(candidate.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
            if !words.isDisjoint(with: ["claude", "anthropic"]) { return .claude }
            if !words.isDisjoint(with: ["gpt", "chatgpt", "openai"]) || candidate.lowercased().hasPrefix("dall-e") || words.contains(where: { $0.range(of: #"^o[0-9]+$"#, options: .regularExpression) != nil }) { return .openAI }
            if !words.isDisjoint(with: ["gemini", "gemma", "google"]) { return .gemini }
            if words.contains("deepseek") { return .deepSeek }
            if words.contains(where: { $0.hasPrefix("qwen") }) { return .qwen }
            if !words.isDisjoint(with: ["grok", "xai"]) { return .xAI }
            if !words.isDisjoint(with: ["llama", "meta"]) { return .meta }
            if !words.isDisjoint(with: ["mistral", "mixtral", "ministral", "codestral", "pixtral", "devstral"]) { return .mistral }
        }
        return provider == .anthropic && !model.isEmpty ? .claude : nil
    }
}

private final class AIModelAssetBundle { }

struct AIModelIcon: View {
    let model: String
    var name: String? = nil
    var provider: AIProvider? = nil
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let brand = AIModelBrand.resolve(model: model, name: name, provider: provider) {
                Image(brand.assetName, bundle: AIModelBrand.assetBundle).resizable().scaledToFit()
            } else {
                Image(systemName: "bubble.left.and.bubble.right").resizable().scaledToFit()
            }
        }.frame(width: size, height: size).foregroundStyle(Color.primary).accessibilityHidden(true)
    }
}

enum AIInterface {
    static let tint = Palette.accent
}

private struct AIControlStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    func aiControlStyle() -> some View { modifier(AIControlStyle()) }
}
