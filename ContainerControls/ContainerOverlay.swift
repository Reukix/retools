import SwiftUI
import UIKit
import ImageIO

private struct ControlSpace: Decodable { let id: UUID; let name: String }
private struct ControlRuntimeOptions: Decodable { let isHidden: Bool? }
private struct ControlApp: Decodable, Identifiable {
    let id: UUID
    let name: String
    let folder: String
    let iconFile: String?
    let selectedContainerID: UUID
    let containers: [ControlSpace]
    var runtimeOptions: ControlRuntimeOptions?
    var spaceName: String { containers.first { $0.id == selectedContainerID }?.name ?? "默认空间" }
}
private struct ControlWorkspace: Decodable { let containerApps: [ControlApp] }

@MainActor
private final class OverlayModel: ObservableObject {
    let root: URL
    let defaults: UserDefaults
    let currentFolder: String
    let preview: Bool
    let restart: () -> Void
    let quit: () -> Void
    @Published var apps: [ControlApp] = []
    @Published var expanded = false
    @Published var appearance = 0
    @Published var opacity = 0.94
    @Published var busy = false
    @Published var message: String?
    @Published var center = CGPoint.zero
    @Published var isDragging = false
    var dockDragOffset = CGSize.zero
    /// 收起手柄的拖动位移，由 OverlayWindow 上的 UIPanGestureRecognizer 逐帧写入。
    @Published var tabDragOffset = CGSize.zero
    @Published var handleLifted = false
    private var icons: [UUID: UIImage] = [:]
    private var iconNames: [UUID: String] = [:]
    var size = CGSize.zero
    var insets = UIEdgeInsets.zero
    var isWorkbench: Bool { currentFolder.isEmpty }
    var isLeft: Bool { center.x < size.width / 2 }
    var tabFrame: CGRect { FloatingControlGeometry.tabFrame(center: center, size: size, insets: insets) }
    var dockFrame: CGRect { FloatingControlGeometry.dockFrame(center: center, size: size, insets: insets, appCount: apps.count) }
    var presentedDockFrame: CGRect { dockFrame.offsetBy(dx: dockDragOffset.width, dy: dockDragOffset.height) }
    var presentedTabFrame: CGRect { tabFrame.offsetBy(dx: tabDragOffset.width, dy: tabDragOffset.height) }
    var support: URL { root.appendingPathComponent("Library/Application Support/Retools") }
    init(root: URL, defaults: UserDefaults, currentFolder: String, preview: Bool = false, restart: @escaping () -> Void, quit: @escaping () -> Void) {
        self.root = root; self.defaults = defaults; self.currentFolder = currentFolder; self.preview = preview; self.restart = restart; self.quit = quit
    }
    func layout(size: CGSize, insets: UIEdgeInsets) {
        guard size.width > 0, size.height > 0, size != self.size || insets != self.insets else { return }
        self.size = size; self.insets = insets
        applyPreferences()
    }
    func move(_ point: CGPoint) { center = FloatingControlGeometry.clamp(point, size: size, insets: insets) }
    func snap() {
        center = FloatingControlGeometry.snap(center, size: size, insets: insets)
        defaults.set(center.x < size.width / 2, forKey: "RetoolsFloatingLeft")
        defaults.set(Double(center.y / max(1, size.height)), forKey: "RetoolsFloatingY")
    }
    func refreshApps() {
        message = nil
        if preview {
            let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            apps = [ControlApp(id: first, name: "当前应用", folder: currentFolder, iconFile: nil, selectedContainerID: first, containers: [ControlSpace(id: first, name: "默认空间")]),
                    ControlApp(id: second, name: "另一个应用", folder: second.uuidString + ".app", iconFile: nil, selectedContainerID: second, containers: [ControlSpace(id: second, name: "独立空间")])]
            for index in 3...8 {
                let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
                apps.append(ControlApp(id: id, name: "示例应用 \(index)", folder: id.uuidString + ".app", iconFile: nil, selectedContainerID: id, containers: [ControlSpace(id: id, name: "默认空间")]))
            }
        } else {
            do {
                let url = support.appendingPathComponent("workspace.json"), values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 10_000_000 else { throw ContainerControlFailure("无法读取容器应用列表。") }
                apps = try JSONDecoder().decode(ControlWorkspace.self, from: Data(contentsOf: url)).containerApps.filter { app in
                    app.folder == app.id.uuidString + ".app" && app.runtimeOptions?.isHidden != true && app.containers.contains { $0.id == app.selectedContainerID }
                }
            } catch { message = "应用列表读取失败，请返回 Retools 后重试。"; apps = [] }
        }
        for app in apps {
            guard let name = app.iconFile, name == (name as NSString).lastPathComponent, iconNames[app.id] != name else { continue }
            iconNames[app.id] = name
            let url = support.appendingPathComponent("Icons/" + name)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 144, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                icons[app.id] = UIImage(cgImage: image)
            }
        }
    }
    func open() { if apps.isEmpty { refreshApps() }; message = nil; expanded = true }
    func close() { expanded = false }
    func applyPreferences() {
        appearance = defaults.object(forKey: "RetoolsDockAppearance") == nil ? 0 : defaults.integer(forKey: "RetoolsDockAppearance")
        opacity = min(1, max(0.65, defaults.object(forKey: "RetoolsDockOpacity") == nil ? 0.94 : defaults.double(forKey: "RetoolsDockOpacity")))
        guard size.width > 0, !isDragging else { return }
        let fraction = defaults.object(forKey: "RetoolsFloatingY") == nil ? 0.55 : defaults.double(forKey: "RetoolsFloatingY")
        center = FloatingControlGeometry.snap(CGPoint(x: defaults.bool(forKey: "RetoolsFloatingLeft") ? 0 : size.width, y: size.height * fraction), size: size, insets: insets)
    }
    func select(_ app: ControlApp) {
        guard app.folder != currentFolder else { close(); return }
        perform(ContainerControlRequest(action: .switchApp, appID: app.id, containerID: app.selectedContainerID), previewMessage: "已请求切换到另一个应用")
    }
    func workbench() { if isWorkbench { close() } else { perform(ContainerControlRequest(action: .workbench), previewMessage: "已请求返回 Retools") } }
    private func perform(_ request: ContainerControlRequest, previewMessage: String) {
        guard !busy else { return }
        if preview { message = previewMessage; close(); return }
        do {
            try ContainerControlMailbox.write(request, support: support)
            UserDefaults.standard.synchronize()
            busy = true; close(); restart()
        } catch { message = error.localizedDescription }
    }
    func exitContainer() {
        if preview { message = "已请求退出容器"; close(); return }
        guard !busy else { return }
        busy = true; UserDefaults.standard.synchronize(); quit()
    }
    func icon(for app: ControlApp) -> UIImage? {
        icons[app.id]
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var railOrigin: CGRect?
    @State private var railOffset = CGSize.zero
    @State private var scrollAxis: FloatingDragAxis = .undecided
    @GestureState private var railDragging = false
    @GestureState private var scrollDragging = false
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86) }
    private var scheme: ColorScheme { model.appearance == 0 ? systemScheme : (model.appearance == 1 ? .light : .dark) }
    private var accent: Color { Color(red: 0.94, green: 0.36, blue: 0.17) }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if model.expanded {
                    dock.frame(width: model.dockFrame.width, height: model.dockFrame.height)
                    .position(x: model.dockFrame.midX, y: model.dockFrame.midY)
                    .offset(railOffset)
                    .transition(.offset(x: model.isLeft ? -76 : 76).combined(with: .opacity))
                }
                if !model.expanded {
                Button { withAnimation(spring) { model.open() } } label: {
                    collapsedHandle.frame(width: 44, height: 76).contentShape(Rectangle())
                }.buttonStyle(.plain).frame(width: 44, height: 76)
                    .position(x: model.tabFrame.midX, y: model.tabFrame.midY).offset(model.tabDragOffset)
                    .allowsHitTesting(!model.expanded).accessibilityHidden(model.expanded)
                    .accessibilityLabel("展开容器侧栏").accessibilityHint("点击展开，拖动自由移动，松手后贴边")
                    .accessibilityIdentifier("container.controls.handle")
                }
                if model.preview, let message = model.message {
                    Text(message).font(.caption).padding(8).background(.regularMaterial, in: Capsule()).position(x: geometry.size.width / 2, y: geometry.size.height - 170).accessibilityIdentifier("container.controls.feedback")
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.ignoresSafeArea().environment(\.colorScheme, scheme)
        // 拖动时位置跟手、不做动画；手柄自身的提起形变由内部的 animation(value:) 驱动。
        .transaction { if model.isDragging { $0.animation = nil } }
        .onChange(of: railDragging) { _, dragging in if !dragging { deferCancelledDragCleanup() } }
        .onChange(of: scrollDragging) { _, dragging in
            if dragging { model.isDragging = true }
            else { DispatchQueue.main.async { if !scrollDragging { scrollAxis = .undecided; if !model.handleLifted && !railDragging { model.isDragging = false } } } }
        }
        .alert("容器切换失败", isPresented: Binding(get: { model.message != nil && !model.preview }, set: { if !$0 { model.message = nil } })) {
            Button("好", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
    /// 收起手柄：平时半藏在屏幕边缘；拖动时从边缘拉出成完整胶囊、略微放大并加深阴影，松手后弹回贴边。
    private var collapsedHandle: some View {
        let lifted = model.handleLifted
        let width: CGFloat = lifted ? 30 : 24, height: CGFloat = lifted ? 66 : 60
        return Capsule().fill(lifted ? AnyShapeStyle(accent) : AnyShapeStyle(.primary.opacity(0.42)))
            .frame(width: lifted ? 4 : 3, height: lifted ? 26 : 22)
            .offset(x: lifted ? 0 : (model.isLeft ? 6 : -6))
            .frame(width: width, height: height)
            .background { DockSurface(cornerRadius: width / 2, opacity: lifted ? max(model.opacity, 0.92) : model.opacity) }
            .overlay { Capsule().strokeBorder(accent.opacity(lifted ? 0.35 : 0), lineWidth: 1) }
            .shadow(color: .black.opacity(lifted ? (scheme == .dark ? 0.34 : 0.18) : (scheme == .dark ? 0.16 : 0.08)), radius: lifted ? 14 : 6, y: lifted ? 6 : 2)
            .scaleEffect(lifted ? 1.06 : 1)
            .offset(x: lifted ? 0 : (model.isLeft ? -22 : 22))
            .animation(spring, value: lifted)
            .sensoryFeedback(.impact(weight: .light), trigger: lifted)
    }
    private var railDrag: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global).updating($railDragging) { _, dragging, _ in dragging = true }.onChanged { value in
            if railOrigin == nil { railOrigin = model.dockFrame; model.isDragging = true }
            railOffset = value.translation; model.dockDragOffset = value.translation
        }.onEnded { value in
            let original = railOrigin ?? model.dockFrame
            let moved = original.offsetBy(dx: value.translation.width, dy: value.translation.height)
            let target = FloatingControlGeometry.dockFrame(center: CGPoint(x: moved.midX, y: moved.midY), size: model.size, insets: model.insets, appCount: model.apps.count)
            model.isDragging = false
            withAnimation(spring) {
                model.center = CGPoint(x: target.midX, y: target.midY)
                railOffset = .zero; model.dockDragOffset = .zero
                model.snap()
            }
            railOrigin = nil
        }
    }
    private func finishCancelledDrag() {
        guard railOrigin != nil else { return }
        model.isDragging = false; railOrigin = nil
        railOffset = .zero; model.dockDragOffset = .zero
    }
    private func deferCancelledDragCleanup() {
        // GestureState can reset before onEnded. Let normal completion commit
        // its physical frame before cleaning up a genuinely cancelled gesture.
        DispatchQueue.main.async { if !railDragging { finishCancelledDrag() } }
    }
    private var dock: some View {
        VStack(spacing: 0) {
            Button { withAnimation(spring) { model.close() } } label: {
                Capsule().fill(.primary.opacity(0.2)).frame(width: 18, height: 3).frame(width: 72, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("收起侧栏").accessibilityIdentifier("container.controls.close").highPriorityGesture(railDrag)
            ScrollView(.vertical) {
                LazyVStack(spacing: 14) {
                    ForEach(model.apps) { app in
                        Button { model.select(app) } label: {
                            Group {
                                if let image = model.icon(for: app) { Image(uiImage: image).resizable().scaledToFill() }
                                else if model.preview {
                                    let index = model.apps.firstIndex(where: { $0.id == app.id }) ?? 0
                                    ZStack { RoundedRectangle(cornerRadius: 12).fill([Color.blue, .purple, .orange, .green, .cyan, .indigo, .pink, .teal][index % 8].gradient); Image(systemName: ["bolt.fill", "headphones", "leaf.fill", "paperplane.fill", "gamecontroller.fill", "shippingbox.fill", "star.fill", "safari.fill"][index % 8]).font(.system(size: 23, weight: .medium)).foregroundStyle(.white) }
                                } else { ZStack { RoundedRectangle(cornerRadius: 11).fill(accent.opacity(0.2)); Image(systemName: "app.fill").font(.system(size: 25)).foregroundStyle(accent) } }
                            }.frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
                                .overlay(alignment: .bottomTrailing) { if app.folder == model.currentFolder { Circle().fill(.green).frame(width: 6, height: 6).padding(2).background(.regularMaterial, in: Circle()).offset(x: 3, y: 3) } }
                        }.buttonStyle(.plain).disabled(model.busy).accessibilityLabel(app.name + (app.folder == model.currentFolder ? "，当前应用" : "，" + app.spaceName)).accessibilityIdentifier("container.controls.app.\(app.id.uuidString)")
                            .contextMenu {
                                Text(app.name); Text(app.spaceName)
                                if app.folder != model.currentFolder { Button("打开应用") { model.select(app) } }
                                if app.folder == model.currentFolder { Button("退出当前容器", role: .destructive) { model.exitContainer() } }
                            }
                    }
                    if model.apps.isEmpty { Image(systemName: "app.dashed").font(.title2).foregroundStyle(.secondary).frame(height: 48) }
                }.padding(.top, 2).padding(.bottom, 10).frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden).simultaneousGesture(scrollDismiss)
            Rectangle().fill(.primary.opacity(0.09)).frame(height: 0.5).padding(.horizontal, 16)
            Button { model.workbench() } label: {
                Image(systemName: "house").font(.system(size: 20, weight: .semibold)).foregroundStyle(.primary.opacity(0.8)).frame(width: 44, height: 44)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).padding(.vertical, 10).accessibilityLabel("返回 Retools").accessibilityHint("长按可退出当前容器").accessibilityIdentifier("container.controls.workbench")
                .highPriorityGesture(railDrag)
                .contextMenu {
                    Button("返回 Retools") { model.workbench() }
                    if !model.isWorkbench { Button("退出当前容器", role: .destructive) { model.exitContainer() }.accessibilityIdentifier("container.controls.exit") }
                }
        }
        .background { DockSurface(cornerRadius: 26, opacity: model.opacity) }
        .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.09), radius: 16, y: 5).disabled(model.busy)
        .overlay(alignment: .leading) { Color.clear.frame(width: 9).contentShape(Rectangle()).gesture(railDrag).accessibilityHidden(true) }
        .overlay(alignment: .trailing) { Color.clear.frame(width: 9).contentShape(Rectangle()).gesture(railDrag).accessibilityHidden(true) }
    }
    private var scrollDismiss: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global).updating($scrollDragging) { _, dragging, _ in dragging = true }.onChanged { scrollAxis.lock(to: $0.translation) }.onEnded { value in
            defer { scrollAxis = .undecided }
            model.isDragging = false
            let outward = model.isLeft ? -value.translation.width : value.translation.width
            if scrollAxis == .horizontal, outward > 25 { withAnimation(spring) { model.close() } }
        }
    }
}

