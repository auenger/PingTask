import AppKit
import ApplicationServices

enum PingTrigger: String, CaseIterable, Identifiable {
    case alt, control, rightDrag, shortcut
    var id: String { rawValue }
    var label: String {
        switch self { case .alt: return "⌥ Option / Alt"; case .control: return "⌃ Ctrl / Control"; case .rightDrag: return "鼠标右键拖动"; case .shortcut: return "自定义快捷键" }
    }
    var symbol: String { if self == .shortcut { return "快捷键" }; return self == .rightDrag ? "右键" : (self == .alt ? "⌥" : "⌃") }
    var mask: CGEventFlags { (self == .rightDrag || self == .shortcut) ? [] : (self == .alt ? .maskAlternate : .maskControl) }
    var cancellationHint: String { self == .rightDrag ? "回到中心、Esc 或左键取消" : "回到中心、Esc 或右键取消" }
    var instructions: String {
        self == .rightDrag
            ? "按住鼠标右键，拖动超过 10 点显示轮盘，移向动作后松手触发。\(cancellationHint)。普通右键点击在松开时打开菜单；此模式接管右键拖动。"
            : "按住触发键，移动选择，松手触发。\(cancellationHint)。其他组合键继续交给当前应用。"
    }
    func isOther(_ flags: CGEventFlags) -> Bool {
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        return !flags.intersection(modifiers.subtracting(mask)).isEmpty
    }
}

struct PingKeyboardShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
    var keyLabel: String
    static let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
    static let standard = Self(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue, keyLabel: "Space")
    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers).intersection(Self.modifierMask) }
    var label: String {
        [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
            .filter { flags.contains($0.0) }.map { $0.1 }.joined() + " " + keyLabel
    }
    func matches(key: UInt16, flags: CGEventFlags) -> Bool {
        key == keyCode && flags.intersection(Self.modifierMask) == self.flags
    }
}

