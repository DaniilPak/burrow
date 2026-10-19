import AppKit
import IOSurface
import QuartzCore
import BurrowCore
import SwiftUI

/// Shows a QEMU machine's screen inside the window and forwards keyboard and mouse,
/// speaking VNC (RFB 3.8) over QEMU's Unix socket.
struct QEMUDisplay: NSViewRepresentable {
    let machine: QEMUMachine

    func makeNSView(context: Context) -> QEMUScreenView {
        let view = QEMUScreenView()
        view.connect(to: machine.vncSocketPath)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: QEMUScreenView, context: Context) {
        view.connect(to: machine.vncSocketPath)
    }

    static func dismantleNSView(_ view: QEMUScreenView, coordinator: ()) {
        view.disconnect()
    }
}

final class QEMUScreenView: NSView {
    private var client: VNCClient?
    private var socketPath: String?
    private var framebufferSize = CGSize(width: 1024, height: 768)
    private var buttons: UInt8 = 0
    private var tracking: NSTrackingArea?
    private var sizedWindow = false
    /// Shows the guest's framebuffer. Its contents are an IOSurface the VNC thread writes
    /// changed rectangles into; Core Animation scales and composites it on the GPU.
    private let screenLayer = CALayer()
    private var surface: IOSurface?
    private var frameScheduled = false
    private let frameLock = NSLock()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.black.cgColor
        screenLayer.contentsGravity = .resize
        screenLayer.magnificationFilter = .linear
        screenLayer.minificationFilter = .trilinear
        screenLayer.isOpaque = true
        layer?.addSublayer(screenLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func connect(to path: String) {
        guard path != socketPath else { return }
        disconnect()
        socketPath = path
        let client = VNCClient(path: path)
        client.onFrame = { [weak self] surface in
            // Coalesce: at most one pending main-thread update, however fast frames arrive.
            guard let self, self.frameLock.withLock({ () -> Bool in
                defer { self.frameScheduled = true }
                return !self.frameScheduled
            }) else { return }
            DispatchQueue.main.async {
                self.frameLock.withLock { self.frameScheduled = false }
                self.show(surface)
            }
        }
        self.client = client
        client.start()
    }

    func disconnect() {
        client?.stop()
        client = nil
        socketPath = nil
    }

    // MARK: Window and cursor

    /// Keeps the window at the guest screen's proportions so the picture fills it without
    /// bars, and opens it as large as the screen allows.
    private func fitWindow() {
        guard let window, framebufferSize.width > 0, framebufferSize.height > 0, bounds.height > 0,
              !window.styleMask.contains(.fullScreen), !window.inLiveResize
        else { return }
        // Measure the window around this view (title bar, toolbar, borders) rather than trusting
        // contentLayoutRect: SwiftUI may lay the screen out under or beside other chrome.
        let extraWidth = window.frame.width - bounds.width
        let extraHeight = window.frame.height - bounds.height
        let aspect = framebufferSize.width / framebufferSize.height
        var frame = window.frame
        if !sizedWindow, let screen = window.screen ?? NSScreen.main {
            // First time: as large as the screen allows, centered.
            sizedWindow = true
            let available = screen.visibleFrame
            let height = min(available.height - extraHeight, (available.width - extraWidth) / aspect)
            frame.size = NSSize(width: (height * aspect).rounded() + extraWidth, height: height.rounded() + extraHeight)
            frame.origin = NSPoint(x: available.midX - frame.width / 2, y: available.maxY - frame.height)
        } else {
            // After a resize: keep the height the user chose and make the width match the picture.
            let width = (bounds.height * aspect).rounded() + extraWidth
            guard abs(width - frame.width) >= 1 else { return }
            frame.size.width = width
        }
        window.setFrame(frame, display: true, animate: false)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        fitWindow()
    }

    private var fullScreenObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sizedWindow = false
        fitWindow()
        fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
        fullScreenObservers = []
        guard let window else { return watchActivity() }
        // In full screen Windows gets the whole display: the toolbar hides and, as in other
        // Mac apps, the title bar slides down only when the pointer reaches the top edge.
        let center = NotificationCenter.default
        fullScreenObservers = [
            center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak window] _ in
                window?.toolbar?.isVisible = false
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak window, weak self] _ in
                window?.toolbar?.isVisible = true
                self?.fitWindow()
            },
        ]
        window.toolbar?.isVisible = !window.styleMask.contains(.fullScreen)
        watchActivity()
    }

    deinit {
        fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
        activityObservers.forEach(NotificationCenter.default.removeObserver)
        if macCursorHidden { NSCursor.unhide() }
        window?.toolbar?.isVisible = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screenLayer.frame = screenRect
        CATransaction.commit()
    }

    private func show(_ surface: IOSurface) {
        let size = CGSize(width: surface.width, height: surface.height)
        let resized = framebufferSize != size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if surface !== self.surface {
            self.surface = surface
            screenLayer.contents = surface
        } else {
            // Same surface, new pixels: tell Core Animation to re-read it. -setContentsChanged
            // isn't in the public headers; reassigning the contents is the fallback.
            let changed = Selector(("setContentsChanged"))
            if screenLayer.responds(to: changed) {
                screenLayer.perform(changed)
            } else {
                screenLayer.contents = nil
                screenLayer.contents = surface
            }
        }
        if resized {
            framebufferSize = size
            screenLayer.frame = screenRect
        }
        CATransaction.commit()
        if resized || !sizedWindow { fitWindow() }
    }

    /// The framebuffer scaled to fit, centered, keeping its aspect ratio.
    private var screenRect: CGRect {
        let scale = min(bounds.width / framebufferSize.width, bounds.height / framebufferSize.height)
        let size = CGSize(width: framebufferSize.width * scale, height: framebufferSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Mac pointer

    /// The Mac pointer hides while it is over Windows in the active window, leaving only
    /// Windows' own; it comes back over the toolbar, outside the window, or in other apps.
    private var macCursorHidden = false
    private var activityObservers: [NSObjectProtocol] = []

    private func setMacCursorHidden(_ hidden: Bool) {
        guard hidden != macCursorHidden else { return }
        macCursorHidden = hidden
        hidden ? NSCursor.hide() : NSCursor.unhide()
    }

    private var pointerIsInside: Bool {
        guard let window, window.isKeyWindow, NSApp.isActive else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseEntered(with event: NSEvent) { setMacCursorHidden(true) }
    override func mouseExited(with event: NSEvent) { setMacCursorHidden(false) }

    private func watchActivity() {
        activityObservers.forEach(NotificationCenter.default.removeObserver)
        activityObservers = []
        guard let window else { return setMacCursorHidden(false) }
        let center = NotificationCenter.default
        let refresh: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            self.setMacCursorHidden(self.pointerIsInside)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            activityObservers.append(center.addObserver(forName: name, object: window, queue: .main, using: refresh))
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            activityObservers.append(center.addObserver(forName: name, object: nil, queue: .main, using: refresh))
        }
        setMacCursorHidden(pointerIsInside)
    }

    private func sendPointer(_ event: NSEvent, extra: UInt8 = 0) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = screenRect
        guard rect.width > 0, rect.height > 0 else { return }
        let x = (point.x - rect.minX) / rect.width * framebufferSize.width
        let y = (point.y - rect.minY) / rect.height * framebufferSize.height
        let clampedX = UInt16(max(0, min(framebufferSize.width - 1, x)))
        let clampedY = UInt16(max(0, min(framebufferSize.height - 1, y)))
        client?.pointer(x: clampedX, y: clampedY, buttons: buttons | extra)
    }

    override func mouseMoved(with event: NSEvent) {
        if !macCursorHidden, pointerIsInside { setMacCursorHidden(true) }
        sendPointer(event)
    }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Control-click is a right click, as everywhere else on the Mac.
        buttons |= event.modifierFlags.contains(.control) ? 4 : 1
        sendPointer(event)
    }
    override func mouseUp(with event: NSEvent) { buttons &= ~5; sendPointer(event) }
    override func rightMouseDown(with event: NSEvent) { buttons |= 4; sendPointer(event) }
    override func rightMouseUp(with event: NSEvent) { buttons &= ~4; sendPointer(event) }
    override func otherMouseDown(with event: NSEvent) { buttons |= 2; sendPointer(event) }
    override func otherMouseUp(with event: NSEvent) { buttons &= ~2; sendPointer(event) }

    private var scrollRemainder: CGFloat = 0
    override func scrollWheel(with event: NSEvent) {
        scrollRemainder += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
        while abs(scrollRemainder) >= 1 {
            // Buttons 4 and 5 (masks 8 and 16) are wheel up and down.
            let mask: UInt8 = scrollRemainder > 0 ? 8 : 16
            sendPointer(event, extra: mask)
            sendPointer(event)
            scrollRemainder -= scrollRemainder > 0 ? 1 : -1
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { return }
        send(event, down: true)
    }
    override func keyUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { return }
        send(event, down: false)
    }

    /// ⌘ shortcuts that mean the same as Ctrl ones in Windows (copy, paste, undo, save, …).
    private static let commandAsControl = Set("acfnoprstvxyz")

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command) {
            // ⌘C, ⌘V, … become Ctrl+C, Ctrl+V in Windows; ⌘Q, ⌘W, ⌘H, ⌘Tab stay with the Mac.
            guard let key = event.charactersIgnoringModifiers?.lowercased().first,
                  Self.commandAsControl.contains(key), let scalar = key.unicodeScalars.first
            else { return super.performKeyEquivalent(with: event) }
            let shifted = event.modifierFlags.contains(.shift)
            client?.key(0xFFE3, down: true)
            if shifted { client?.key(0xFFE1, down: true) }
            client?.key(scalar.value, down: true)
            client?.key(scalar.value, down: false)
            if shifted { client?.key(0xFFE1, down: false) }
            client?.key(0xFFE3, down: false)
            return true
        }
        send(event, down: true)
        send(event, down: false)
        return true
    }

    private var heldModifiers: NSEvent.ModifierFlags = []
    override func flagsChanged(with event: NSEvent) {
        // Caps Lock isn't forwarded: typed characters already arrive in the right case.
        let pairs: [(NSEvent.ModifierFlags, UInt32)] = [(.shift, 0xFFE1), (.control, 0xFFE3), (.option, 0xFFE9)]
        let now = event.modifierFlags.intersection([.shift, .control, .option])
        for (flag, keysym) in pairs where now.contains(flag) != heldModifiers.contains(flag) {
            client?.key(keysym, down: now.contains(flag))
        }
        heldModifiers = now
    }

    override func resignFirstResponder() -> Bool {
        // Release held modifiers so the guest doesn't think Shift is stuck.
        for keysym: UInt32 in [0xFFE1, 0xFFE3, 0xFFE9] { client?.key(keysym, down: false) }
        heldModifiers = []
        return super.resignFirstResponder()
    }

    private func send(_ event: NSEvent, down: Bool) {
        if let keysym = Self.specialKeys[event.keyCode] {
            client?.key(keysym, down: down)
            return
        }
        // Option produces composed characters on the Mac; the guest wants the plain key.
        let source = event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control)
            ? event.charactersIgnoringModifiers : event.characters
        guard let scalar = source?.unicodeScalars.first else { return }
        let value = scalar.value
        // Latin-1 maps to keysyms directly; other characters use the Unicode keysym range.
        let keysym = value < 0x100 ? value : 0x0100_0000 | value
        client?.key(keysym, down: down)
    }

    /// Mac virtual key codes for keys that don't produce printable characters.
    private static let specialKeys: [UInt16: UInt32] = [
        36: 0xFF0D, 76: 0xFF8D, 48: 0xFF09, 51: 0xFF08, 117: 0xFFFF, 53: 0xFF1B,
        123: 0xFF51, 124: 0xFF53, 125: 0xFF54, 126: 0xFF52,
        115: 0xFF50, 119: 0xFF57, 116: 0xFF55, 121: 0xFF56, 114: 0xFF63,
        122: 0xFFBE, 120: 0xFFBF, 99: 0xFFC0, 118: 0xFFC1, 96: 0xFFC2, 97: 0xFFC3,
        98: 0xFFC4, 100: 0xFFC5, 101: 0xFFC6, 109: 0xFFC7, 103: 0xFFC8, 111: 0xFFC9,
        49: 0x0020,
    ]
}

