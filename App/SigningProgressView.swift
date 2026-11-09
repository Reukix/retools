import SwiftUI

/// 证书签名过程面板：逐项显示每个阶段在做什么，完成后可直接分享输出。
struct SigningProgressSheet: View {
    @ObservedObject var progress: SigningProgressModel
    var onClose: () -> Void
    @State private var showLog = false

    private var running: Bool { progress.outcome == .running }
    private var failed: Bool { if case .failed = progress.outcome { return true }; return false }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    overallBar
                    VStack(spacing: 0) {
                        ForEach(Array(progress.stages.enumerated()), id: \.element) { index, stage in
                            row(stage)
                            if index < progress.stages.count - 1 { Divider().padding(.leading, 46) }
                        }
                    }.workspaceCard(padding: 6)
                    if case .failed(let message) = progress.outcome {
                        Label { Text(message).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                            .font(.subheadline).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityIdentifier("signing.progress.error")
                    }
                    DisclosureGroup(isExpanded: $showLog) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(progress.log.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(.top, 8)
                    } label: { Label("详细日志", systemImage: "text.alignleft").font(.subheadline) }
                        .padding(.horizontal, 4)
                }.padding(20)
            }
            .ambientBackground()
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle("签名进度").navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(running)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                switch progress.outcome {
                case .running: ProgressView().controlSize(.large).tint(Palette.accent)
                case .succeeded: Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.octagon.fill").font(.system(size: 34)).foregroundStyle(.red)
                }
            }.frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.bold)).lineLimit(2)
                TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                    Text(subtitle(now: context.date)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("signing.progress.header")
    }
    private var title: String {
        switch progress.outcome {
        case .running: "正在签名「\(progress.appName)」"
        case .succeeded(let message): message
        case .failed: "签名未完成"
        }
    }
    private func subtitle(now: Date) -> String {
        let end = progress.finishedAt ?? now
        let seconds = max(0, Int(end.timeIntervalSince(progress.startedAt)))
        let elapsed = seconds >= 60 ? "\(seconds / 60) 分 \(seconds % 60) 秒" : "\(seconds) 秒"
        if running, let current = progress.current { return "\(current.title) · 已用时 \(elapsed)" }
        return "用时 \(elapsed)"
    }

    private var overallBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress.overall).tint(failed ? .red : Palette.accent)
                .animation(.easeOut(duration: 0.25), value: progress.overall)
            HStack {
                Text("\(progress.stages.filter { [.done, .skipped].contains(progress.states[$0]) }.count)/\(progress.stages.count) 个步骤")
                Spacer()
                Text("\(Int((progress.overall * 100).rounded()))%").monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine).accessibilityLabel("整体进度").accessibilityValue("\(Int((progress.overall * 100).rounded()))%")
    }

    private func row(_ stage: SigningStage) -> some View {
        let state = progress.states[stage] ?? .pending
        return HStack(alignment: .top, spacing: 12) {
            stateIcon(state, stage: stage).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(stage.title).font(.subheadline.weight(state == .running ? .semibold : .regular))
                        .foregroundStyle(state == .pending ? .secondary : .primary)
                    Spacer(minLength: 6)
                    if state == .running, let fraction = progress.fraction {
                        Text("\(Int((fraction * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(Palette.accent)
                    }
                }
                if let detail = progress.details[stage], state != .pending {
                    Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                if state == .running, let fraction = progress.fraction {
                    ProgressView(value: fraction).tint(Palette.accent).animation(.easeOut(duration: 0.2), value: fraction)
                }
            }
        }.padding(.horizontal, 10).padding(.vertical, 11)
            .accessibilityElement(children: .combine).accessibilityIdentifier("signing.progress.\(stage)")
    }

    @ViewBuilder private func stateIcon(_ state: SigningProgressModel.StepState, stage: SigningStage) -> some View {
        switch state {
        case .pending: Image(systemName: stage.symbol).font(.system(size: 14)).foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small).tint(Palette.accent)
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle.fill").font(.system(size: 20)).foregroundStyle(.tertiary)
        case .failed: Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 10) {
            switch progress.outcome {
            case .running:
                Label("签名进行中，请保持 Retools 在前台", systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
            case .succeeded:
                HStack(spacing: 10) {
                    if let url = progress.exportURL {
                        ShareLink(item: url) { Label("分享 IPA", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 48) }
                            .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14)).accessibilityIdentifier("signing.progress.share")
                    }
                    Button(action: onClose) { Text("完成").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 14)).accessibilityIdentifier("signing.progress.close")
                }
            case .failed:
                // 签名已完成、只是安装失败时，输出文件已保存，仍可分享给其他安装工具。
                HStack(spacing: 10) {
                    if let url = progress.exportURL, progress.states[.install] == .failed {
                        ShareLink(item: url) { Label("分享 IPA", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 48) }
                            .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14)).accessibilityIdentifier("signing.progress.share")
                    }
                    Button(action: onClose) { Text("关闭").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48) }
                        .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14)).accessibilityIdentifier("signing.progress.close")
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
        // 签名中只有一行提示文字，背景必须占满宽度，否则会变成压在步骤列表上的一块白块。
        .bottomBarBackground()
    }
}
