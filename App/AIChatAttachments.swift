import Foundation
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreGraphics
import CoreTransferable

actor AIChatFiles {
    static let maximumFileBytes = 32_000_000
    nonisolated let directory: URL
    private var prepared = false
    private let retainedIDs: Set<UUID>?
    init(repository: AIChatRepository) {
        directory = repository.directory.appendingPathComponent("Attachments")
        retainedIDs = (try? repository.history()).map { Set($0.conversations.flatMap(\.messages).flatMap { $0.attachments ?? [] }.map(\.id)) }
    }
    nonisolated func url(_ attachment: AIChatAttachment, thumbnail: Bool = false) -> URL? {
        let name = thumbnail ? (attachment.thumbnailName ?? attachment.fileName) : attachment.fileName
        guard name == (name as NSString).lastPathComponent, name.hasPrefix(attachment.id.uuidString + ".") || name.hasPrefix(attachment.id.uuidString + "-preview.") else { return nil }
        return directory.appendingPathComponent(name)
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard !prepared else { return }; prepared = true
        if let retainedIDs {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? [] {
                guard let id = UUID(uuidString: String(file.lastPathComponent.prefix(36))), !retainedIDs.contains(id) else { continue }
                if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { try? FileManager.default.removeItem(at: file) }
            }
        }
    }
    func importFile(_ source: URL) throws -> AIChatAttachment {
        try Task.checkCancellation(); try prepareDirectory()
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        var result: Result<AIChatAttachment, Error>?, coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { file in
            result = Result {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WorkspaceFailure("请选择普通文件。") }
                guard (values.fileSize ?? Int.max) <= Self.maximumFileBytes else { throw WorkspaceFailure("单个附件最多 32 MB，请压缩或裁剪后再导入。") }
                let type = UTType(filenameExtension: file.pathExtension) ?? .data
                let kind: AIAttachmentKind = type.conforms(to: .image) ? .image : type.conforms(to: .movie) ? .video : .file
                let id = UUID(), ext = file.pathExtension.lowercased()
                let name = id.uuidString + (ext.isEmpty ? ".data" : "." + String(ext.prefix(12)).filter { $0.isLetter || $0.isNumber })
                let destination = directory.appendingPathComponent(name)
                do {
                    FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    let input = try FileHandle(forReadingFrom: file), output = try FileHandle(forWritingTo: destination)
                    defer { try? input.close(); try? output.close() }
                    var count = 0
                    while let bytes = try input.read(upToCount: 262144), !bytes.isEmpty {
                        try Task.checkCancellation(); count += bytes.count
                        guard count <= Self.maximumFileBytes else { throw WorkspaceFailure("单个附件最多 32 MB。") }
                        try output.write(contentsOf: bytes)
                    }
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
                    var attachment = AIChatAttachment(id: id, fileName: name, name: source.lastPathComponent, kind: kind, mediaType: type.preferredMIMEType ?? "application/octet-stream", byteCount: count)
                    if kind == .image {
                        guard let image = Self.thumbnail(at: destination, side: 1024) else { throw WorkspaceFailure("无法读取这张图片。") }
                        attachment.thumbnailName = try saveThumbnail(image, id: id)
                    } else if kind == .video {
                        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
                        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 600, height: 600)
                        if let image = try? generator.copyCGImage(at: .zero, actualTime: nil) { attachment.thumbnailName = try? saveThumbnail(image, id: id) }
                    }
                    return attachment
                } catch { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + "-preview.jpg")); throw error }
            }
        }
        guard let result else { throw coordinationError ?? WorkspaceFailure("无法读取所选附件。") }
        return try result.get()
    }
    func saveGeneratedImage(_ data: Data) throws -> AIChatAttachment {
        try Task.checkCancellation(); try prepareDirectory()
        guard !data.isEmpty, data.count <= Self.maximumFileBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000, width * height <= 100_000_000,
              let thumbnail = Self.thumbnail(source, side: 1024) else { throw WorkspaceFailure("接口返回的图片无法读取，或超过尺寸限制。") }
        let id = UUID(), fileType = UTType(type as String), ext = fileType?.preferredFilenameExtension ?? "png"
        let name = id.uuidString + "." + ext, destination = directory.appendingPathComponent(name)
        do {
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let preview = try saveThumbnail(thumbnail, id: id)
            try Task.checkCancellation()
            return AIChatAttachment(id: id, fileName: name, name: "生成图片." + ext, kind: .image, mediaType: fileType?.preferredMIMEType ?? "image/png", byteCount: data.count, thumbnailName: preview)
        } catch { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + "-preview.jpg")); throw error }
    }
    func remove(_ attachments: [AIChatAttachment]) {
        for attachment in attachments {
            if let file = url(attachment) { try? FileManager.default.removeItem(at: file) }
            if attachment.thumbnailName != nil, let preview = url(attachment, thumbnail: true) { try? FileManager.default.removeItem(at: preview) }
        }
    }
    private func saveThumbnail(_ image: CGImage, id: UUID) throws -> String {
        let name = id.uuidString + "-preview.jpg", data = try Self.jpeg(image)
        try data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(name).path)
        return name
    }
    nonisolated static func thumbnail(at file: URL, side: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return thumbnail(source, side: side)
    }
    nonisolated private static func thumbnail(_ source: CGImageSource, side: Int) -> CGImage? {
        guard let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = values[kCGImagePropertyPixelWidth] as? Int, let height = values[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000, width * height <= 100_000_000 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    nonisolated static func jpeg(_ image: CGImage) throws -> Data {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WorkspaceFailure("无法处理图片。") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height)); context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = NSMutableData()
        guard let bitmap = context.makeImage(), let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw WorkspaceFailure("无法编码图片。") }
        CGImageDestinationAddImage(destination, bitmap, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw WorkspaceFailure("无法保存图片预览。") }
        return data as Data
    }
    nonisolated static func fileURL(_ attachment: AIChatAttachment, directory: URL) throws -> URL {
        let file = attachment.fileName
        guard file == (file as NSString).lastPathComponent, file.hasPrefix(attachment.id.uuidString + ".") else { throw WorkspaceFailure("附件路径无效。") }
        let url = directory.appendingPathComponent(file)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= maximumFileBytes else { throw WorkspaceFailure("附件不可用或超过大小限制。") }
        return url
    }
}

struct AIPhotoTransfer: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            guard let size = try received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= AIChatFiles.maximumFileBytes else { throw WorkspaceFailure("单个附件最多 32 MB，请先压缩或裁剪。") }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AIPhoto-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let output = folder.appendingPathComponent(received.file.lastPathComponent)
            do { try FileManager.default.copyItem(at: received.file, to: output); return AIPhotoTransfer(url: output) }
            catch { try? FileManager.default.removeItem(at: folder); throw error }
        }
    }
}
