import AppKit

// MARK: - Window title constants
//
// Both overlay windows must be excluded from ScreenCaptureKit so they never appear
// in the H.264 stream. ScreenCaptureManager looks up SCWindows by these titles.

let kViewerCursorWindowTitle = "PearShare-ViewerCursor"
let kHostGhostCursorWindowTitle = "PearShare-HostGhostCursor"

// Keep the old constant so existing MediaSession.overlayWindowTitle references compile.
let kRemoteCursorWindowTitle = kViewerCursorWindowTitle

// MARK: - RemoteCursorOverlayWindow
//
// A transparent, borderless, non-activating NSWindow at .floating level that draws
// a simple colored arrow cursor for a remote (or "ghost") participant.
//
// No ring, no halo — just a pastel arrow whose color identifies the participant:
//   pastelRed  = host (shown when viewer has control and host cursor is "ghosted")
//   pastelBlue = viewer (shown when host has control and viewer cursor is visible)

final class RemoteCursorOverlayWindow: NSWindow {

    private let cursorView: CursorArrowView

    // MARK: - Factory methods

    static func pastelRed(peerName: String = "") -> RemoteCursorOverlayWindow {
        let color = NSColor(red: 1.0, green: 0.55, blue: 0.55, alpha: 1.0)
        return RemoteCursorOverlayWindow(color: color, peerName: peerName,
                                         title: kHostGhostCursorWindowTitle)
    }

    static func pastelBlue(peerName: String = "") -> RemoteCursorOverlayWindow {
        let color = NSColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 1.0)
        return RemoteCursorOverlayWindow(color: color, peerName: peerName,
                                         title: kViewerCursorWindowTitle)
    }

    // MARK: - Init

    init(color: NSColor, peerName: String, title windowTitle: String) {
        cursorView = CursorArrowView(color: color, peerName: peerName)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 56, height: 64),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.title = windowTitle
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = cursorView
    }

    // MARK: - Positioning

    /// Move so the arrow tip sits at `screenPoint` (AppKit coords, origin bottom-left).
    func moveTo(screenPoint: NSPoint) {
        let origin = NSPoint(
            x: screenPoint.x - CursorArrowView.tipX,
            y: screenPoint.y - (frame.height - CursorArrowView.tipY)
        )
        setFrameOrigin(origin)
    }

    // MARK: - Visibility

    func show() { orderFrontRegardless() }
    func hide() { orderOut(nil) }

    var peerDisplayName: String {
        get { cursorView.peerName }
        set { cursorView.peerName = newValue }
    }
}

// MARK: - CursorArrowView

private final class CursorArrowView: NSView {

    /// Where the tip of the arrow is within the view frame (AppKit coords, origin bottom-left).
    static let tipX: CGFloat = 4
    static let tipY: CGFloat = 4  // distance from top of view

    private let arrowColor: NSColor
    var peerName: String { didSet { needsDisplay = true } }

    init(color: NSColor, peerName: String) {
        self.arrowColor = color
        self.peerName = peerName
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // In AppKit coords (origin bottom-left of view):
        let tip = CGPoint(x: Self.tipX, y: bounds.height - Self.tipY - 20)

        drawArrow(at: tip, color: arrowColor, in: ctx)

        if !peerName.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: arrowColor,
            ]
            NSAttributedString(string: peerName, attributes: attrs)
                .draw(at: NSPoint(x: tip.x + 14, y: tip.y - 14))
        }
    }

    private func drawArrow(at tip: CGPoint, color: NSColor, in ctx: CGContext) {
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x,      y: tip.y - 16))
        path.addLine(to: CGPoint(x: tip.x + 4,  y: tip.y - 12))
        path.addLine(to: CGPoint(x: tip.x + 9,  y: tip.y - 20))
        path.addLine(to: CGPoint(x: tip.x + 11, y: tip.y - 19))
        path.addLine(to: CGPoint(x: tip.x + 6,  y: tip.y - 11))
        path.addLine(to: CGPoint(x: tip.x + 10, y: tip.y - 11))
        path.closeSubpath()

        // Slightly darkened outline for legibility on any background
        ctx.setStrokeColor(color.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(path)
        ctx.strokePath()

        ctx.setFillColor(color.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }
}
