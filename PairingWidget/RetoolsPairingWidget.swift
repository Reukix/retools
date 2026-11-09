import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RetoolsPairingWidgets: WidgetBundle {
    var body: some Widget {
        RetoolsPairingActivity()
        RetoolsExpiryWidget()
    }
}

struct RetoolsPairingActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PairingActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.state.succeeded ? "checkmark.circle.fill" : "iphone.radiowaves.left.and.right")
                    .font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Retools · 设备配对").font(.headline)
                    Text(context.isStale ? "配对已超时，请返回 Retools" : context.state.phase).font(.caption).foregroundStyle(.secondary)
                    if !context.isStale, let pin = context.state.pin {
                        Text(pin).font(.system(size: 30, weight: .bold, design: .monospaced)).privacySensitive()
                    }
                }
                Spacer(minLength: 0)
            }.padding(18).activityBackgroundTint(.black.opacity(0.85)).activitySystemActionForegroundColor(.orange)
                .widgetURL(URL(string: "retools://pairing"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Retools", systemImage: "iphone.radiowaves.left.and.right").font(.caption).foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.finished { Image(systemName: context.state.succeeded ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(context.state.succeeded ? .green : .orange) }
                    else { Text("设备配对").font(.caption).foregroundStyle(.secondary) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 7) {
                        if !context.isStale, let pin = context.state.pin {
                            Text(pin).font(.system(size: 34, weight: .bold, design: .monospaced)).privacySensitive()
                            Text("在系统设置中输入配对码").font(.caption).foregroundStyle(.secondary)
                        } else { Text(context.isStale ? "配对已超时，请返回 Retools" : context.state.phase).font(.subheadline).multilineTextAlignment(.center) }
                    }.frame(maxWidth: .infinity).padding(.bottom, 8)
                }
            } compactLeading: {
                Image(systemName: context.state.succeeded ? "checkmark.circle.fill" : "iphone.radiowaves.left.and.right").foregroundStyle(.orange)
            } compactTrailing: {
                Text(context.isStale ? "超时" : (context.state.pin ?? (context.state.finished ? "完成" : "配对")))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).privacySensitive()
            } minimal: {
                Image(systemName: context.state.succeeded ? "checkmark.circle.fill" : "iphone.radiowaves.left.and.right").foregroundStyle(.orange)
            }.widgetURL(URL(string: "retools://pairing")).keylineTint(.orange)
        }
    }
}
