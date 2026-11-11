import SwiftUI
import IPadnKit

/// The store participates in the workbench navigation stack and its native push/pop transitions.
struct StoreBrowserHostView: View {
    var initialSearch: String? = nil
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var renewal: RenewalController
    @State private var installation: StoreArchiveRequest?

    var body: some View {
        StoreBrowserView(initialSearch: initialSearch, installationSettings: AnyView(
            StoreInstallationSettingsView().environmentObject(store).environmentObject(renewal)
        )) { file, action in
            guard !store.isWorking, !renewal.isWorking else { throw WorkspaceFailure("请等待当前操作完成。") }
            switch action {
            case .importToLibrary: try await store.importStoreDownload(file)
            case .installOnDevice: installation = StoreArchiveRequest(file: file)
            case .prepareDecryption:
                store.pendingStoreDecryptionSource = file
                store.showDecryption = true
            }
        }
        .workbenchNavigation()
        .sheet(item: $installation) { StoreArchiveInstallView(request: $0) }
    }
}
