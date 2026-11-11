import SwiftUI
import QuickLook
import ImageIO

struct AIAttachmentPreview: View {
    let file: URL?
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let file { AIQuickLookController(file: file, title: title) }
                else { ContentUnavailableView("附件暂不可用", systemImage: "doc.questionmark") }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("ai.preview.close") } }
        }.tint(AIInterface.tint)
    }
}

private struct AIQuickLookController: UIViewControllerRepresentable {
    let file: URL
    let title: String
    final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(file: URL, title: String) { previewItemURL = file; previewItemTitle = title }
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let item: Item
        init(file: URL, title: String) { item = Item(file: file, title: title) }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { item }
    }
    func makeCoordinator() -> Coordinator { Coordinator(file: file, title: title) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) { }
}

/// 图片查看，与系统相册相同的姿态：只有图片本身移动。
///
/// 打开时图片从对话里缩略图的位置飞到屏幕中央，同时放大、圆角收起，背景的暗色模糊与按钮随之淡入；
/// 下滑时图片跟手移动并略微缩小，背景随距离变淡，松手后飞回缩略图或弹回中央；关闭按钮同样飞回原处。
/// 双指缩放、双击放大，放大后拖动查看；轻点显示或隐藏按钮。GIF 在静止时播放动画。
struct AIImageViewer: View {
    let file: URL?
    let title: String
    /// 缩略图在屏幕上的位置；没有时从中央淡入淡出。
    let sourceFrame: CGRect?
    var sourceCornerRadius: CGFloat = 13
    let onSave: () async -> Bool
    /// 关闭动画结束后调用，由调用方移除查看界面（不带动画）。
    let onClose: () -> Void

    @State private var progress: CGFloat = 0
    @State private var drag: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var showsChrome = true
    @State private var saved = false
    @State private var closing = false
    @State private var still: UIImage?
    @State private var animated = false

    private static let open = Animation.spring(response: 0.44, dampingFraction: 0.86)
    private static let settle = Animation.spring(response: 0.36, dampingFraction: 0.9)
    /// 飞回缩略图不能过冲，否则落地时会比缩略图小一圈再弹回。
    private static let flyBack = Animation.smooth(duration: 0.38)

