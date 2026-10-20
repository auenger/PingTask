import AppKit
import ScreenCaptureKit
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct DesktopTarget: Codable {
    let windowID: UInt32
    let processID: Int32
    let appName: String
    let bundleID: String
    let title: String
    let bounds: CGRect // Quartz global points, top-left origin.
    let pointer: CGPoint
    let displayID: UInt32
    let scale: CGFloat
}
struct OCRLine: Codable {
    let text: String
    let bounds: CGRect // Normalized Vision coordinates, bottom-left origin.
    let confidence: Float
}
struct DesktopCapture: Codable, Identifiable {
    let id: UUID
    let created: Date
    let target: DesktopTarget
    let pixelWidth: Int
    let pixelHeight: Int
    let lines: [OCRLine]
    var imageURL: URL { Self.directory.appendingPathComponent("\(id.uuidString).png") }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PingTaskPrototype/Captures", isDirectory: true)
    }
    var pointedText: String { CaptureGeometry.pointedLine(lines, target: target)?.text ?? "" }
    var evidence: String {
        "桌面单次窗口截图 · \(created.formatted())\n\(target.appName) · \(target.title) · 窗口 \(target.windowID)\n\(pixelWidth) × \(pixelHeight) 像素 · 缩放 \(target.scale) · OCR 最多 400 行，仅为定位线索"
    }
}

enum CaptureGeometry {
    static func slice(delta: CGPoint, deadZone: CGFloat = 46) -> Int? {
        guard hypot(delta.x, delta.y) > deadZone else { return nil }
        // Input is top-left coordinates: north, east, south, west.
        return (Int(((atan2(delta.y, delta.x) + .pi / 2) / (.pi / 2)).rounded()) + 4) % 4
    }
    static func appKitPoint(_ quartz: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: quartz.x, y: primaryHeight - quartz.y)
    }
    static func normalizedPointer(_ target: DesktopTarget) -> CGPoint {
        CGPoint(x: (target.pointer.x - target.bounds.minX) / target.bounds.width,
                y: 1 - (target.pointer.y - target.bounds.minY) / target.bounds.height)
    }
    static func pointedLine(_ lines: [OCRLine], target: DesktopTarget) -> OCRLine? {
        let p = normalizedPointer(target)
        let candidates = lines.filter { line in
            let r = line.bounds.insetBy(dx: -18 / target.bounds.width, dy: -12 / target.bounds.height)
            return line.confidence >= 0.4 && r.contains(p)
        }
        return candidates.min { abs($0.bounds.midY - p.y) < abs($1.bounds.midY - p.y) }
    }
}

