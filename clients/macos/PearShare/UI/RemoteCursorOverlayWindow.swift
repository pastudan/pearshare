import AppKit

// MARK: - RemoteCursorOverlayWindow
//
// A transparent, borderless, non-activating NSWindow that floats above all other windows
// and draws a colored ring around the remote peer's cursor position.
//
// This window is deliberately excluded from ScreenCaptureKit's capture filter so it
// never appears in the H.264 stream — the host sees the overlay but the viewer's
// recorded frames stay clean.
//
// Window title is set to kRemoteCursorWindowTitle so ScreenCaptureManager can find
// and exclude it by title when building the SCContentFilter.

let kRemoteCursorWindowTitle = "PearShare-RemoteCursor"

final class RemoteCursorOverlayWindow: NSWindow {

    // The NSView that does the actual drawing
    private let cursorView = RemoteCursorView()

    /// The peer's display name, shown as a small label beneath the ring.
    var peerDisplayName: String = "" {
        didSet { cursorView.peerDisplayName = peerDisplayName }
    }

    // MARK: - Init

    init() {
        // Small window — just big enough for the ring + label
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 48, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        title = kRemoteCursorWindowTitle
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true           // never steal clicks from actual UI
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        contentView = cursorView
    }

    // MARK: - Move to screen position

    /// Move the overlay so its hotspot (top-left of the arrow) sits at `screenPoint`.
    /// `screenPoint` is in AppKit screen coordinates (origin bottom-left of main screen).
    func moveTo(screenPoint: NSPoint) {
        // Offset so the pointer tip is at the hotspot
        let origin = NSPoint(
            x: screenPoint.x - RemoteCursorView.hotspotX,
            y: screenPoint.y - (frame.height - RemoteCursorView.hotspotY)
        )
        setFrameOrigin(origin)
    }

    // MARK: - Show / Hide

    func show() {
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}

// MARK: - RemoteCursorView

/// Draws an arrow cursor with a colored ring halo — visually distinct from the local cursor.
private final class RemoteCursorView: NSView {

    // Hotspot offsets within the view frame (where the arrow tip is)
    static let hotspotX: CGFloat = 4
    static let hotspotY: CGFloat = 4

    // Accent color for the ring (teal, visually distinct from system blue/green)
    private static let ringColor = NSColor(red: 0.0, green: 0.78, blue: 0.75, alpha: 1.0)
    private static let ringWidth: CGFloat = 2.5
    private static let ringRadius: CGFloat = 11

    var peerDisplayName: String = "" {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let tip = CGPoint(x: Self.hotspotX, y: bounds.height - Self.hotspotY - 20)

        // Draw the colored ring centered near the arrow tip
        let ringCenter = CGPoint(x: tip.x + 6, y: tip.y + 6)
        ctx.setStrokeColor(Self.ringColor.cgColor)
        ctx.setLineWidth(Self.ringWidth)
        ctx.addEllipse(in: CGRect(
            x: ringCenter.x - Self.ringRadius,
            y: ringCenter.y - Self.ringRadius,
            width: Self.ringRadius * 2,
            height: Self.ringRadius * 2
        ))
        ctx.strokePath()

        // Draw a standard arrow cursor shape in white with a dark outline
        drawArrow(at: tip, in: ctx)

        // Peer name label beneath the arrow
        if !peerDisplayName.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let str = NSAttributedString(string: peerDisplayName, attributes: attrs)
            let labelOrigin = NSPoint(x: tip.x + 14, y: tip.y - 14)
            str.draw(at: labelOrigin)
        }
    }

    // Draws a simple arrow cursor polygon
    private func drawArrow(at tip: CGPoint, in ctx: CGContext) {
        let arrowPath = CGMutablePath()
        arrowPath.move(to: tip)
        arrowPath.addLine(to: CGPoint(x: tip.x,      y: tip.y - 16))
        arrowPath.addLine(to: CGPoint(x: tip.x + 4,  y: tip.y - 12))
        arrowPath.addLine(to: CGPoint(x: tip.x + 9,  y: tip.y - 20))
        arrowPath.addLine(to: CGPoint(x: tip.x + 11, y: tip.y - 19))
        arrowPath.addLine(to: CGPoint(x: tip.x + 6,  y: tip.y - 11))
        arrowPath.addLine(to: CGPoint(x: tip.x + 10, y: tip.y - 11))
        arrowPath.closeSubpath()

        // Dark outline
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(arrowPath)
        ctx.strokePath()

        // White fill
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(arrowPath)
        ctx.fillPath()
    }
}