// Consume only the configured chord. Repeats cannot create another gesture; cancellation
// retains ownership until key-up so an application never receives an orphaned release.
struct PingShortcutState {
    private(set) var held = false
    private(set) var active = false
    mutating func down(matches: Bool, point: CGPoint) -> PingInputSignal? {
        if held { return nil }
        guard matches else { return nil }
        held = true; active = true
        return .begin(point)
    }
    mutating func up(point: CGPoint) -> PingInputSignal? {
        defer { held = false; active = false }
        return active ? .release(point) : nil
    }
    mutating func cancel() { active = false }
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

// Own the complete suppressed right-button sequence, including cancellation until mouse-up.
// A click is replayed only if it never crossed the drag threshold and was not canceled.
struct PingRightDragState {
    private(set) var origin: CGPoint?
    private(set) var dragging = false
    private var canceled = false
    mutating func down(at point: CGPoint) { origin = point; dragging = false; canceled = false }
    mutating func move(to point: CGPoint) -> [PingInputSignal] {
        guard let origin, !canceled else { return [] }
        if !dragging {
            guard hypot(point.x - origin.x, point.y - origin.y) > 10 else { return [] }
            dragging = true
            return [.begin(origin), .move(point)]
        }
        return [.move(point)]
    }
    mutating func up(at point: CGPoint) -> (replayClick: Bool, signal: PingInputSignal?) {
        guard origin != nil else { return (false, nil) }
        defer { self = Self() }
        return (!dragging && !canceled, dragging && !canceled ? .release(point) : nil)
    }
    mutating func cancel() { if origin != nil { canceled = true } }
}

// Event tap does no capture, window queries, OCR, or CLI. All work is queued to its owner.
@MainActor final class GlobalPingInput {
    typealias Signal = PingInputSignal
    var trigger: PingTrigger = .alt
    var shortcut = PingKeyboardShortcut.standard
    var recordingShortcut = false
    var receive: ((Signal) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var state = PingInputState()
    private var rightState = PingRightDragState()
    private var rightDown: CGEvent?
    private var shortcutState = PingShortcutState()
    private var heldShortcutKey: UInt16?

    func start() throws {
        stop()
        guard AXIsProcessTrusted() else { throw WxFailure(message: "请先授权辅助功能，再启用全局 Ping") }
        let types: [CGEventType] = [.flagsChanged, .mouseMoved, .leftMouseDragged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .rightMouseDragged, .rightMouseUp, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: { proxy, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<GlobalPingInput>.fromOpaque(context).takeUnretainedValue().handle(type, event, proxy: proxy)
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
        rightState = PingRightDragState(); rightDown = nil
        shortcutState = PingShortcutState(); heldShortcutKey = nil
        emit(.cancel)
    }
    func disarm() { state.cancel(); rightState.cancel(); shortcutState.cancel() }
    private func emit(_ signal: Signal) {
        DispatchQueue.main.async { [weak self] in self?.receive?(signal) }
    }
    private func handle(_ type: CGEventType, _ event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            state = PingInputState(); rightState.cancel(); shortcutState.cancel(); emit(.cancel)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // A fresh down also recovers if macOS dropped the previous up while the tap was disabled.
        if type == .rightMouseDown && rightState.origin != nil {
            rightState = PingRightDragState(); rightDown = nil; emit(.cancel)
        }
        // Finish a claimed mouse sequence even if the trigger setting changes or the wheel expires.
        if rightState.origin != nil {
            if type == .rightMouseUp {
                let result = rightState.up(at: event.location)
                if result.replayClick, let rightDown { rightDown.tapPostEvent(proxy) }
                rightDown = nil
                if let signal = result.signal { emit(signal) }
                return result.replayClick ? Unmanaged.passUnretained(event) : nil
            }
            if type == .rightMouseDragged {
                for signal in rightState.move(to: event.location) { emit(signal) }
                return nil
            }
            if type == .keyDown || type == .flagsChanged || type == .leftMouseDown || type == .otherMouseDown || type == .scrollWheel {
                rightState.cancel(); emit(.cancel)
                if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 { return nil }
            }
            return Unmanaged.passUnretained(event)
        }
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if shortcutState.held {
            if type == .keyUp && key == heldShortcutKey {
                if let signal = shortcutState.up(point: event.location) { emit(signal) }
                heldShortcutKey = nil
                return nil
            }
            if type == .keyDown && key == heldShortcutKey { return nil }
            if type == .mouseMoved || type == .leftMouseDragged {
                if shortcutState.active { emit(.move(event.location)) }
            } else if type != .keyUp {
                // Releasing a modifier before the main key cancels the gesture.
                if type != .flagsChanged || event.flags.intersection(PingKeyboardShortcut.modifierMask) != shortcut.flags {
                    shortcutState.cancel(); emit(.cancel)
                    if type == .keyDown && key == 53 { return nil }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        if recordingShortcut { return Unmanaged.passUnretained(event) }
        if trigger == .shortcut {
            if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               let signal = shortcutState.down(matches: shortcut.matches(key: key, flags: event.flags), point: event.location) {
                heldShortcutKey = key; emit(signal)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        if trigger == .rightDrag {
            if type == .rightMouseDown && !trigger.isOther(event.flags), let copy = event.copy() {
                rightDown = copy
                rightState.down(at: event.location)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged {
            let option = event.flags.contains(trigger.mask)
            let other = trigger.isOther(event.flags)
            if let signal = state.flags(option: option, other: other, point: event.location) { emit(signal) }
        } else if state.armed && (type == .mouseMoved || type == .leftMouseDragged) {
            emit(.move(event.location))
        } else if state.armed && type != .keyUp {
            let escape = type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53
            state.cancel(); emit(.cancel)
            // Preserve ordinary Option shortcuts/clicks; only Escape dismisses our active gesture.
            if escape { return nil }
        }
        return Unmanaged.passUnretained(event)
    }
}
