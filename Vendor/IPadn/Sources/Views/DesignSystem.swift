import SwiftUI
import UIKit

// Retools presentation, adapted 2026-11-11. Business screens use native SwiftUI controls.
enum UX {
    static func motion(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }
    static let accent = Color(red: 0.94, green: 0.36, blue: 0.17)
    static let accentGradient = LinearGradient(colors: [Color(red: 1, green: 0.56, blue: 0.27), accent, Color(red: 0.87, green: 0.24, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let tint = Color.primary
    static let buttonTint = accent
    static let onAccent = Color.white
    static let switchTint = accent
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1) : UIColor(red: 0.965, green: 0.962, blue: 0.948, alpha: 1) })
    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.13, blue: 0.14, alpha: 1) : .white })
    static let border = Color.primary.opacity(0.06)
    static let iconCorner: CGFloat = 0.2237
    static func feedback() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

/// Full-width primary action (App Store sign-in "继续" style).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(configuration.role == .destructive ? Color.white : UX.onAccent)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background { RoundedRectangle(cornerRadius: 17, style: .continuous).fill(configuration.role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(UX.accentGradient)) }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .opacity(enabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: configuration.isPressed)
    }
}
typealias MonochromeButtonStyle = PrimaryButtonStyle

/// System switch with a tint that stays legible in both appearances (see `UX.switchTint`).
struct TintedSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).tint(UX.switchTint)
    }
}

/// App Store "获取 / 打开" capsule. `filled` is the prominent variant.
struct CapsuleButtonStyle: ButtonStyle {
    var filled = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(filled ? UX.onAccent : Color.primary)
            .padding(.horizontal, 16).frame(minWidth: 74, minHeight: 36)
            .background(filled ? AnyShapeStyle(UX.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.06)), in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

/// A real Button keeps keyboard, VoiceOver, disabled state and List selection behavior native.
struct RowCapsule: View {
    let title: String
    var filled = false
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .buttonStyle(CapsuleButtonStyle(filled: filled))
            .disabled(!enabled)
            .accessibilityLabel(title)
    }
}

/// App Store download progress: a ring with a stop/pause glyph.
struct ProgressRing: View {
    var progress: Double?
    var symbol = "pause.fill"
    var body: some View {
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 3)
            if let progress {
                Circle().trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(UX.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
            }
            if progress == nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.primary)
            }
        }
        .frame(width: 30, height: 30)
        .padding(7)
        .contentShape(Circle())
    }
}

struct BrandMark: View {
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: "bag.fill").resizable().scaledToFit().foregroundStyle(.white).padding(size * 0.23).frame(width: size, height: size)
            .background(UX.accentGradient)
            .clipShape(RoundedRectangle(cornerRadius: size * UX.iconCorner, style: .continuous)).accessibilityHidden(true)
    }
}

struct EmptyState: View {
    let title: String
    let message: String
    let symbol: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .medium)).foregroundStyle(UX.accent)
                .padding(.bottom, 6)
            Text(title).font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(Color.primary).multilineTextAlignment(.center)
            Text(message).font(.subheadline).foregroundStyle(Color.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(CapsuleButtonStyle()).padding(.top, 8)
            }
        }.padding(.vertical, 28).frame(maxWidth: .infinity).padding(.horizontal, 12)
    }
}

struct InlineIssue: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.subheadline).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                if let retry { Button("重试", action: retry).buttonStyle(CapsuleButtonStyle()) }
            }
        }.padding(.vertical, 6)
    }
}

/// In-list search field. `capsule` is the App Store search-tab bar: a
/// full-width pill that searches from the keyboard's Search key.
struct SearchInput: View {
    @Binding var text: String
    var placeholder: String
    var capsule = false
    var submit: (() -> Void)? = nil
    var clear: (() -> Void)? = nil
    @FocusState private var focused: Bool
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.secondary)
            TextField(placeholder, text: $text).font(.subheadline).foregroundStyle(Color.primary).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).focused($focused)
                .onSubmit { focused = false; if !trimmed.isEmpty { submit?() } }
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = ""; clear?() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(uiColor: .tertiaryLabel)).frame(width: 32, height: 32) }
                    .buttonStyle(.borderless).accessibilityLabel("清空输入")
            }
            if submit != nil && !capsule {
                Button { focused = false; submit?() } label: { Text("搜索").font(.subheadline.weight(.semibold)) }
                    .buttonStyle(.borderless)
                    .disabled(trimmed.isEmpty)
                    .accessibilityLabel("搜索应用").accessibilityIdentifier("search.submit")
            }
        }
        .padding(.leading, capsule ? 14 : 10).padding(.trailing, capsule ? 6 : 8)
        .frame(minHeight: 48)
        .background(UX.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(UX.border))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

