import SwiftUI

struct DeviceServiceStatus: View {
    let phase: DeviceToolsStore.Phase
    var retry: () async -> Void

    var body: some View {
        switch phase {
        case .idle, .loading:
            Section { HStack(spacing: 10) { ProgressView(); Text("正在读取…").foregroundStyle(Color.secondary) } }
        case .failed(let message):
            Section {
                Text(message).font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
                Button("重新读取") { Task { await retry() } }
                NavigationLink("设备配对与连接") { DeviceConnectionView() }
            }
        case .ready:
            EmptyView()
        }
    }
}