enum DesktopCaptureService {
    // Called outside the event tap, before the overlay appears.
    static func target(at point: CGPoint) throws -> DesktopTarget {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw WxFailure(message: "无法读取目标窗口")
        }
        for info in windows {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let raw = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary), bounds.contains(point),
                  bounds.width > 40, bounds.height > 40,
                  let id = info[kCGWindowNumber as String] as? UInt32 else { continue }
            guard pid != getpid() else { throw WxFailure(message: "请指向其他应用的信息后再 Ping") }
            var display = CGMainDisplayID(), count: UInt32 = 0
            CGGetDisplaysWithPoint(point, 1, &display, &count)
            let screenWidth = CGDisplayBounds(display).width
            let scale = screenWidth > 0 ? CGFloat(CGDisplayPixelsWide(display)) / screenWidth : 1
            return DesktopTarget(windowID: id, processID: pid,
                                 appName: info[kCGWindowOwnerName as String] as? String ?? "未知应用",
                                 bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "",
                                 title: info[kCGWindowName as String] as? String ?? "",
                                 bounds: bounds, pointer: point, displayID: display, scale: scale)
        }
        throw WxFailure(message: "指针下没有可捕获的其他应用窗口；请指向消息后再 Ping")
    }

    static func capture(_ target: DesktopTarget) async throws -> DesktopCapture {
        guard CGPreflightScreenCaptureAccess() else { throw WxFailure(message: "尚未授权屏幕录制，请在桌面 Ping 页授权后重试") }
        let content: SCShareableContent = try await CaptureDeadline.wait { completion in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true, completionHandler: completion)
        }
        guard let window = content.windows.first(where: { $0.windowID == target.windowID && $0.owningApplication?.processID == target.processID }) else {
            throw WxFailure(message: "目标窗口已关闭或不可见，请重新 Ping")
        }
        guard abs(window.frame.minX - target.bounds.minX) < 2,
              abs(window.frame.minY - target.bounds.minY) < 2,
              abs(window.frame.width - target.bounds.width) < 2,
              abs(window.frame.height - target.bounds.height) < 2 else {
            throw WxFailure(message: "选择期间窗口移动或尺寸变化，请重新 Ping")
        }
        // A window-specific filter excludes all other windows, including our wheel.
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = max(1, min(target.scale, 2))
        let fit = min(1, 4096 / max(window.frame.width * scale, window.frame.height * scale))
        config.width = max(1, Int(window.frame.width * scale * fit))
        config.height = max(1, Int(window.frame.height * scale * fit))
        config.scalesToFit = true
        config.showsCursor = false
        config.capturesAudio = false
        config.queueDepth = 1
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let image: CGImage
        if #available(macOS 14.0, *) {
            config.ignoreShadowsSingleWindow = true
            image = try await CaptureDeadline.wait { completion in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config, completionHandler: completion)
            }
        } else {
            image = try await OneFrameCapture.take(filter: filter, configuration: config)
        }
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = false
            // OCR failure must not discard the captured evidence. An empty result stays unresolved.
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).prefix(400).compactMap { observation -> OCRLine? in
                guard let text = observation.topCandidates(1).first else { return nil }
                return OCRLine(text: String(text.string.prefix(1000)), bounds: observation.boundingBox, confidence: text.confidence)
            }
            let capture = DesktopCapture(id: UUID(), created: Date(), target: target,
                                         pixelWidth: image.width, pixelHeight: image.height, lines: lines)
            try FileManager.default.createDirectory(at: DesktopCapture.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw WxFailure(message: "无法编码截图")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw WxFailure(message: "截图编码失败") }
            try (data as Data).write(to: capture.imageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: capture.imageURL.path)
            return capture
        }.value
    }
}

// macOS 13 fallback: collect one complete frame, stop the stream on success/error/timeout.
private final class OneFrameCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var stream: SCStream?
    private var deadline: DispatchWorkItem?
    static func take(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        let receiver = OneFrameCapture()
        return try await withCheckedThrowingContinuation { continuation in
            receiver.continuation = continuation
            let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
            receiver.stream = stream
            do {
                try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: DispatchQueue(label: "PingTask.single-frame"))
                let deadline = DispatchWorkItem { receiver.finish(.failure(WxFailure(message: "单次截图超时，请检查屏幕录制权限"))) }
                receiver.deadline = deadline
                DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: deadline)
                stream.startCapture { error in if let error { receiver.finish(.failure(error)) } }
            } catch { receiver.finish(.failure(error)) }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { finish(.failure(error)) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let raw = attachments.first?[.contentRect] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: raw as CFDictionary),
              let factor = attachments.first?[.scaleFactor] as? CGFloat else { return }
        // contentRect is in surface points; pixel buffers use pixels and CI uses bottom-left coordinates.
        let crop = CGRect(x: rect.minX * factor, y: ci.extent.height - rect.maxY * factor,
                          width: rect.width * factor, height: rect.height * factor).integral
        guard crop.width > 0, crop.height > 0, ci.extent.contains(crop),
              let image = CIContext().createCGImage(ci, from: crop) else { return }
        finish(.success(image))
    }
    private func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let stream = self.stream; self.stream = nil
        deadline?.cancel(); deadline = nil
        lock.unlock()
        // Always request stop, but a stalled capture service must not hold our timeout continuation.
        stream?.stopCapture { _ in }
        continuation.resume(with: result)
    }
}

// Completion APIs may fail to call back after a permission/service transition. Never hold the UI indefinitely.
private final class CaptureDeadline<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeout: DispatchWorkItem?
    static func wait(_ start: (@escaping @Sendable (Value?, Error?) -> Void) -> Void) async throws -> Value {
        let reply = CaptureDeadline<Value>()
        return try await withCheckedThrowingContinuation { continuation in
            reply.continuation = continuation
            let timeout = DispatchWorkItem { reply.finish(nil, WxFailure(message: "系统截图请求超时，请检查权限后重试")) }
            reply.timeout = timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            start { value, error in reply.finish(value, error) }
        }
    }
    private func finish(_ value: Value?, _ error: Error?) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        lock.unlock()
        if let value { continuation.resume(returning: value) }
        else { continuation.resume(throwing: error ?? WxFailure(message: "系统未返回截图内容")) }
    }
}