/// A section header's 刷新 that turns into a small spinner while busy, in
/// the same place, so nothing around it moves. Taps while busy are ignored.
struct RefreshButton: View {
    let busy: Bool
    let action: () -> Void
    @State private var showsSpinner = false
    var body: some View {
        ZStack(alignment: .trailing) {
            Button("刷新") { if !busy { action() } }
                .font(.body).textCase(nil)
                .opacity(showsSpinner ? 0 : 1)
            if showsSpinner { ProgressView().controlSize(.small).transition(.opacity) }
        }
        .revealAfterDelay(busy, into: $showsSpinner)
        .accessibilityValue(busy ? "正在刷新" : "")
    }
}

/// Root-tab chrome that pairs with `PageHeader`. The navigation bar stays
/// visible (hiding it made the page jump when popping back from a pushed
/// page); it shows the small title only once the header has scrolled away.
struct RootTabBar: ViewModifier {
    let title: String
    let headerScrolledAway: Bool
    func body(content: Content) -> some View {
        content.navigationTitle("商店下载").navigationBarTitleDisplayMode(.inline)
    }
}
extension View {
    /// Sets `shown` once `active` has lasted a moment and clears it as soon
    /// as it ends, so quick work (a cache hit) never flashes a spinner.
    func revealAfterDelay(_ active: Bool, into shown: Binding<Bool>, delay: Duration = .milliseconds(300)) -> some View {
        task(id: active) {
            guard active else {
                if shown.wrappedValue { withAnimation(.easeOut(duration: 0.15)) { shown.wrappedValue = false } }
                return
            }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.15)) { shown.wrappedValue = true }
        }
    }
    func rootTabBar(_ title: String, headerScrolledAway: Bool) -> some View {
        modifier(RootTabBar(title: title, headerScrolledAway: headerScrolledAway))
    }
    /// Reports whether this view has scrolled up under the navigation bar.
    func onScrolledUnderBar(_ action: @escaping (Bool) -> Void) -> some View {
        onGeometryChange(for: Bool.self) { proxy in
            proxy.frame(in: .global).maxY < 104
        } action: { action($0) }
    }
}

/// App Store root-tab header: large title with the trailing control (the
/// account avatar) on the same line, instead of a separate toolbar row.
struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(.system(size: 32, weight: .bold, design: .rounded)).foregroundStyle(Color.primary).lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
    }
}
extension PageHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

struct TaskStatusPill: View {
    let status: DownloadStatus
    private var color: Color {
        switch status {
        case .failed: return .red
        case .completed: return .green
        case .paused: return .secondary
        default: return UX.tint
        }
    }
    var body: some View {
        // Not a Label: inside List rows a Label gets the list's icon column,
        // which leaves a wide gap between the glyph and the text.
        HStack(spacing: 4) {
            Image(systemName: status.symbol).imageScale(.small)
            Text(status.title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

/// Small outlined capsule for platform and state tags (iOS, 已下架…).
struct TagBadge: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(nil)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5))
            .fixedSize()
    }
}

struct AppSkeleton: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.tertiarySystemFill)).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill)).frame(width: 150, height: 13)
                RoundedRectangle(cornerRadius: 4).fill(Color(.quaternarySystemFill)).frame(width: 100, height: 10)
            }
            Spacer()
            Capsule().fill(Color(.tertiarySystemFill)).frame(width: 74, height: 30)
        }.padding(.vertical, 6).accessibilityHidden(true)
    }
}

