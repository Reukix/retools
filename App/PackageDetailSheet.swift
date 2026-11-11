import SwiftUI

struct PackageDetailSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let packageID: UUID
    var initialSigning = false
    @State private var showSigning = false
    @State private var confirmDelete = false
    private var package: AppPackage? { store.state.packages.first { $0.id == packageID } }
    var body: some View {
        NavigationStack {
            if initialSigning { PackageSigningView(packageID: packageID) }
            else if let package {
                ScrollView {
                    VStack(alignment: .leading, spacing: 23) {
                        HStack(spacing: 17) {
                            AppIcon(name: package.name, url: store.iconURL(package.iconFile), size: 76)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(package.name).font(.system(size: 24, weight: .bold)).lineLimit(2)
                                Text("v\(package.version) (\(package.build))").font(.system(size: 13)).foregroundStyle(Color.secondary)
                                StatusPill(title: package.isEncrypted ? "加密应用" : "本地 IPA", color: package.isEncrypted ? .secondary : Palette.accent)
                            }
                        }
                        VStack(spacing: 6) {
                            InfoRow(title: "应用标识", value: package.bundleID)
                            InfoRow(title: "文件大小", value: package.sizeLabel)
                            InfoRow(title: "最低系统", value: "iOS \(package.minimumOS)")
                            InfoRow(title: "导入时间", value: package.importedAt.formatted(date: .abbreviated, time: .shortened))
                        }.workspaceCard()
                        NavigationLink { EmbeddedLibrariesView(target: .package(packageID), onlyPlugins: true) } label: {
                            HStack {
                                Label("已注入插件", systemImage: "puzzlepiece.extension")
                                Spacer()
                                if package.embeddedLibraryInspectionVersion == EmbeddedLibraryInspector.version, let libraries = package.embeddedLibraries { Text("\(libraries.filter(\.isInjectedPlugin).count)").foregroundStyle(Color.secondary) }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.secondary)
                            }.font(.subheadline).workspaceCard()
                        }.accessibilityIdentifier("package.embeddedLibraries")
                        if package.isEncrypted {
                            Label("此应用的可执行文件已加密，无法重新签名或在容器中运行。", systemImage: "lock").font(.system(size: 13)).foregroundStyle(Color.secondary).lineSpacing(4).workspaceCard()
                        } else {
                            VStack(spacing: 12) {
                                PrimaryButton(title: "签名应用", symbol: "signature") { showSigning = true }.accessibilityIdentifier("package.sign")
                                Button { store.install(package); dismiss() } label: {
                                    Label("导入到容器", systemImage: "shippingbox").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 16)
                                        .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                                }.buttonStyle(.plain).accessibilityIdentifier("package.container")
                            }
                        }
                        if let url = store.exportURL(package) {
                            VStack(alignment: .leading, spacing: 14) {
                                SectionHeading(title: "签名输出")
                                if let date = package.signedAt { InfoRow(title: "签名时间", value: date.formatted(date: .abbreviated, time: .shortened)) }
                                if let id = package.signedBundleID { InfoRow(title: "输出标识", value: id) }
                                if let date = package.signedExpiresAt { InfoRow(title: "凭据到期", value: date.formatted(date: .abbreviated, time: .omitted)) }
                                ShareLink(item: url) { Label("导出签名输出", systemImage: "square.and.arrow.up").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 8) }
                                Text("通过共享菜单保存到「文件」，或交给支持 IPA 的安装工具。").font(.system(size: 12)).foregroundStyle(Color.secondary)
                            }.workspaceCard()
                        }
                        Button("从应用库移除", role: .destructive) { confirmDelete = true }.font(.system(size: 13)).frame(maxWidth: .infinity).padding(.top, 5).disabled(store.isWorking)
                    }.padding(22).frame(maxWidth: 650).frame(maxWidth: .infinity)
                }.ambientBackground().navigationTitle("应用详情").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                    .navigationDestination(isPresented: $showSigning) { PackageSigningView(packageID: packageID) }
                    .confirmationDialog("从应用库移除？", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("移除 IPA 和签名输出", role: .destructive) { Task { if await store.deletePackage(package) { dismiss() } } }
                    } message: { Text("已导入的容器及其数据会保留。") }
            }
        }
    }
}
