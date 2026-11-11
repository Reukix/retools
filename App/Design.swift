import SwiftUI

enum Palette {
    static let accent = Color(red: 0.94, green: 0.36, blue: 0.17)
    /// 渐变的深端，与 accent 搭配形成品牌橙色渐变。
    static let accentDeep = Color(red: 0.87, green: 0.24, blue: 0.13)
    static let accentLight = Color(red: 1.0, green: 0.56, blue: 0.27)
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1) : UIColor(red: 0.965, green: 0.962, blue: 0.948, alpha: 1) })
    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.13, blue: 0.14, alpha: 1) : .white })
    static let ink = Color.primary
    static let muted = Color.secondary
    // Explicit text colors keep informational labels neutral inside tinted controls.
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let border = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.05) })
    static let shadow = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .clear : UIColor(red: 0.45, green: 0.25, blue: 0.1, alpha: 0.08) })
    static let dark = Color(red: 0.13, green: 0.15, blue: 0.16)
    static let accentGradient = LinearGradient(colors: [accentLight, accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// 页面背景：暖色底加顶部柔和光晕，呼应应用图标的橙色。
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Palette.background
            RadialGradient(colors: [Palette.accent.opacity(scheme == .dark ? 0.20 : 0.13), .clear], center: UnitPoint(x: 0.05, y: -0.05), startRadius: 0, endRadius: 460)
            RadialGradient(colors: [Color(red: 1, green: 0.72, blue: 0.35).opacity(scheme == .dark ? 0.10 : 0.16), .clear], center: UnitPoint(x: 1.0, y: 0.02), startRadius: 0, endRadius: 360)
        }.ignoresSafeArea()
    }
}

extension View {
    func ambientBackground() -> some View {
        background(AmbientBackground()).workbenchNavigation()
    }
    func workbenchNavigation() -> some View {
        background(WorkspaceNavigationPolicy().frame(width: 0, height: 0))
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 20
    func body(content: Content) -> some View {
        content.padding(padding)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
            .shadow(color: Palette.shadow, radius: 16, x: 0, y: 6)
    }
}
extension View {
    func workspaceCard(padding: CGFloat = 20) -> some View { modifier(CardModifier(padding: padding)) }
    /// 页面底部操作栏的背景：占满宽度、延伸到 Home 指示条下方，顶部一条细分隔线。
    /// 背景只跟着内容大小走时，内容窄（例如一行提示文字）就会变成浮在页面上的一块白块。
    func bottomBarBackground() -> some View {
        frame(maxWidth: .infinity)
            .background { Rectangle().fill(.bar).overlay(alignment: .top) { Divider() }.ignoresSafeArea(edges: .bottom) }
    }
}

struct PrimaryButton: View {
    let title: String
    var symbol: String = "plus"
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(.white).background(Palette.accentGradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .shadow(color: Palette.accent.opacity(0.28), radius: 12, x: 0, y: 6)
                .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }.buttonStyle(.plain)
    }
}

/// 胶囊形渐变按钮，用于卡片内的主要操作（如「运行」）。
/// 图标与文字紧挨的标签。按钮放在列表里时，系统标签会套用列表的图标列宽度，导致图标和文字隔得很开。
struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon; configuration.title }
    }
}

struct GradientCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.labelStyle(TightLabelStyle()).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Palette.accentGradient, in: Capsule())
            .shadow(color: Palette.accent.opacity(isEnabled ? 0.3 : 0), radius: 8, x: 0, y: 4)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct ScreenHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2).fill(Palette.accent).frame(width: 6, height: 6)
                Text(eyebrow).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Color.secondary)
            }
            Text(title).font(.system(size: 32, weight: .bold, design: .rounded)).tracking(-0.8).foregroundStyle(Color.primary)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(Color.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionHeading: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(Color.primary)
            Spacer()
            if let trailing { Text(trailing).font(.footnote.monospacedDigit()).foregroundStyle(Color.secondary) }
        }
    }
}

struct StatusPill: View {
    let title: String
    var color: Color = Palette.accent
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
        }.foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// 概览数字卡片：图标、数字与说明。
struct StatTile: View {
    let value: String
    let title: String
    let symbol: String
    var color: Color = Palette.accent
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
                .frame(width: 30, height: 30).background(color.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit().contentTransition(.numericText()).foregroundStyle(Color.primary)
                Text(title).font(.caption).foregroundStyle(Color.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).workspaceCard(padding: 14)
            .accessibilityElement(children: .combine)
    }
}

struct AppIcon: View {
    let name: String
    var url: URL?
    var size: CGFloat = 56
    /// 没有图标时按名称挑选一组固定渐变，让列表更有层次。
    private static let placeholders: [[Color]] = [
        [Color(red: 1.0, green: 0.58, blue: 0.29), Color(red: 0.92, green: 0.32, blue: 0.16)],
        [Color(red: 0.36, green: 0.62, blue: 1.0), Color(red: 0.2, green: 0.38, blue: 0.92)],
        [Color(red: 0.69, green: 0.49, blue: 1.0), Color(red: 0.47, green: 0.28, blue: 0.9)],
        [Color(red: 0.3, green: 0.82, blue: 0.62), Color(red: 0.1, green: 0.6, blue: 0.48)],
        [Color(red: 1.0, green: 0.47, blue: 0.62), Color(red: 0.88, green: 0.24, blue: 0.45)],
        [Color(red: 0.28, green: 0.78, blue: 0.9), Color(red: 0.1, green: 0.52, blue: 0.75)],
    ]
    private var gradient: [Color] {
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.placeholders[seed % Self.placeholders.count]
    }
    var body: some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFill() }
            else {
                ZStack {
                    LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.42, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.235, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.235, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .shadow(color: Palette.shadow.opacity(1.4), radius: size * 0.12, x: 0, y: size * 0.06)
    }
}

/// Retools 自身的品牌图标。
struct BrandMark: View {
    var size: CGFloat = 60
    var body: some View {
        Image("retools.brand", bundle: Bundle(for: BrandAssetAnchor.self)).resizable().scaledToFill()
            .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.235, style: .continuous))
            .shadow(color: Palette.accent.opacity(0.3), radius: size * 0.18, x: 0, y: size * 0.08)
            .accessibilityHidden(true)
    }
}
private final class BrandAssetAnchor {}

/// 渐变图标块，用于空状态与欢迎页。
struct GlyphTile: View {
    let symbol: String
    var size: CGFloat = 76
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Palette.accentGradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .shadow(color: Palette.accent.opacity(0.32), radius: 18, x: 0, y: 10)
            .accessibilityHidden(true)
    }
}

struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(spacing: 14) {
            GlyphTile(symbol: symbol).padding(.bottom, 8)
            Text(title).font(.title3.weight(.bold))
            Text(detail).font(.subheadline).foregroundStyle(Color.secondary).multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 300)
            actions().padding(.top, 6)
        }.frame(maxWidth: .infinity).padding(.vertical, 36)
    }
}
extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, detail: String) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

struct InfoRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Color.secondary)
            Spacer(minLength: 24)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled).foregroundStyle(Color.primary)
        }.font(.subheadline).padding(.vertical, 5)
    }
}

struct HelpStep: View {
    let number: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.accent)
                .frame(width: 29, height: 29).background(Palette.accent.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(Color.secondary).lineSpacing(3)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
