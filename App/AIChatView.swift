import SwiftUI
import PhotosUI

struct AIChatView: View {
    @StateObject private var chat = AIChatStore.shared
    @State private var showSettings = false
    @State private var showModels = false
    @State private var showHistory = false
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var previewAttachment: AIChatAttachment?
    /// 正在查看的图片：从缩略图的位置飞出，关闭时飞回。
    @State private var viewingImage: AIChatAttachment?
    @State private var viewingSource: CGRect?
    @State private var viewingRadius: CGFloat = 13
    /// 缩略图在屏幕上的位置；只在打开时读取，滚动时不触发重绘。
    @State private var imageFrames = ImageFrameStore()
    @State private var followReply = true
    @FocusState private var composerFocused: Bool
    private var model: String { chat.configuration.endpoint(for: chat.configuration.provider).model }
    private var modelName: String? { chat.models.first { $0.id == model }?.title }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            if chat.current?.messages.isEmpty != false { welcome }
                            ForEach(chat.current?.messages ?? []) { message in messageView(message) }
                            Color.clear.frame(height: 1).id("ai.bottom")
                        }.padding(.horizontal, 20).padding(.vertical, 24).frame(maxWidth: 760).frame(maxWidth: .infinity)
                    }.scrollDismissesKeyboard(.interactively)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                        .accessibilityIdentifier("ai.messages")
                        .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in followReply = false })
                        .overlay(alignment: .bottom) {
                            if !followReply, chat.current != nil {
                                Button { followReply = true; withAnimation { proxy.scrollTo("ai.bottom", anchor: .bottom) } } label: { Label("回到最新消息", systemImage: "arrow.down").labelStyle(.iconOnly) }
                                    .aiControlStyle().buttonBorderShape(.circle).controlSize(.large).padding(.bottom, 12).accessibilityLabel("回到最新消息")
                            }
                        }
                        .onChange(of: chat.current?.messages.last?.content) { _, _ in if followReply { proxy.scrollTo("ai.bottom", anchor: .bottom) } }
                        .onChange(of: chat.current?.messages.last?.attachments?.count) { _, _ in if followReply { proxy.scrollTo("ai.bottom", anchor: .bottom) } }
                        .onChange(of: chat.history.currentID) { _, _ in followReply = true; proxy.scrollTo("ai.bottom", anchor: .bottom) }
                        .onChange(of: chat.current?.messages.count) { _, _ in if followReply { proxy.scrollTo("ai.bottom", anchor: .bottom) } }
                }
            }.ambientBackground().navigationTitle("AI 对话").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .toolbar(composerFocused ? .hidden : .visible, for: .tabBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { composerFocused = false; showHistory = true } label: { Image(systemName: "line.3.horizontal") }.accessibilityLabel("历史对话").accessibilityIdentifier("ai.history") }
                    ToolbarItem(placement: .principal) { modelHeader }
                    ToolbarItem(placement: .primaryAction) {
                        Button { composerFocused = false; chat.newConversation(); followReply = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("新建对话").accessibilityIdentifier("ai.new")
                    }
                }
                .sheet(isPresented: $showSettings) { NavigationStack { AISettingsView() }.tint(AIInterface.tint) }
                .sheet(isPresented: $showModels) { AIModelPickerView(chat: chat).tint(AIInterface.tint) }
                .sheet(isPresented: $showHistory) { AIHistoryView(chat: chat).tint(AIInterface.tint) }
                .sheet(isPresented: $showFiles) {
                    DocumentImportPicker(isPresented: $showFiles) { result in
                        switch result { case .success(let url): Task { await chat.importAttachment(url) }; case .failure(let error): chat.issue = error.localizedDescription }
                    }
                }
                .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: 8, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
                .task(id: photos) {
                    guard !photos.isEmpty else { return }
                    for photo in photos {
                        do {
                            guard let selected = try await photo.loadTransferable(type: AIPhotoTransfer.self) else { throw WorkspaceFailure("无法读取所选照片或视频。") }
                            defer { try? FileManager.default.removeItem(at: selected.url.deletingLastPathComponent()) }
                            try Task.checkCancellation(); await chat.importAttachment(selected.url)
                        } catch is CancellationError { return }
                        catch { chat.issue = error.localizedDescription }
                    }
                    photos = []
                }
                // 文件和视频用系统预览；图片用自己的查看界面，过渡动画由它自己完成。
                .sheet(item: $previewAttachment) { attachment in
                    AIAttachmentPreview(file: chat.attachmentURL(attachment), title: attachment.name).tint(AIInterface.tint)
                }
                .fullScreenCover(item: $viewingImage) { attachment in
                    AIImageViewer(file: chat.attachmentURL(attachment), title: attachment.name, sourceFrame: viewingSource, sourceCornerRadius: viewingRadius,
                                  onSave: { await chat.saveImageToPhotos(attachment) },
                                  onClose: { withoutAnimation { viewingImage = nil } })
                        .presentationBackground(.clear)
                }
                .overlay(alignment: .top) {
                    if let notice = chat.notice {
                        Label(notice, systemImage: "checkmark.circle.fill").font(.subheadline).padding(14).background(.regularMaterial, in: Capsule()).padding(.top, 8)
                            .task(id: notice) { try? await Task.sleep(for: .seconds(3)); if chat.notice == notice { chat.notice = nil } }
                    }
                }
        }.tint(AIInterface.tint)
    }
    private var welcome: some View {
        VStack(spacing: 14) {
            if chat.configured, !model.isEmpty {
                AIModelIcon(model: model, name: modelName, provider: chat.configuration.provider, size: 42)
                    .frame(width: 80, height: 80).background(Palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
                    .background(Circle().fill(Palette.accent.opacity(0.22)).frame(width: 150, height: 150).blur(radius: 40))
                    .shadow(color: Palette.shadow.opacity(1.5), radius: 16, x: 0, y: 8).padding(.bottom, 6)
                Text("有什么可以帮你？").font(.title2.weight(.bold))
                Text("正在使用 \(modelName ?? model)。可以附加图片、视频或文件，点击顶部切换模型。")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3)
            } else {
                GlyphTile(symbol: "sparkles", size: 80).padding(.bottom, 6)
                Text("连接 AI 接口").font(.title2.weight(.bold))
                Text("填写 API 地址和密钥后自动读取模型，支持 OpenAI 兼容与 Anthropic 协议。")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3)
                Button { composerFocused = false; showSettings = true } label: { Label("设置 AI 接口", systemImage: "key.fill") }
                    .buttonStyle(GradientCapsuleButtonStyle()).padding(.top, 6)
            }
        }.frame(maxWidth: 420).padding(.horizontal, 12).frame(maxWidth: .infinity).padding(.top, 72)
    }
    private var modelHeader: some View {
        Button { composerFocused = false; if chat.models.isEmpty { showSettings = true } else { showModels = true } } label: {
            HStack(spacing: 8) {
                if !model.isEmpty { AIModelIcon(model: model, name: modelName, provider: chat.configuration.provider) }
                Text(model.isEmpty ? "添加 AI 接口" : modelName ?? model).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(Color.secondary)
            }.frame(maxWidth: 210).padding(.horizontal, 4)
        }.aiControlStyle().buttonBorderShape(.capsule).accessibilityLabel("当前模型与接口设置").accessibilityValue(modelName ?? model).accessibilityIdentifier("ai.models")
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let issue = chat.issue {
                HStack(alignment: .top) { Text(issue).font(.footnote).foregroundStyle(.red); Spacer(); Button { chat.issue = nil } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }.buttonStyle(.borderless).accessibilityLabel("关闭提示") }.accessibilityIdentifier("ai.error")
            }
            if !chat.canContinue { HStack { Text("接口已更改，历史对话仍可查看。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("新建对话") { chat.newConversation() }.font(.caption) } }
            VStack(alignment: .leading, spacing: 4) {
                if !chat.draftAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) { ForEach(chat.draftAttachments) { attachment in draftCard(attachment) } }.padding(.horizontal, 12).padding(.top, 12)
                    }.accessibilityIdentifier("ai.attachments")
                }
                if chat.isImporting { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在准备附件…").font(.caption).foregroundStyle(.secondary) }.padding(.horizontal, 16).padding(.top, 8) }
                HStack(alignment: .bottom, spacing: 8) {
                    Menu {
                        Button("照片与视频", systemImage: "photo.on.rectangle.angled") { composerFocused = false; showPhotos = true }
                        Button("选择文件", systemImage: "folder") { composerFocused = false; showFiles = true }
                    } label: { Label("添加附件", systemImage: "plus").labelStyle(.iconOnly).font(.title3).frame(width: 36, height: 44) }
                        .buttonStyle(.borderless).disabled(chat.isImporting).accessibilityLabel("添加附件").accessibilityIdentifier("ai.addAttachment")
                    TextField("询问 AI", text: $chat.draftText, axis: .vertical).textFieldStyle(.plain).focused($composerFocused).lineLimit(1...6).font(.body).foregroundStyle(.primary).padding(.vertical, 11).accessibilityIdentifier("ai.input")
                    Button {
                        if chat.isGenerating { chat.stop() }
                        else if chat.send(chat.draftText) { followReply = true }
                    } label: {
                        Label(chat.isGenerating ? "停止回答" : "发送消息", systemImage: chat.isGenerating ? "stop.fill" : "arrow.up").labelStyle(.iconOnly).font(.body.weight(.semibold)).frame(width: 24, height: 24)
                    }.buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.regular).disabled(!chat.isGenerating && (chat.isImporting || (chat.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.draftAttachments.isEmpty) || !chat.configured || !chat.canContinue))
                        .accessibilityLabel(chat.isGenerating ? "停止回答" : "发送消息").accessibilityIdentifier(chat.isGenerating ? "ai.stop" : "ai.send")
                }.padding(.horizontal, 10).padding(.vertical, 6)
            }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(composerFocused ? Palette.accent.opacity(0.45) : Palette.border, lineWidth: composerFocused ? 1.2 : 1))
                .shadow(color: Palette.shadow.opacity(1.5), radius: 18, x: 0, y: 6)
                .animation(.easeOut(duration: 0.2), value: composerFocused)
        }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8).frame(maxWidth: 760).frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [Palette.background.opacity(0), Palette.background, Palette.background], startPoint: .top, endPoint: .bottom))
    }
    private func draftCard(_ attachment: AIChatAttachment) -> some View {
        HStack(spacing: 9) {
            Button { openPreview(attachment, cornerRadius: 9) } label: {
                HStack(spacing: 9) {
                    imageSource(attachmentIcon(attachment, size: 44), attachment)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(attachment.name).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)).font(.caption2).foregroundStyle(Color.secondary)
                    }.frame(maxWidth: 120, alignment: .leading)
                }
            }.buttonStyle(.borderless).accessibilityLabel("预览附件 " + attachment.name)
            Button { chat.removeDraftAttachment(attachment.id) } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("移除附件 " + attachment.name)
        }.padding(8).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 13))
    }
    @ViewBuilder private func attachmentIcon(_ attachment: AIChatAttachment, size: CGFloat) -> some View {
        if let url = chat.attachmentURL(attachment, thumbnail: true), let image = UIImage(contentsOfFile: url.path), attachment.kind != .file {
            Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 9)).overlay { if attachment.kind == .video { Image(systemName: "play.circle.fill").foregroundStyle(.white) } }
        } else { Image(systemName: attachment.kind == .video ? "video" : attachment.kind == .image ? "photo" : "doc.text").font(.system(size: size * 0.4)).foregroundStyle(.tint).frame(width: size, height: size).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9)) }
    }
    @ViewBuilder private func messageView(_ message: AIChatMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 28)
                VStack(alignment: .trailing, spacing: 10) {
                    if let attachments = message.attachments { ForEach(attachments) { attachment in Button { openPreview(attachment, cornerRadius: 9) } label: { HStack(spacing: 10) { imageSource(attachmentIcon(attachment, size: 48), attachment); Text(attachment.name).font(.subheadline).foregroundStyle(.primary).lineLimit(2); Image(systemName: "arrow.up.right").font(.caption) }.padding(10).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.border, lineWidth: 1)) }.buttonStyle(.borderless) } }
                    if !message.content.isEmpty { Text(message.content).foregroundStyle(.white).tint(.white).textSelection(.enabled).padding(.horizontal, 15).padding(.vertical, 11)
                        .background(Palette.accentGradient, in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous))
                        .shadow(color: Palette.accent.opacity(0.22), radius: 10, x: 0, y: 5) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 13) {
                let replyModel = message.modelLabel ?? chat.current?.connection.model ?? ""
                HStack(spacing: 7) {
                    AIModelIcon(model: replyModel, provider: chat.current?.connection.provider, size: 14)
                        .frame(width: 26, height: 26).background(Palette.surface, in: Circle()).overlay(Circle().strokeBorder(Palette.border, lineWidth: 1))
                    Text(replyModel.isEmpty ? "AI" : replyModel).foregroundStyle(.secondary).lineLimit(1)
                }.font(.caption.weight(.medium)).accessibilityElement(children: .combine)
                if message.content.isEmpty, message.attachments?.isEmpty != false, message.status == .streaming {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在回应…").font(.footnote).foregroundStyle(.secondary) }
                }
                if !message.content.isEmpty { AIMessageContent(text: message.content) }
                if let attachments = message.attachments { ForEach(attachments) { attachment in generatedImage(attachment) } }
                if let note = message.note { Text(note).font(.footnote).foregroundStyle(message.status == .failed ? .red : .secondary) }
                HStack(spacing: 8) {
                    if !message.content.isEmpty, message.status != .streaming {
                        Button { UIPasteboard.general.string = message.content; chat.notice = "已复制回答" } label: { Label("复制回答", systemImage: "doc.on.doc").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("复制回答")
                        ShareLink(item: message.content) { Label("分享回答", systemImage: "square.and.arrow.up").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("分享回答")
                    }
                    if message.id == chat.current?.messages.last?.id, message.status == .failed || message.status == .stopped { Button { chat.retry() } label: { Label("重试", systemImage: "arrow.clockwise").frame(minHeight: 44) } }
                }.font(.subheadline).foregroundStyle(.secondary).buttonStyle(.borderless).disabled(chat.isGenerating).padding(.top, -6)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    /// 图片交给查看界面从缩略图飞出（不使用系统的弹出动画）；其他附件用系统预览。
    private func openPreview(_ attachment: AIChatAttachment, cornerRadius: CGFloat = 13) {
        guard attachment.kind == .image else { previewAttachment = attachment; return }
        viewingSource = imageFrames.frames[attachment.id]; viewingRadius = cornerRadius
        withoutAnimation { viewingImage = attachment }
    }
    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
    /// 记录缩略图位置，并在图片被「拿起」时隐藏原位。
    private func imageSource(_ view: some View, _ attachment: AIChatAttachment) -> some View {
        view.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { imageFrames.frames[attachment.id] = $0 }
            .opacity(viewingImage?.id == attachment.id ? 0 : 1)
    }
    private func generatedImage(_ attachment: AIChatAttachment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { openPreview(attachment) } label: {
                Group {
                    if let url = chat.attachmentURL(attachment, thumbnail: true), let image = UIImage(contentsOfFile: url.path), image.size.height > 0 {
                        // 图片在卡片内四周等距居中；比例过竖时，两侧用同一张图的模糊版补齐，而不是留白。
                        let aspect = max(image.size.width / image.size.height, 0.75)
                        ZStack {
                            Image(uiImage: image).resizable().scaledToFill().blur(radius: 28).opacity(0.55)
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                        .frame(maxWidth: .infinity)
                        .aspectRatio(aspect, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .modifier(ImageSourceModifier(attachment: attachment, frames: imageFrames, hidden: viewingImage?.id == attachment.id))
                        .overlay(alignment: .topTrailing) {
                            if attachment.mediaType == "image/gif" {
                                Text("GIF").font(.caption2.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.black.opacity(0.55), in: Capsule()).padding(10)
                            }
                        }
                    } else { Label("图片文件暂不可用", systemImage: "photo").frame(maxWidth: .infinity).padding(24) }
                }.padding([.horizontal, .top], 8)
            }.buttonStyle(.borderless).accessibilityLabel("预览生成图片")
            HStack(spacing: 20) {
                Button { Task { await chat.saveImageToPhotos(attachment) } } label: { Label("保存", systemImage: "square.and.arrow.down").frame(minHeight: 44).contentShape(Rectangle()) }.accessibilityIdentifier("ai.image.save")
                if let file = chat.attachmentURL(attachment) { ShareLink(item: file) { Label("分享", systemImage: "square.and.arrow.up").frame(minHeight: 44).contentShape(Rectangle()) } }
                Spacer(minLength: 0)
                Button { chat.reuseAttachment(attachment) } label: { Image(systemName: "plus.circle").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("将图片添加为附件")
            }.font(.subheadline).buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 2)
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        .shadow(color: Palette.shadow, radius: 12, x: 0, y: 6)
    }
}

private struct AIMessageContent: View {
    let text: String
    var body: some View {
        let blocks = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks.indices, id: \.self) { index in
                if index.isMultiple(of: 2) {
                    Text((try? AttributedString(markdown: blocks[index], options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(blocks[index])).lineSpacing(4).textSelection(.enabled)
                } else {
                    AICodeBlock(raw: blocks[index])
                }
            }
        }
    }
}

private struct AICodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false
    init(raw: String) {
        let lines = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let first = lines.first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if lines.count > 1, !first.isEmpty, first.count <= 20, !first.contains(" ") {
            language = first; code = String(lines[1]).trimmingCharacters(in: .newlines)
        } else { language = ""; code = raw.trimmingCharacters(in: .newlines) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code; copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: { Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption).frame(minHeight: 32) }
                    .buttonStyle(.borderless).accessibilityLabel("复制代码")
            }.padding(.leading, 14).padding(.trailing, 10).background(Color(uiColor: .tertiarySystemFill))
            ScrollView(.horizontal) { Text(code).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(14) }
        }.background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
    }
}

private struct AIHistoryView: View {
    @ObservedObject var chat: AIChatStore
    @Environment(\.dismiss) private var dismiss
    private var groups: [(title: String, items: [AIConversation])] {
        let calendar = Calendar.current
        let sorted = chat.history.conversations.sorted { $0.updatedAt > $1.updatedAt }
        func title(_ date: Date) -> String {
            if calendar.isDateInToday(date) { return "今天" }
            if calendar.isDateInYesterday(date) { return "昨天" }
            if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: .now)).day, days < 7 { return "过去 7 天" }
            return date.formatted(.dateTime.year().month())
        }
        var result: [(title: String, items: [AIConversation])] = []
        for conversation in sorted {
            let key = title(conversation.updatedAt)
            if result.last?.title == key { result[result.count - 1].items.append(conversation) } else { result.append((key, [conversation])) }
        }
        return result
    }
    var body: some View {
        NavigationStack {
            List {
                if chat.history.conversations.isEmpty { ContentUnavailableView("暂无对话", systemImage: "bubble.left.and.bubble.right", description: Text("开始的新对话会保存在这台设备上。")) }
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { conversation in
                            Button { chat.open(conversation.id); dismiss() } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    AIModelIcon(model: conversation.connection.model, provider: conversation.connection.provider, size: 20).frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(conversation.title).foregroundStyle(Color.primary).lineLimit(2)
                                        HStack(spacing: 6) {
                                            Text(conversation.connection.model).lineLimit(1).truncationMode(.middle)
                                            Text("·")
                                            Text(Calendar.current.isDateInToday(conversation.updatedAt) ? conversation.updatedAt.formatted(.dateTime.hour().minute()) : conversation.updatedAt.formatted(.dateTime.month().day()))
                                        }.font(.caption).foregroundStyle(Color.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if conversation.id == chat.history.currentID { Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(.tint).accessibilityLabel("当前对话") }
                                }.padding(.vertical, 3)
                            }.swipeActions { Button("删除", role: .destructive) { chat.delete(conversation.id) } }
                        }
                    }
                }
            }.scrollContentBackground(.hidden).ambientBackground().navigationTitle("历史对话").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

/// 缩略图位置的记录；普通引用类型，写入不会触发界面重绘。
final class ImageFrameStore { var frames: [UUID: CGRect] = [:] }

private struct ImageSourceModifier: ViewModifier {
    let attachment: AIChatAttachment
    let frames: ImageFrameStore
    let hidden: Bool
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.frames[attachment.id] = $0 }
            .opacity(hidden ? 0 : 1)
    }
}
