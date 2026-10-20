import AppKit
import ApplicationServices

enum PingTrigger: String, CaseIterable, Identifiable {
    case alt, control
    var id: String { rawValue }
    var label: String { self == .alt ? "⌥ Alt / Option" : "⌃ Ctrl / Control" }
    var symbol: String { self == .alt ? "⌥" : "⌃" }
    var mask: CGEventFlags { self == .alt ? .maskAlternate : .maskControl }
    func isOther(_ flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskCommand, .maskShift, self == .alt ? .maskControl : .maskAlternate]).isEmpty
    }
}

enum PingInputSignal: Equatable { case begin(CGPoint), move(CGPoint), release(CGPoint), cancel }
struct PingInputState {
    var armed = false
    var optionDown = false
    mutating func flags(option: Bool, other: Bool, point: CGPoint) -> PingInputSignal? {
        defer { optionDown = option }
        if option && !optionDown && !other { armed = true; return .begin(point) }
        if armed && other { armed = false; return .cancel }
        if !option && optionDown && armed { armed = false; return .release(point) }
        return nil
    }
    mutating func cancel() { armed = false }
}

// Event tap does no capture, window queries, OCR, or CLI. All work is queued to its owner.
@MainActor final class GlobalPingInput {
    typealias Signal = PingInputSignal
    var trigger: PingTrigger = .alt
    var receive: ((Signal) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var state = PingInputState()

    func start() throws {
        stop()
        guard AXIsProcessTrusted() else { throw WxFailure(message: "请先授权辅助功能，再启用全局 Ping") }
        let types: [CGEventType] = [.flagsChanged, .mouseMoved, .leftMouseDragged, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<GlobalPingInput>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw WxFailure(message: "无法安装全局输入监听；请检查辅助功能授权并重新启动应用")
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; state = PingInputState()
        emit(.cancel)
    }
    func disarm() { state.cancel() }
    private func emit(_ signal: Signal) {
        DispatchQueue.main.async { [weak self] in self?.receive?(signal) }
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            state = PingInputState(); emit(.cancel)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged {
            let option = event.flags.contains(trigger.mask)
            let other = trigger.isOther(event.flags)
            if let signal = state.flags(option: option, other: other, point: event.location) { emit(signal) }
        } else if state.armed && (type == .mouseMoved || type == .leftMouseDragged) {
            emit(.move(event.location))
        } else if state.armed {
            let escape = type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53
            state.cancel(); emit(.cancel)
            // Preserve ordinary Option shortcuts/clicks; only Escape dismisses our active gesture.
            if escape { return nil }
        }
        return Unmanaged.passUnretained(event)
    }
}
