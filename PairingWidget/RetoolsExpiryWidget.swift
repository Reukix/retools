import SwiftUI
import WidgetKit

/// 桌面与锁屏小组件：Retools 和 Apple ID 签名应用还剩几天。数据由主程序写入共享钥匙串。
struct RetoolsExpiryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RetoolsExpiry", provider: ExpiryProvider()) { entry in
            ExpiryWidgetView(entry: entry)
                .containerBackground(for: .widget) { ExpiryWidgetBackground() }
                .widgetURL(URL(string: "retools://expiry"))
        }
        .configurationDisplayName("签名有效期")
        .description("Retools 与 Apple ID 签名应用的剩余天数。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct ExpiryEntry: TimelineEntry {
    let date: Date
    let snapshot: ExpirySnapshot?
    /// 按剩余时间排序，Retools 自身在同样紧迫时排前面。
    var items: [ExpirySnapshot.Item] {
        (snapshot?.items ?? []).sorted { ($0.expiry ?? .distantFuture, $0.isHost ? 0 : 1) < ($1.expiry ?? .distantFuture, $1.isHost ? 0 : 1) }
    }
    var host: ExpirySnapshot.Item? { snapshot?.items.first(where: \.isHost) }
    /// 小号和锁屏只放一个：最先到期的那个。
    var primary: ExpirySnapshot.Item? { items.first }
}

struct ExpiryProvider: TimelineProvider {
    func placeholder(in context: Context) -> ExpiryEntry { ExpiryEntry(date: Date(), snapshot: .preview) }
    func getSnapshot(in context: Context, completion: @escaping (ExpiryEntry) -> Void) {
        let stored = ExpirySnapshotStore.load()
        // 小组件库里的预览没有真实数据时用示例，让用户看到它的样子。
        completion(ExpiryEntry(date: Date(), snapshot: context.isPreview && (stored?.items.isEmpty ?? true) ? .preview : stored))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ExpiryEntry>) -> Void) {
        let snapshot = ExpirySnapshotStore.load()
        let now = Date()
        // 剩余天数在「到期时间减整数天」的时刻跳变；排出接下来几次跳变，加上每 6 小时一次兜底。
        var dates: Set<Date> = [now]
        for item in snapshot?.items ?? [] {
            guard let expiry = item.expiry else { continue }
            for day in 0...8 {
                let change = expiry.addingTimeInterval(-Double(day) * 86_400)
                if change > now, change < now.addingTimeInterval(2 * 86_400) { dates.insert(change.addingTimeInterval(1)) }
            }
        }
        for hour in stride(from: 6, through: 48, by: 6) { dates.insert(now.addingTimeInterval(Double(hour) * 3600)) }
        let entries = dates.sorted().map { ExpiryEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

private enum ExpiryStyle {
    static let accent = Color(red: 0.94, green: 0.36, blue: 0.17)
    static func color(_ expiry: Date?, now: Date) -> Color {
        guard let expiry else { return .secondary }
        let seconds = expiry.timeIntervalSince(now)
        if seconds < 86_400 { return .red }
        return ExpirySnapshot.daysLeft(expiry, now: now) <= 3 ? .orange : .green
    }
    /// 数字与单位分开，便于大字号显示。
    static func value(_ expiry: Date?, now: Date) -> (number: String, unit: String) {
        guard let expiry else { return ("–", "") }
        let seconds = expiry.timeIntervalSince(now)
        if seconds <= 0 { return ("0", "已过期") }
        if seconds < 86_400 { return ("\(max(1, Int((seconds / 3600).rounded(.up))))", "小时") }
        return ("\(ExpirySnapshot.daysLeft(expiry, now: now))", "天")
    }
    static func label(_ expiry: Date?, now: Date) -> String {
        let value = value(expiry, now: now)
        return value.unit == "已过期" ? "已过期" : value.number + " " + value.unit
    }
    /// 7 天签名周期内的剩余比例。
    static func fraction(_ expiry: Date?, now: Date) -> Double {
        guard let expiry else { return 0 }
        return min(1, max(0, expiry.timeIntervalSince(now) / (7 * 86_400)))
    }
}

private struct ExpiryWidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            scheme == .dark ? Color(red: 0.07, green: 0.08, blue: 0.09) : Color(red: 0.975, green: 0.968, blue: 0.955)
            RadialGradient(colors: [ExpiryStyle.accent.opacity(scheme == .dark ? 0.22 : 0.14), .clear], center: .topLeading, startRadius: 0, endRadius: 220)
        }
    }
}

