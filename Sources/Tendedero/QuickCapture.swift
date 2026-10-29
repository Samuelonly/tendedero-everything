import AppKit
import Carbon.HIToolbox
import ImageIO
import UniformTypeIdentifiers

/// Quick Capture: press its shortcut and the screen dims. The pointer picks
/// a window, a click shoots it; drag to shoot an area instead. One capture,
/// then the overlay goes away: the shortcut is what starts the next one.
/// Escape cancels. Nothing opens an editor: each capture flies straight onto
/// the line.
@MainActor
final class QuickCapture {
    enum Target {
        case window(CGWindowID, CGRect)
        case region(CGRect)
    }

    struct Shot {
        let id: CGWindowID
        /// The window's bounds, in the global coordinates screenshots use.
        let rect: CGRect
    }

    /// A finished capture, and the screen area it came from, in AppKit
    /// coordinates, so the line can fly it in from there.
    var onCaptured: ((URL, CGRect) -> Void)?

    private var overlays: [QuickCapturePanel] = []
    private var keyMonitor: Any?
    private var busy = false

    func start() {
        guard overlays.isEmpty else { return }
        guard Self.hasPermission() else { return }
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let panel = QuickCapturePanel(screen: screen)
            panel.shots = Self.windows(on: screen)
            panel.onShoot = { [weak self] target in self?.shoot(target) }
            panel.onExit = { [weak self] in self?.stop() }
            overlays.append(panel)
            panel.orderFrontRegardless()
        }
        overlays.first?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            self?.stop()
            return nil
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for panel in overlays { panel.orderOut(nil) }
        overlays = []
    }

    /// The windows worth shooting: real, visible windows on that screen,
    /// front to back, our own left out.
    static func windows(on screen: NSScreen) -> [Shot] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]],
              let frame = cgFrame(of: screen) else { return [] }
        let ourPID = Int(ProcessInfo.processInfo.processIdentifier)
        var shots: [Shot] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let owner = info[kCGWindowOwnerPID as String] as? Int, owner != ourPID,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any] else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect),
                  rect.width > 60, rect.height > 60,
                  frame.contains(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
            shots.append(Shot(id: CGWindowID(number), rect: rect))
        }
        return shots
    }

    /// The topmost window under a point, in global screenshot coordinates.
    static func shot(at point: CGPoint, in shots: [Shot]) -> Shot? {
        shots.first { $0.rect.contains(point) }
    }

    /// A screen's frame in global screenshot coordinates, where the origin
    /// is the top left of the main display.
    static func cgFrame(of screen: NSScreen) -> CGRect? {
        guard let main = NSScreen.screens.first else { return nil }
        let frame = screen.frame
        return CGRect(x: frame.minX, y: main.frame.maxY - frame.maxY,
                      width: frame.width, height: frame.height)
    }

    /// The other way, for AppKit.
    static func appKitRect(_ rect: CGRect) -> CGRect {
        guard let main = NSScreen.screens.first else { return rect }
        return CGRect(x: rect.minX, y: main.frame.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    // MARK: Shooting

    private func shoot(_ target: Target) {
        guard !busy else { return }
        busy = true
        // Our veil would be in the shot, so it goes away for a moment.
        setVisible(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            let image: CGImage?
            let rect: CGRect
            switch target {
            case .window(let id, let bounds):
                image = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                                [.boundsIgnoreFraming, .bestResolution])
                rect = bounds
            case .region(let bounds):
                image = CGWindowListCreateImage(bounds, .optionOnScreenOnly, kCGNullWindowID,
                                                [.bestResolution])
                rect = bounds
            }
            self.setVisible(true)
            self.busy = false
            guard let image, let url = self.save(image) else {
                // Still up, so another shot can be tried.
                NSSound.beep()
                return
            }
            // One capture is the whole errand: the line flies it in, and the
            // screen goes back to normal without a second click.
            self.stop()
            self.onCaptured?(url, Self.appKitRect(rect))
        }
    }

    private func setVisible(_ on: Bool) {
        for panel in overlays {
            if on { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
    }

    private func save(_ image: CGImage) -> URL? {
        let folder = OwnFolder.prepare()
        let stamp = Self.stamp()
        var url = folder.appendingPathComponent("Capture \(stamp).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Capture \(stamp) \(n).png")
            n += 1
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        log.notice("Quick Capture saved \(url.lastPathComponent, privacy: .public)")
        return url
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }

    // MARK: Screen recording permission

    /// Shooting a window or an area needs the Screen Recording permission.
    /// Asked once, with a way to the setting; macOS wants the app opened
    /// again after it is granted.
    private static func hasPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = L("Quick Capture needs Screen Recording")
        alert.informativeText = L("Turn on Screen Recording for Tendedero Everything in System Settings, then open Tendedero Everything again.")
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Later"))
        if let icon = NSImage(named: "Tendedero") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}

/// One screen of the overlay: the veil, the highlighted window and the hint.
final class QuickCapturePanel: NSPanel {
    /// NSPanel already exposes `screen`, so this one is named separately.
    let hostScreen: NSScreen
    private let canvas: QuickCaptureView

    var shots: [QuickCapture.Shot] {
        get { canvas.shots }
        set { canvas.shots = newValue }
    }
    var onShoot: ((QuickCapture.Target) -> Void)? {
        get { canvas.onShoot }
        set { canvas.onShoot = newValue }
    }
    var onExit: (() -> Void)? {
        get { canvas.onExit }
        set { canvas.onExit = newValue }
    }

    init(screen: NSScreen) {
        self.hostScreen = screen
        canvas = QuickCaptureView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above everything, the line included.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        canvas.screen = screen
        contentView = canvas
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class QuickCaptureView: NSView {
    var screen: NSScreen?
    var shots: [QuickCapture.Shot] = []
    var onShoot: ((QuickCapture.Target) -> Void)?
    var onExit: (() -> Void)?

    private var hovered: QuickCapture.Shot?
    private var dragStart: CGPoint?
    private var dragRect: CGRect?

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }

    private func updateHover(_ event: NSEvent) {
        guard dragStart == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        hovered = QuickCapture.shot(at: global(point), in: shots)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragRect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        dragRect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragRect = nil
        }
        if let rect = dragRect, rect.width > 8, rect.height > 8 {
            onShoot?(.region(globalRect(rect)))
            return
        }
        if let hovered {
            onShoot?(.window(hovered.id, hovered.rect))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onExit?()
    }

    // MARK: Coordinates

    /// A point in the view to the global coordinates screenshots use.
    private func global(_ point: CGPoint) -> CGPoint {
        guard let window, let main = NSScreen.screens.first else { return point }
        let onScreen = window.convertPoint(toScreen: convert(point, to: nil))
        return CGPoint(x: onScreen.x, y: main.frame.maxY - onScreen.y)
    }

    private func globalRect(_ rect: CGRect) -> CGRect {
        guard let window, let main = NSScreen.screens.first else { return rect }
        let onScreen = window.convertToScreen(convert(rect, to: nil))
        return CGRect(x: onScreen.minX, y: main.frame.maxY - onScreen.maxY,
                      width: onScreen.width, height: onScreen.height)
    }

    /// A window's bounds, in the view's own coordinates.
    private func viewRect(_ rect: CGRect) -> CGRect {
        guard let window, let main = NSScreen.screens.first else { return rect }
        let onScreen = CGRect(x: rect.minX, y: main.frame.maxY - rect.maxY,
                              width: rect.width, height: rect.height)
        let origin = window.convertPoint(fromScreen: onScreen.origin)
        return CGRect(x: origin.x, y: origin.y, width: onScreen.width, height: onScreen.height)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.black.withAlphaComponent(0.32).cgColor)
        context.fill(bounds)

        let target = dragRect ?? hovered.map { viewRect($0.rect) }
        if let target {
            // Cut the veil away over the shot, so what will be captured is
            // seen as it is.
            context.setBlendMode(.clear)
            context.fill(target.insetBy(dx: 1, dy: 1))
            context.setBlendMode(.normal)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(2)
            context.stroke(target.insetBy(dx: 1, dy: 1))

            let label = "\(Int(target.width)) × \(Int(target.height))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            let box = CGRect(x: target.minX + 6, y: target.maxY - size.height - 10,
                             width: size.width + 8, height: size.height + 4)
            if box.maxX < bounds.maxX, box.maxY < bounds.maxY {
                NSColor.black.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
                label.draw(at: CGPoint(x: box.minX + 4, y: box.minY + 2), withAttributes: attributes)
            }
        }

        let hint = L("Click a window, or drag for an area. Escape quits.")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = hint.size(withAttributes: attributes)
        let box = CGRect(x: bounds.midX - size.width / 2 - 10, y: bounds.maxY - 44,
                         width: size.width + 20, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        hint.draw(at: CGPoint(x: box.minX + 10, y: box.minY + 4), withAttributes: attributes)
    }
}