    var body: some View {
        // 外层读取安全区（不忽略安全区时才拿得到），内容本身铺满全屏，坐标与缩略图的全局坐标一致。
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let screen = CGRect(x: 0, y: 0, width: geometry.size.width + insets.leading + insets.trailing,
                                height: geometry.size.height + insets.top + insets.bottom)
            let target = fittedFrame(in: screen, safeArea: insets)
            let source = sourceFrame ?? target
            let pull = min(hypot(drag.width, drag.height) / 320, 1)
            let frame = Self.interpolate(source, target, progress)
            let resting = progress == 1 && drag == .zero && !closing
            ZStack {
                backdrop
                    .opacity(Double(progress * (1 - pull * 0.85)))
                    .ignoresSafeArea()
                imageLayer(size: frame.size, resting: resting)
                    .clipShape(RoundedRectangle(cornerRadius: sourceCornerRadius * (1 - progress), style: .continuous))
                    .scaleEffect(scale * (1 - pull * 0.22))
                    .shadow(color: .black.opacity(0.3 * Double(progress)), radius: 24, x: 0, y: 12)
                    .opacity(sourceFrame == nil ? Double(progress) : 1)
                    .position(x: frame.midX + pan.width + drag.width, y: frame.midY + pan.height + drag.height)
                    .gesture(SimultaneousGesture(magnify, dragGesture))
                    .onTapGesture(count: 2) { withAnimation(Self.settle) { if scale > 1 { resetZoom() } else { scale = 2.5; baseScale = 2.5 } } }
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showsChrome.toggle() } }
                    .accessibilityLabel(title)
                chrome
                    .padding(.top, insets.top)
                    .opacity(showsChrome ? Double(progress * (1 - pull)) : 0)
                    .allowsHitTesting(showsChrome && progress > 0.9)
            }
            .frame(width: screen.width, height: screen.height)
            .ignoresSafeArea()
        }
        .statusBarHidden(!showsChrome && !closing)
        .environment(\.colorScheme, .dark)
        .onAppear {
            still = file.flatMap { UIImage(contentsOfFile: $0.path) }
            animated = file.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.map { CGImageSourceGetCount($0) > 1 } ?? false
            withAnimation(Self.open) { progress = 1 }
        }
    }

    // MARK: Layers

    private var backdrop: some View {
        ZStack {
            Color.black
            if let still {
                Color.clear.overlay { Image(uiImage: still).resizable().scaledToFill() }
                    .clipped().blur(radius: 50, opaque: true).opacity(0.55)
            }
        }
    }

    @ViewBuilder private func imageLayer(size: CGSize, resting: Bool) -> some View {
        if let still {
            Image(uiImage: still).resizable().scaledToFill()
                .frame(width: size.width, height: size.height).clipped()
                .overlay { if animated && resting, let file { AnimatedImageView(file: file) } }
        } else {
            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.6)).frame(width: size.width, height: size.height)
        }
    }

    private var chrome: some View {
        HStack {
            Button { close() } label: { Image(systemName: "xmark").font(.headline).modifier(ViewerButtonBackground()) }
                .accessibilityLabel("关闭").accessibilityIdentifier("ai.viewer.close")
            Spacer()
            if let file {
                ShareLink(item: file) { Image(systemName: "square.and.arrow.up").font(.headline).modifier(ViewerButtonBackground()) }
                    .accessibilityLabel("分享")
            }
            Button { Task { saved = await onSave() } } label: {
                Image(systemName: saved ? "checkmark" : "square.and.arrow.down").font(.headline).modifier(ViewerButtonBackground())
            }.accessibilityLabel(saved ? "已保存" : "保存到相册").disabled(saved)
        }
        .foregroundStyle(.white).padding(.horizontal, 16).padding(.top, 6)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Geometry

    /// 图片在屏幕中按比例完整显示的位置（避开顶部按钮和底部安全区）。
    private func fittedFrame(in screen: CGRect, safeArea: EdgeInsets) -> CGRect {
        let area = screen.inset(by: UIEdgeInsets(top: safeArea.top + 56, left: 0, bottom: safeArea.bottom + 24, right: 0))
        guard let size = still?.size, size.width > 0, size.height > 0 else { return area.insetBy(dx: 40, dy: 120) }
        let ratio = min(area.width / size.width, area.height / size.height)
        let fitted = CGSize(width: size.width * ratio, height: size.height * ratio)
        return CGRect(x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    private static func interpolate(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    // MARK: Gestures

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in guard !closing else { return }; scale = min(max(baseScale * value.magnification, 1), 6) }
            .onEnded { _ in baseScale = scale; if scale <= 1.02 { withAnimation(Self.settle) { resetZoom() } } }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard !closing else { return }
                if scale > 1 { pan = CGSize(width: basePan.width + value.translation.width, height: basePan.height + value.translation.height) }
                else { drag = value.translation }
            }
            .onEnded { value in
                guard !closing else { return }
                if scale > 1 { basePan = pan; return }
                if value.translation.height > 110 || value.predictedEndTranslation.height > 320 { close() }
                else { withAnimation(Self.settle) { drag = .zero } }
            }
    }

    private func resetZoom() { scale = 1; baseScale = 1; pan = .zero; basePan = .zero }

    /// 飞回缩略图（没有缩略图位置时淡出），动画结束后再移除查看界面。
    private func close() {
        guard !closing else { return }
        closing = true
        withAnimation(Self.flyBack, completionCriteria: .removed) {
            progress = 0; drag = .zero; resetZoom()
        } completion: { onClose() }
    }
}

/// 按比例完整显示图片；GIF 逐帧播放。
private struct AnimatedImageView: UIViewRepresentable {
    let file: URL
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal); view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = Self.load(file)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {}
    /// 只占用给定的空间，不按原图像素尺寸撑开。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 320))
    }

    static func load(_ file: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return UIImage(contentsOfFile: file.path) }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(contentsOfFile: file.path) }
        var frames: [UIImage] = [], duration: Double = 0
        for index in 0..<min(count, 300) {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += delay < 0.02 ? 0.1 : delay
            frames.append(UIImage(cgImage: frame))
        }
        return frames.isEmpty ? UIImage(contentsOfFile: file.path) : UIImage.animatedImage(with: frames, duration: duration)
    }
}

/// 查看界面按钮统一的半透明圆底，在亮色或暗色图片上都看得清。
private struct ViewerButtonBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(width: 44, height: 44)
            .background(Circle().fill(.black.opacity(0.38)))
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .contentShape(Circle())
    }
}