struct ExpiryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExpiryEntry
    var body: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    // MARK: 锁屏

    @ViewBuilder private var inline: some View {
        if let item = entry.primary {
            Text("\(item.name) · \(ExpiryStyle.label(item.expiry, now: entry.date))")
        } else { Text("Retools 签名有效期") }
    }
    private var circular: some View {
        let item = entry.primary
        let value = ExpiryStyle.value(item?.expiry, now: entry.date)
        return Gauge(value: ExpiryStyle.fraction(item?.expiry, now: entry.date)) {
            Text(item?.name ?? "Retools")
        } currentValueLabel: {
            Text(value.number).font(.system(size: 20, weight: .bold, design: .rounded))
        }.gaugeStyle(.accessoryCircularCapacity).widgetAccentable()
    }
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("签名有效期", systemImage: "seal").font(.caption2.weight(.semibold)).widgetAccentable()
            if entry.items.isEmpty { Text("打开 Retools 查看").font(.caption) }
            ForEach(entry.items.prefix(2)) { item in
                HStack {
                    Text(item.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ExpiryStyle.label(item.expiry, now: entry.date)).monospacedDigit()
                }.font(.caption)
            }
        }
    }

    // MARK: 桌面

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "seal.fill").font(.caption.weight(.bold)).foregroundStyle(ExpiryStyle.accent)
                Text("有效期").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let item = entry.primary {
                let value = ExpiryStyle.value(item.expiry, now: entry.date)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value.number).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(ExpiryStyle.color(item.expiry, now: entry.date)).contentTransition(.numericText())
                    Text(value.unit).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                ProgressView(value: ExpiryStyle.fraction(item.expiry, now: entry.date))
                    .tint(ExpiryStyle.color(item.expiry, now: entry.date)).padding(.top, 6)
                if entry.items.count > 1 {
                    Text("另有 \(entry.items.count - 1) 个应用").font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                }
            } else { emptyState }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "seal.fill").font(.caption.weight(.bold)).foregroundStyle(ExpiryStyle.accent)
                Text("签名有效期").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let result = entry.snapshot?.lastRenewal { Text(result).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
            if entry.items.isEmpty { Spacer(minLength: 0); emptyState; Spacer(minLength: 0) }
            else {
                VStack(spacing: 6) {
                    ForEach(entry.items.prefix(4)) { item in
                        HStack(spacing: 8) {
                            Circle().fill(ExpiryStyle.color(item.expiry, now: entry.date)).frame(width: 7, height: 7)
                            Text(item.name).font(.subheadline.weight(item.isHost ? .semibold : .regular)).lineLimit(1)
                            if item.autoRenew { Image(systemName: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(.secondary) }
                            Spacer(minLength: 6)
                            Text(ExpiryStyle.label(item.expiry, now: entry.date)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(ExpiryStyle.color(item.expiry, now: entry.date))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
    private var emptyState: some View {
        Text("登录 Apple ID 签名后，这里会显示剩余天数").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

extension ExpirySnapshot {
    /// 小组件库预览用的示例数据。
    static var preview: ExpirySnapshot {
        let now = Date()
        return ExpirySnapshot(items: [
            Item(id: "host", name: "Retools", expiry: now.addingTimeInterval(5.2 * 86_400), autoRenew: true, isHost: true),
            Item(id: "a", name: "示例应用", expiry: now.addingTimeInterval(2.4 * 86_400), autoRenew: true, isHost: false),
            Item(id: "b", name: "另一个应用", expiry: now.addingTimeInterval(6.5 * 86_400), autoRenew: false, isHost: false),
        ], updatedAt: now, lastRenewal: nil)
    }
}
