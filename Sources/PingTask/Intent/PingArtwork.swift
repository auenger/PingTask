import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ArtworkItem: Codable, Identifiable {
    let id: String
    let title: String
    let group: String
}

enum PingArtwork {
    static let centerDefault = "pingwheel_basicpingrender"
    static let cache = NSCache<NSString, NSImage>()
    static var resourceBundle: Bundle {
        if let root = Bundle.main.resourceURL,
           let packaged = Bundle(url: root.appendingPathComponent("PingTask_PingTask.bundle")) { return packaged }
        return .module
    }
    static let catalog: [ArtworkItem] = {
        guard let url = resourceBundle.url(forResource: "artwork-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url), let items = try? JSONDecoder().decode([ArtworkItem].self, from: data) else { return [] }
        return items
    }()
    static var names: [String] { catalog.map(\.id) }
    static var customDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PingTaskPrototype/Artwork")
    }
    static func name(for action: PingAction) -> String { action.artwork ?? defaultName(for: action.id) }
    static func defaultName(for id: String) -> String {
        switch id {
        case "analyze": return "png_enemymissing_128x128"
        case "plan": return "png_assist_me_128x128"
        case "implement": return "png_all_in"
        case "continue": return "omw"
        default: return centerDefault
        }
    }
    static func customURL(_ ref: String, directory: URL = customDirectory) -> URL? {
        guard ref.hasPrefix("custom:"), let uuid = UUID(uuidString: String(ref.dropFirst(7))) else { return nil }
        return directory.appendingPathComponent(uuid.uuidString + ".png")
    }
    static func image(_ name: String) -> NSImage? {
        if let image = cache.object(forKey: name as NSString) { return image }
        let url = name.hasPrefix("custom:") ? customURL(name) : resourceBundle.url(forResource: name, withExtension: "png")
        if let url, let image = NSImage(contentsOf: url) {
            cache.setObject(image, forKey: name as NSString); return image
        }
        // Missing imported files remain visible as a placeholder, never an invisible wheel slot.
        return NSImage(systemSymbolName: "photo", accessibilityDescription: "图片不可用")
    }
    static func customItems(directory: URL) -> [ArtworkItem] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ArtworkItem(id: "custom:" + $0.deletingPathExtension().lastPathComponent,
                               title: "自定义 " + $0.lastPathComponent.prefix(6), group: "自定义") }
    }
    /// Decode a bounded first frame off the main thread, stripping metadata and storing a private PNG copy.
    static func importImage(at url: URL, directory: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 20 * 1024 * 1024 else {
            throw WxFailure(message: "请选择不超过 20 MB 的图片文件")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, max(width, height) <= 8192,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { throw WxFailure(message: "无法读取图片，请使用边长不超过 8192 像素的 PNG、JPEG、HEIC、GIF 或 WebP") }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
            throw WxFailure(message: "图片转换失败")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WxFailure(message: "图片转换失败") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let ref = "custom:" + UUID().uuidString
        let target = customURL(ref, directory: directory)!
        try (encoded as Data).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return ref
    }
}
