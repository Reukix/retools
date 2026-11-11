// Retools integration, 2026-11-11. GPL-2.0-or-later.
import SwiftUI

/// Capture the module context before SwiftUI promotes a destination into the host stack.
private struct StoreDestinationContext: ViewModifier {
    let store: ToolStore
    let handler: (@MainActor (URL, StorePackageAction) async throws -> Void)?
    let modal: Bool
    let installationSettings: AnyView?
    func body(content: Content) -> some View {
        content.environmentObject(store)
            .environmentObject(store.apple)
            .environmentObject(store.downloads)
            .environmentObject(store.signer)
            .environment(\.storePackageHandler, handler)
            .environment(\.storeIsModal, modal)
            .environment(\.storeInstallationSettings, installationSettings)
            .tint(Color.primary)
    }
}

struct StoreNavigationLink<Destination: View, Label: View>: View {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.storePackageHandler) private var handler
    @Environment(\.storeIsModal) private var modal
    @Environment(\.storeInstallationSettings) private var installationSettings
    private let destination: Destination
    private let label: Label

    init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Label) {
        self.destination = destination(); self.label = label()
    }
    init(_ title: String, @ViewBuilder destination: () -> Destination) where Label == Text {
        self.destination = destination(); self.label = Text(title)
    }
    var body: some View {
        let context = StoreDestinationContext(store: store, handler: handler, modal: modal, installationSettings: installationSettings)
        NavigationLink { destination.modifier(context) } label: { label }
    }
}

private struct StoreItemDestination<Item: Hashable, Destination: View>: ViewModifier {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.storePackageHandler) private var handler
    @Environment(\.storeIsModal) private var modal
    @Environment(\.storeInstallationSettings) private var installationSettings
    @Binding var item: Item?
    let destination: (Item) -> Destination
    func body(content: Content) -> some View {
        let context = StoreDestinationContext(store: store, handler: handler, modal: modal, installationSettings: installationSettings)
        content.navigationDestination(item: $item) { destination($0).modifier(context) }
    }
}

private struct StorePresentedDestination<Destination: View>: ViewModifier {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.storePackageHandler) private var handler
    @Environment(\.storeIsModal) private var modal
    @Environment(\.storeInstallationSettings) private var installationSettings
    @Binding var presented: Bool
    let destination: () -> Destination
    func body(content: Content) -> some View {
        let context = StoreDestinationContext(store: store, handler: handler, modal: modal, installationSettings: installationSettings)
        content.navigationDestination(isPresented: $presented) { destination().modifier(context) }
    }
}

extension View {
    func storeNavigationDestination<Item: Hashable, Destination: View>(item: Binding<Item?>,
        @ViewBuilder destination: @escaping (Item) -> Destination) -> some View {
        modifier(StoreItemDestination(item: item, destination: destination))
    }
    func storeNavigationDestination<Destination: View>(isPresented: Binding<Bool>,
        @ViewBuilder destination: @escaping () -> Destination) -> some View {
        modifier(StorePresentedDestination(presented: isPresented, destination: destination))
    }
}