private struct DockSurface: View {
    let cornerRadius: CGFloat
    let opacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(Color(uiColor: .secondarySystemBackground))
            } else if #available(iOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape).opacity(opacity)
            } else {
                shape.fill(.ultraThinMaterial).opacity(opacity)
                    .overlay { shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
            }
        }.allowsHitTesting(false)
    }
}

@MainActor
private final class OverlayWindow: UIWindow {
    let model: OverlayModel
    /// 拖动开始时手柄可见胶囊的中心（半隐藏在边缘的那一截）。
    private var handleOrigin: CGPoint?
    init(scene: UIWindowScene?, model: OverlayModel) {
        self.model = model
        super.init(frame: scene?.coordinateSpace.bounds ?? UIScreen.main.bounds)
        if let scene { windowScene = scene }
        windowLevel = .alert + 2
        backgroundColor = .clear
        rootViewController = UIHostingController(rootView: OverlayView(model: model))
        rootViewController?.view.backgroundColor = .clear
        accessibilityIdentifier = "container.controls.window"
        // 收起手柄用 UIKit 拖动：SwiftUI 的 DragGesture 挂在 Button 上，真机触摸时会与按钮的按压手势争抢，
        // 导致拖动起步迟滞或中途丢失，手柄不跟手。平移手势逐帧读取位移，与手指保持一致。
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }
    // UIView 对挂在自身上的手势调用此方法：只在收起状态、手指落在手柄范围内时开始平移。
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer.view === self, recognizer is UIPanGestureRecognizer else { return super.gestureRecognizerShouldBegin(recognizer) }
        return !model.expanded && model.tabFrame.insetBy(dx: -6, dy: -6).contains(recognizer.location(in: self))
    }
    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: self)
        let spring: Animation? = UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.34, dampingFraction: 0.8)
        switch pan.state {
        case .began:
            handleOrigin = CGPoint(x: model.tabFrame.midX + (model.isLeft ? -22 : 22), y: model.tabFrame.midY)
            model.isDragging = true
            model.tabDragOffset = CGSize(width: translation.x, height: translation.y)
            withAnimation(spring) { model.handleLifted = true }
        case .changed:
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { model.tabDragOffset = CGSize(width: translation.x, height: translation.y) }
        case .ended, .cancelled, .failed:
            let origin = handleOrigin ?? model.center
            // 按松手速度预估落点，轻甩即可换边。
            let velocity = pan.state == .ended ? pan.velocity(in: self) : .zero
            let target = CGPoint(x: origin.x + translation.x + velocity.x * 0.12, y: origin.y + translation.y + velocity.y * 0.05)
            model.isDragging = false
            withAnimation(spring) {
                model.move(target); model.snap()
                model.tabDragOffset = .zero; model.handleLifted = false
            }
            handleOrigin = nil
        default: break
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); model.layout(size: bounds.size, insets: safeAreaInsets) }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if model.expanded, !model.presentedDockFrame.contains(point) {
            // UIKit places context-menu views above the hosting view. Their
            // actions must receive the touch before the outside-dismiss rule.
            if let hit = super.hitTest(point, with: event), hit !== rootViewController?.view, hit !== self { return hit }
            if !model.isDragging, event?.type == .touches {
                Task { @MainActor [weak model] in withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { model?.close() } }
            }
            return nil
        }
        guard model.expanded || model.presentedTabFrame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