/// A small RFB client: no authentication, 32-bit true colour, Raw and DesktopSize encodings.
final class VNCClient: @unchecked Sendable {
    private let path: String
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private var stopped = false
    private var width = 0
    private var height = 0
    /// The guest screen, shared with Core Animation; changed rectangles are read into it in place.
    private var surface: IOSurface?

    /// Called on the reader thread after each update has been written into the surface.
    var onFrame: ((IOSurface) -> Void)?

    init(path: String) { self.path = path }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "Burrow VNC"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        writeLock.withLock { stopped = true }
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    // MARK: Input

    func key(_ keysym: UInt32, down: Bool) {
        var message = Data([4, down ? 1 : 0, 0, 0])
        message.append(contentsOf: be32(keysym))
        send(message)
    }

    func pointer(x: UInt16, y: UInt16, buttons: UInt8) {
        var message = Data([5, buttons])
        message.append(contentsOf: be16(x))
        message.append(contentsOf: be16(y))
        send(message)
    }

    private func send(_ data: Data) {
        writeLock.withLock {
            guard !stopped, fd >= 0 else { return }
            try? UnixSocket.write(fd, data)
        }
    }

    // MARK: Protocol

    private func run() {
        // QEMU creates the socket moments after it launches.
        for _ in 0..<100 {
            if writeLock.withLock({ stopped }) { return }
            if let connected = try? UnixSocket.connect(path: path), connected >= 0 {
                fd = connected
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard fd >= 0 else { return }
        defer {
            close(fd)
            fd = -1
        }
        guard handshake() else { return }
        requestUpdate(incremental: false)
        while !writeLock.withLock({ stopped }) {
            guard let type = readBytes(1)?.first else { return }
            switch type {
            case 0:
                guard readFramebufferUpdate() else { return }
                // Ask for the next update before handing this one over, so QEMU can prepare it
                // while the frame is on screen.
                requestUpdate(incremental: true)
                if let surface { onFrame?(surface) }
            case 1: // SetColourMapEntries: unused with true colour, but skip it cleanly.
                guard let header = readBytes(5) else { return }
                let count = Int(u16(header, 3))
                guard readBytes(count * 6) != nil else { return }
            case 2: // Bell
                continue
            case 3: // ServerCutText
                guard let header = readBytes(7) else { return }
                guard readBytes(Int(u32(header, 3))) != nil else { return }
            default:
                return
            }
        }
    }

    private func handshake() -> Bool {
        guard readBytes(12) != nil else { return false }
        send(Data("RFB 003.008\n".utf8))
        guard let count = readBytes(1)?.first, count > 0, let types = readBytes(Int(count)), types.contains(1) else { return false }
        send(Data([1]))
        guard let result = readBytes(4), u32(result, 0) == 0 else { return false }
        send(Data([1])) // ClientInit, shared
        guard let serverInit = readBytes(24) else { return false }
        width = Int(u16(serverInit, 0))
        height = Int(u16(serverInit, 2))
        guard readBytes(Int(u32(serverInit, 20))) != nil else { return false }
        makeSurface()

        // 32 bpp, depth 24, little endian, true colour; red at bit 16 makes BGRX bytes.
        var format = Data([0, 0, 0, 0, 32, 24, 0, 1])
        format.append(contentsOf: be16(255) + be16(255) + be16(255))
        format.append(contentsOf: [16, 8, 0, 0, 0, 0])
        send(format)

        var encodings = Data([2, 0])
        // No rich-cursor encoding: QEMU then draws Windows' pointer into the picture itself, so
        // exactly one pointer shows and it is always where Windows thinks it is.
        let list: [Int32] = [0, -223] // Raw, DesktopSize
        encodings.append(contentsOf: be16(UInt16(list.count)))
        for encoding in list { encodings.append(contentsOf: be32(UInt32(bitPattern: encoding))) }
        send(encodings)
        return true
    }

    private func requestUpdate(incremental: Bool) {
        var message = Data([3, incremental ? 1 : 0])
        message.append(contentsOf: be16(0) + be16(0) + be16(UInt16(width)) + be16(UInt16(height)))
        send(message)
    }

    private func makeSurface() {
        guard width > 0, height > 0 else { return }
        surface = IOSurface(properties: [
            .width: width, .height: height,
            .bytesPerElement: 4, .bytesPerRow: width * 4,
            .pixelFormat: 0x4247_5241, // 'BGRA'
        ])
    }

    private func readFramebufferUpdate() -> Bool {
        guard let header = readBytes(3) else { return false }
        let rects = Int(u16(header, 1))
        for _ in 0..<rects {
            guard let rect = readBytes(12) else { return false }
            let x = Int(u16(rect, 0)), y = Int(u16(rect, 2))
            let w = Int(u16(rect, 4)), h = Int(u16(rect, 6))
            let encoding = Int32(bitPattern: u32(rect, 8))
            switch encoding {
            case 0:
                guard readRaw(x: x, y: y, w: w, h: h) else { return false }
            case -223:
                width = w
                height = h
                makeSurface()
            default:
                return false
            }
        }
        return true
    }

    /// Reads a raw rectangle straight into the surface, row by row, with no extra copies.
    private func readRaw(x: Int, y: Int, w: Int, h: Int) -> Bool {
        let rowBytes = w * 4
        guard let surface, x + w <= width, y + h <= height else {
            // Out of bounds (a resize raced the update): consume and drop it.
            var scratch = [UInt8](repeating: 0, count: rowBytes)
            for _ in 0..<h {
                guard scratch.withUnsafeMutableBytes({ UnixSocket.read(fd, into: $0.baseAddress!, count: rowBytes) }) else { return false }
            }
            return true
        }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let base = surface.baseAddress
        let stride = surface.bytesPerRow
        for line in 0..<h {
            let row = base + (y + line) * stride + x * 4
            guard UnixSocket.read(fd, into: row, count: rowBytes) else { return false }
            // The padding byte arrives as 0; make it opaque alpha for Core Animation.
            let pixels = row.bindMemory(to: UInt32.self, capacity: w)
            for index in 0..<w { pixels[index] |= 0xFF00_0000 }
        }
        return true
    }

    // MARK: Bytes

    private func readBytes(_ count: Int) -> [UInt8]? {
        if count == 0 { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        let ok = buffer.withUnsafeMutableBytes { UnixSocket.read(fd, into: $0.baseAddress!, count: count) }
        return ok ? buffer : nil
    }

    private func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
    private func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
    private func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    private func be32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
}
