import AppKit
import SwiftUI

struct MirrorCanvas: NSViewRepresentable {
    @ObservedObject var store: MirrorStore

    func makeNSView(context: Context) -> MirrorCanvasView {
        let view = MirrorCanvasView()
        view.commandHandler = { [weak store] command in store?.send(command) }
        return view
    }

    func updateNSView(_ view: MirrorCanvasView, context: Context) {
        view.screenSize = store.details.resolution
        view.displayedImage = store.image
        view.inputPlatform = store.selectedPlatform
        view.usesRealtimeTouch = store.selectedPlatform == .android || store.harmonyRealtimeTouch
    }
}

class MirrorCanvasView: NSView, NSTextInputClient {
    var commandHandler: ((RemoteCommand) -> Void)?
    var screenSize = CGSize(width: 1260, height: 2720) { didSet { needsDisplay = true } }
    var displayedImage: NSImage? { didSet { needsDisplay = true } }
    var usesRealtimeTouch = false
    var inputPlatform: DevicePlatform?

    private var touchActive = false
    private var touchStartLocation: CGPoint?
    private var mouseDownDate: Date?
    private var lastTouchPoint: CGPoint?
    private var lastMoveSentAt = Date.distantPast
    private var markedText = NSMutableAttributedString()
    private var keyMonitor: Any?
    private var lastScrollAt = Date.distantPast

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow else { return event }
                guard Self.handlesKeyEvent(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
                    return event
                }
                self.handleKeyDown(event)
                return nil
            }
        }
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let displayedImage else { return }
        let target = GeometryMapper.aspectFitRect(contentSize: displayedImage.size, in: bounds)
        displayedImage.draw(in: target, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.medium])
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let local = convert(event.locationInWindow, from: nil)
        guard let point = normalized(local) else { return }
        touchActive = true
        touchStartLocation = local
        mouseDownDate = Date()
        lastTouchPoint = point
        lastMoveSentAt = Date()
        if usesRealtimeTouch { commandHandler?(.touchDown(point)) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard touchActive, usesRealtimeTouch else { return }
        let local = convert(event.locationInWindow, from: nil)
        guard let point = normalizedClamped(local) else { return }
        if let touchStartLocation, hypot(local.x - touchStartLocation.x, local.y - touchStartLocation.y) < 4 { return }
        let now = Date()
        guard now.timeIntervalSince(lastMoveSentAt) >= 1.0 / 60.0 else { return }
        if let lastTouchPoint, hypot(point.x - lastTouchPoint.x, point.y - lastTouchPoint.y) < 0.0005 { return }
        lastTouchPoint = point
        lastMoveSentAt = now
        commandHandler?(.touchMove(point))
    }

    override func mouseUp(with event: NSEvent) {
        guard touchActive else { return }
        let local = convert(event.locationInWindow, from: nil)
        let point = normalizedClamped(local) ?? lastTouchPoint
        if usesRealtimeTouch {
            if let point { commandHandler?(.touchUp(point)) }
        } else if let startLocation = touchStartLocation,
                  let from = normalized(startLocation), let to = point {
            if hypot(local.x - startLocation.x, local.y - startLocation.y) < 5 {
                commandHandler?(.tap(to))
            } else {
                commandHandler?(.swipe(from: from, to: to, duration: Date().timeIntervalSince(mouseDownDate ?? Date())))
            }
        }
        touchActive = false
        touchStartLocation = nil
        mouseDownDate = nil
        lastTouchPoint = nil
    }

    override func rightMouseUp(with event: NSEvent) { commandHandler?(.namedKey("Back")) }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { commandHandler?(.namedKey("Home")) }
    }

    override func scrollWheel(with event: NSEvent) {
        if usesRealtimeTouch, inputPlatform == .harmonyOS {
            handleHarmonyScroll(event)
            return
        }
        let minimumInterval = usesRealtimeTouch ? 1.0 / 60.0 : 0.12
        guard abs(event.scrollingDeltaY) > (usesRealtimeTouch ? 0.01 : 0.4) || abs(event.scrollingDeltaX) > 0.01,
              Date().timeIntervalSince(lastScrollAt) >= minimumInterval else { return }
        lastScrollAt = Date()
        if usesRealtimeTouch {
            let local = convert(event.locationInWindow, from: nil)
            guard let point = normalizedClamped(local) else { return }
            commandHandler?(.scroll(at: point, deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY)))
        } else {
            let upward = event.scrollingDeltaY < 0
            commandHandler?(.swipe(
                from: CGPoint(x: 0.5, y: upward ? 0.67 : 0.38),
                to: CGPoint(x: 0.5, y: upward ? 0.38 : 0.67),
                duration: 0.18
            ))
        }
    }

    override func keyDown(with event: NSEvent) {
        if Self.handlesKeyEvent(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            handleKeyDown(event)
        } else {
            super.keyDown(with: event)
        }
    }

    static func handlesKeyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let normalized = modifiers.intersection(.deviceIndependentFlagsMask)
        if normalized.contains(.command) {
            // Command-A/C/V/X/Z are intentionally forwarded to Android and
            // HarmonyOS. All other Command shortcuts belong to macOS.
            return [0, 8, 9, 7, 6].contains(keyCode)
        }
        return true
    }

    private func handleKeyDown(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            switch event.keyCode {
            case 9:
                if let value = NSPasteboard.general.string(forType: .string), !value.isEmpty { commandHandler?(.text(value)) }
            case 0: commandHandler?(.keyCombination(2072, 2017))
            case 8: commandHandler?(.keyCombination(2072, 2019))
            case 7: commandHandler?(.keyCombination(2072, 2040))
            case 6: commandHandler?(.keyCombination(2072, 2042))
            default: return
            }
            return
        }
        switch event.keyCode {
        case 51: commandHandler?(.keyCode(2055))
        case 117: commandHandler?(.keyCode(2071))
        case 36, 76: commandHandler?(.keyCode(2054))
        case 48: commandHandler?(.keyCode(2049))
        case 53: commandHandler?(.namedKey("Back"))
        case 123: commandHandler?(.keyCode(2014))
        case 124: commandHandler?(.keyCode(2015))
        case 125: commandHandler?(.keyCode(2013))
        case 126: commandHandler?(.keyCode(2012))
        default: interpretKeyEvents([event])
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let value = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if !value.isEmpty { commandHandler?(.text(value)) }
        markedText = NSMutableAttributedString()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else {
            markedText = NSMutableAttributedString(string: string as? String ?? "")
        }
    }

    func unmarkText() { markedText = NSMutableAttributedString() }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let local = NSRect(x: bounds.midX, y: bounds.maxY - 30, width: 1, height: 20)
        guard let window else { return local }
        return window.convertToScreen(convert(local, to: nil))
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(deleteBackward(_:)): commandHandler?(.keyCode(2055))
        case #selector(deleteForward(_:)): commandHandler?(.keyCode(2071))
        case #selector(insertNewline(_:)): commandHandler?(.keyCode(2054))
        case #selector(insertTab(_:)): commandHandler?(.keyCode(2049))
        case #selector(moveLeft(_:)): commandHandler?(.keyCode(2014))
        case #selector(moveRight(_:)): commandHandler?(.keyCode(2015))
        case #selector(moveDown(_:)): commandHandler?(.keyCode(2013))
        case #selector(moveUp(_:)): commandHandler?(.keyCode(2012))
        default: break
        }
    }

    private func normalized(_ point: CGPoint) -> CGPoint? {
        let imageSize = displayedImage?.size ?? screenSize
        return GeometryMapper.normalized(point, contentRect: GeometryMapper.aspectFitRect(contentSize: imageSize, in: bounds))
    }

    private func normalizedClamped(_ point: CGPoint) -> CGPoint? {
        let imageSize = displayedImage?.size ?? screenSize
        return GeometryMapper.normalizedClamped(point, contentRect: GeometryMapper.aspectFitRect(contentSize: imageSize, in: bounds))
    }

    private var harmonyScrollPoint: CGPoint?
    private var harmonyScrollEndWorkItem: DispatchWorkItem?

    private func handleHarmonyScroll(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let anchor = normalizedClamped(local) else { return }
        if event.phase == .cancelled || event.phase == .ended {
            if let point = harmonyScrollPoint { commandHandler?(.touchUp(point)) }
            harmonyScrollPoint = nil
            harmonyScrollEndWorkItem?.cancel()
            harmonyScrollEndWorkItem = nil
            return
        }
        if harmonyScrollPoint == nil {
            harmonyScrollPoint = anchor
            commandHandler?(.touchDown(anchor))
        }
        let now = Date()
        guard now.timeIntervalSince(lastScrollAt) >= 1.0 / 120.0 else { return }
        lastScrollAt = now
        guard let current = harmonyScrollPoint else { return }
        let scale = 3.0
        let next = CGPoint(
            x: (current.x - event.scrollingDeltaX * scale / max(bounds.width, 1)).clamped01,
            y: (current.y + event.scrollingDeltaY * scale / max(bounds.height, 1)).clamped01
        )
        if hypot(next.x - current.x, next.y - current.y) >= 0.001 {
            harmonyScrollPoint = next
            commandHandler?(.touchMove(next))
        }
        guard event.phase.isEmpty else { return }
        harmonyScrollEndWorkItem?.cancel()
        let end = DispatchWorkItem { [weak self] in
            guard let self, let point = self.harmonyScrollPoint else { return }
            self.commandHandler?(.touchUp(point))
            self.harmonyScrollPoint = nil
            self.harmonyScrollEndWorkItem = nil
        }
        harmonyScrollEndWorkItem = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: end)
    }
}
