import Foundation
import AppKit
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

struct LocalMedia: Identifiable {
    let path: String
    let roots: [URL]
    let isImage: Bool
    let isThumbnail: Bool
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    static func candidate(_ message: WxMessage, account: WxAccount) -> LocalMedia? {
        guard let detail = message.contentDetail, detail["media_status"] == "resolved" else { return nil }
        let image = message.type == 3
        guard image || detail["type"] == "file" || detail["media_type"] == "file" else { return nil }
        guard let path = detail["path"] ?? detail["thumbnail_path"], path.hasPrefix("/") else { return nil }
        let dataRoot = URL(fileURLWithPath: account.dataDir).deletingLastPathComponent()
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wxview/cache").appendingPathComponent(account.account)
        guard !account.account.contains("/"), account.account != "..", account.account != "." else { return nil }
        return LocalMedia(path: path, roots: [dataRoot, cache], isImage: image,
                          isThumbnail: detail["thumbnail"] == "true" || detail["path"] == nil)
    }
    func validatedURL() throws -> URL {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard roots.contains(where: { url.path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") }) else {
            throw WxFailure(message: "附件路径超出当前账号目录")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= MediaIO.limit else {
            throw WxFailure(message: "附件不存在、不是普通文件或超过 32 MB")
        }
        return url
    }
}

struct TaskAttachment: Codable, Identifiable {
    let id: UUID
    let name: String
    let path: String
    let sha256: String
    let isImage: Bool
    let isThumbnail: Bool
}

actor MediaIO {
    static let shared = MediaIO()
    static let limit = 32 * 1024 * 1024
    static var directory: URL { DesktopCapture.directory.deletingLastPathComponent().appendingPathComponent("Attachments") }
    static func bytes(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard !data.isEmpty, data.count <= limit else { throw WxFailure(message: "附件为空或超过 32 MB") }
        return data
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func image(_ data: Data, size: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw WxFailure(message: "无法解码本地图片") }
        return image
    }
    func thumbnail(_ media: LocalMedia) throws -> CGImage {
        try Task.checkCancellation()
        return try Self.image(Self.bytes(media.validatedURL()), size: 400)
    }
    func validate(_ media: LocalMedia) throws -> URL { try media.validatedURL() }
    func snapshot(_ media: LocalMedia, root: URL = MediaIO.directory) throws -> TaskAttachment {
        try Self.makeSnapshot(media, root: root)
    }
    static func makeSnapshot(_ media: LocalMedia, root: URL) throws -> TaskAttachment {
        let url = try media.validatedURL(), data = try Self.bytes(url)
        if media.isImage { _ = try Self.image(data, size: 64) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID(), suffix = url.pathExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(12)
        let destination = root.appendingPathComponent(id.uuidString + (suffix.isEmpty ? "" : "." + suffix))
        try data.write(to: destination, options: .atomic)
        do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return TaskAttachment(id: id, name: media.name, path: destination.path, sha256: Self.digest(data), isImage: media.isImage, isThumbnail: media.isThumbnail)
    }
    static func png(_ data: Data) throws -> Data {
        let image = try image(data, size: 4096)
        let result = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else { throw WxFailure(message: "图片转换失败") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw WxFailure(message: "图片转换失败") }
        return result as Data
    }
}
