import SwiftUI
import ContainerControls

struct FloatingDockSettingsView: View {
    @AppStorage("RetoolsFloatingControlsEnabled") private var enabled = true
    @AppStorage("RetoolsFloatingLeft") private var left = false
    @AppStorage("RetoolsDockAppearance") private var appearance = 0
    @AppStorage("RetoolsDockOpacity") private var opacity = 0.94
    var body: some View {
        Form {
            Section { Toggle("开启悬浮侧栏", isOn: $enabled) }
            Section {
                Picker("显示在", selection: $left) { Text("左侧").tag(true); Text("右侧").tag(false) }.pickerStyle(.segmented)
            } header: { Text("贴边位置") } footer: { Text("收起时可以自由拖动，松手后吸附到最近一侧；点击手柄展开。") }
            Section("侧栏外观") {
                Picker("日间与夜间", selection: $appearance) { Text("跟随系统").tag(0); Text("日间模式").tag(1); Text("夜间模式").tag(2) }
                LabeledContent("不透明度", value: opacity.formatted(.percent.precision(.fractionLength(0))))
                Slider(value: $opacity, in: 0.65...1, step: 0.01).accessibilityLabel("侧栏不透明度")
            }
            Section {
                Label("点击展开；拖动顶部或主页按钮调整位置", systemImage: "hand.draw")
                Label("点应用切换，点栏外收起", systemImage: "app.badge")
                Label("长按应用或主页查看更多操作", systemImage: "hand.tap")
            } header: { Text("使用方式") } footer: { Text("切换应用会重启客体进程，保留对应空间的数据。") }
        }.scrollContentBackground(.hidden).ambientBackground().navigationTitle("悬浮侧栏").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
            .onChange(of: left) { _, _ in RetoolsContainerControls.refreshPreferences() }
            .onChange(of: appearance) { _, _ in RetoolsContainerControls.refreshPreferences() }
            .onChange(of: opacity) { _, _ in RetoolsContainerControls.refreshPreferences() }
            .onChange(of: enabled) { _, _ in RetoolsContainerControls.refreshPreferences() }
    }
}