@MainActor
@objc(RetoolsContainerControls)
public final class RetoolsContainerControls: NSObject {
    private static var active: RetoolsContainerControls?
    private var windows: [ObjectIdentifier: OverlayWindow] = [:]
    private var legacyWindow: OverlayWindow?
    private var observers: [NSObjectProtocol] = []
    private var UIKitStarted = false
    private let root: URL
    private let defaults: UserDefaults
    private let folder: String
    private let preview: Bool
    private let restart: () -> Void
    private let quit: () -> Void
    private init(root: URL, defaults: UserDefaults, folder: String, preview: Bool = false, restart: @escaping () -> Void, quit: @escaping () -> Void) {
        self.root = root; self.defaults = defaults; self.folder = folder; self.preview = preview; self.restart = restart; self.quit = quit
    }
    private func record(_ stage: String) {
        guard !preview else { return }
        let directory = root.appendingPathComponent("Library/Application Support/Retools/Diagnostics")
        let payload: [String: Any] = ["stage": stage, "context": folder.isEmpty ? "workbench" : "guest", "date": Date().timeIntervalSince1970, "windows": windows.count + (legacyWindow == nil ? 0 : 1)]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys).write(to: directory.appendingPathComponent(folder.isEmpty ? "container-controls-host.json" : "container-controls-guest.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { NSLog("[Retools] Could not save container-controls diagnostic") }
    }
    @objc(installWithHostRoot:defaults:currentFolder:currentContainer:restart:quit:)
    public static func install(hostRoot: String, defaults: UserDefaults, currentFolder: String, currentContainer: String, restart: @escaping () -> Void, quit: @escaping () -> Void) {
        guard active == nil, defaults.object(forKey: "RetoolsFloatingControlsEnabled") as? Bool != false else { return }
        let controller = RetoolsContainerControls(root: URL(fileURLWithPath: hostRoot), defaults: defaults, folder: currentFolder, restart: restart, quit: quit)
        active = controller; controller.record("installed-before-guest-main"); controller.observe()
    }
    public static func installWorkbench(hostRoot: String, defaults: UserDefaults, onRequest: @escaping () -> Void) {
        guard active == nil else { refreshPreferences(); return }
        let controller = RetoolsContainerControls(root: URL(fileURLWithPath: hostRoot), defaults: defaults, folder: "", restart: onRequest, quit: {})
        active = controller; controller.UIKitStarted = true; controller.record("installed-in-workbench"); controller.observe(); controller.connectScenes()
    }
    public static func refreshPreferences() {
        guard let controller = active, controller.UIKitStarted else { return }
        let enabled = controller.defaults.object(forKey: "RetoolsFloatingControlsEnabled") as? Bool != false
        for window in Array(controller.windows.values) + [controller.legacyWindow].compactMap({ $0 }) {
            window.model.applyPreferences(); if !window.model.isDragging { window.model.refreshApps() }; window.isHidden = !enabled
        }
        if enabled { controller.connectScenes() }
    }
    public static func finishWorkbenchRequest() {
        guard let controller = active, controller.folder.isEmpty else { return }
        for window in Array(controller.windows.values) + [controller.legacyWindow].compactMap({ $0 }) { window.model.busy = false }
    }
    private func observe() {
        for name in [UIApplication.didFinishLaunchingNotification, UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification, UIWindow.didBecomeVisibleNotification, UIScene.didDisconnectNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard !(note.object is OverlayWindow) else { return }
                Task { @MainActor in self?.UIKitStarted = true; self?.connectScenes() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { _ in
            Task { @MainActor in Self.refreshPreferences() }
        })
        // Installation happens before the guest's main(). Creating UIApplication
        // there would prevent a guest with a custom principal class from using it.
        // Guest launch/window notifications connect the overlay after UIKit starts.
        if preview { UIKitStarted = true; connectScenes() }
    }
    private func connectScenes() {
        guard defaults.object(forKey: "RetoolsFloatingControlsEnabled") as? Bool != false else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if scenes.isEmpty {
            if legacyWindow == nil, UIApplication.shared.windows.contains(where: { !($0 is OverlayWindow) && !$0.isHidden }) {
                let model = OverlayModel(root: root, defaults: defaults, currentFolder: folder, preview: preview, restart: restart, quit: quit)
                model.refreshApps(); model.applyPreferences()
                let window = OverlayWindow(scene: nil, model: model); legacyWindow = window; window.isHidden = false
                model.layout(size: window.bounds.size, insets: window.safeAreaInsets)
                record("legacy-window-visible")
            }
            return
        }
        legacyWindow?.isHidden = true; legacyWindow = nil
        let connected = Set(scenes.map(ObjectIdentifier.init))
        for id in windows.keys.filter({ !connected.contains($0) }) { windows[id]?.isHidden = true; windows.removeValue(forKey: id) }
        for scene in scenes where scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive {
            let key = ObjectIdentifier(scene)
            guard windows[key] == nil, scene.windows.contains(where: { !($0 is OverlayWindow) && !$0.isHidden }) else { continue }
            let model = OverlayModel(root: root, defaults: defaults, currentFolder: folder, preview: preview, restart: restart, quit: quit)
            model.refreshApps(); model.applyPreferences()
            let window = OverlayWindow(scene: scene, model: model); windows[key] = window
            window.isHidden = false
            model.layout(size: window.bounds.size, insets: window.safeAreaInsets)
            record("scene-window-visible")
        }
    }
    #if DEBUG
    public static func showPreview() {
        guard active == nil else { return }
        UserDefaults.standard.removePersistentDomain(forName: "RetoolsControlsPreview")
        let controller = RetoolsContainerControls(root: URL(fileURLWithPath: NSHomeDirectory()), defaults: UserDefaults(suiteName: "RetoolsControlsPreview")!, folder: "11111111-1111-1111-1111-111111111111.app", preview: true, restart: {}, quit: {})
        active = controller; controller.observe()
    }
    #endif
}