/// One cell of the App Store product page's horizontal info strip.
struct InfoStripItem: View {
    let caption: String
    let value: String
    var detail: String? = nil
    var symbol: String? = nil
    var body: some View {
        VStack(spacing: 4) {
            Text(caption).font(.caption2.weight(.semibold)).foregroundStyle(Color.secondary).lineLimit(1)
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.title3.weight(.semibold))
                } else {
                    Text(value).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(Color.secondary)
            .frame(height: 26)
            Text(detail ?? (symbol == nil ? " " : value)).font(.caption).foregroundStyle(Color.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Six separate digit boxes like Apple's two-factor screen. Backed by one
/// hidden one-time-code field so paste and SMS/AutoFill keep working.
struct VerificationCodeField: View {
    @Binding var code: String
    var length = 6
    var disabled = false
    var onComplete: (String) -> Void
    @FocusState private var focused: Bool
    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .disabled(disabled)
                .foregroundStyle(.clear).tint(.clear)
                .frame(width: 1, height: 1).opacity(0.02)
                .accessibilityIdentifier("apple.verification.code")
                .onChange(of: code) { _, value in
                    let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(length))
                    if digits != value { code = digits; return }
                    if digits.count == length { onComplete(digits) }
                }
            HStack(spacing: 10) {
                ForEach(0..<length, id: \.self) { index in
                    let characters = Array(code)
                    let current = index == characters.count && focused
                    Text(index < characters.count ? String(characters[index]) : "")
                        .font(.title.monospacedDigit().weight(.semibold))
                        .frame(width: 44, height: 56)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(current ? UX.tint : Color(.separator), lineWidth: current ? 2 : 0.5))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("验证码，已输入 \(code.count) 位")
        }
        .onAppear { if !disabled { focused = true } }
        .onChange(of: disabled) { _, value in if !value { focused = true } }
    }
}

struct StoreAmbientBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            UX.background
            RadialGradient(colors: [UX.accent.opacity(scheme == .dark ? 0.16 : 0.10), .clear], center: UnitPoint(x: 0.05, y: 0), startRadius: 0, endRadius: 440)
        }.ignoresSafeArea()
    }
}

struct ToolPageStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .foregroundStyle(Color.primary).tint(Color.primary)
            .background(StoreAmbientBackground()).scrollDismissesKeyboard(.interactively)
            .listSectionSpacing(16)
            .contentMargins(.bottom, 20, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 48)

    }
}
extension View { func toolPage() -> some View { modifier(ToolPageStyle()) } }

/// One line of text that, when it does not fit, scrolls once in place to
/// reveal the rest and returns, instead of being cut off with an ellipsis.
struct MarqueeText: View {
    let text: String
    var font: Font = .subheadline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    private var overflow: CGFloat { max(0, textWidth - boxWidth) }
    var body: some View {
        // The hidden copy sets the line height and takes the available width.
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Text(text).font(font).lineLimit(1).fixedSize()
                    .offset(x: offset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    if overflow > 0 {
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 14)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isStaticText)
            .task(id: overflow) {
                offset = 0
                guard overflow > 1, !reduceMotion else { return }
                do {
                    try await Task.sleep(for: .milliseconds(900))
                    withAnimation(.easeInOut(duration: max(0.8, Double(overflow) / 35))) { offset = -overflow - 14 }
                    try await Task.sleep(for: .milliseconds(Int(max(0.8, Double(overflow) / 35) * 1000) + 1200))
                    withAnimation(.easeInOut(duration: 0.45)) { offset = 0 }
                } catch { offset = 0 }
            }
    }
}

extension AnyTransition {
    /// Replaces a status label or button without the old and new content
    /// being visible at the same time: the old one fades out quickly, then
    /// the new one fades and scales in.
    static var statusSwap: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.92))
                .animation(.easeOut(duration: 0.18).delay(0.1)),
            removal: .opacity.animation(.easeIn(duration: 0.1)))
    }
}

// Native sheets inherit the same typography and keep their own Done/Cancel controls.
extension View {
    func storeSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                    @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        sheet(item: item, onDismiss: onDismiss) { item in
            content(item).environment(\.storeIsModal, true).foregroundStyle(Color.primary).tint(Color.primary)
        }
    }
    func storeSheet<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                @ViewBuilder content: @escaping () -> Sheet) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().environment(\.storeIsModal, true).foregroundStyle(Color.primary).tint(Color.primary)
        }
    }
}

struct StoreMetric {
    let title: String
    let value: String
}

/// A compact overview uses the same hierarchy as Retools tool cards.
struct StoreOverviewCard: View {
    let title: String
    let detail: String
    let symbol: String
    var metrics: [StoreMetric] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 46, height: 46).background(UX.accentGradient, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(Color.primary)
                    Text(detail).font(.subheadline).foregroundStyle(Color.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !metrics.isEmpty {
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    ForEach(metrics.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metrics[index].value).font(.system(.headline, design: .rounded)).foregroundStyle(Color.primary)
                                .monospacedDigit().contentTransition(.numericText())
                            Text(metrics[index].title).font(.caption).foregroundStyle(Color.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(UX.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(UX.border))
    }
}
extension View {
    func storeOverviewRow() -> some View {
        listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}
