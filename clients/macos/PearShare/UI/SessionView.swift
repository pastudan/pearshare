import SwiftUI
import AppKit

/// Full-window view for the viewer role. Shows the decoded remote video
/// with a brand-colored border that follows the window's corner radius.
struct SessionView: View {
    let renderer: VideoRenderer

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoDisplayView(renderer: renderer)
                .ignoresSafeArea()
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.pearGreen, lineWidth: 3)
        )
    }
}

// MARK: - ViewerWindowContentView

/// Transparent wrapper that is the viewer window's contentView.
/// Its only job is to provide resize cursor rects — the real rendering is done
/// by the NSHostingView subview. Without this, a .borderless window never
/// shows edge/corner resize cursors because AppKit only does that for titled windows.
final class ViewerWindowContentView: NSView {

    private static let edgeSize: CGFloat = 12

    override func resetCursorRects() {
        let e = Self.edgeSize
        let w = bounds.width
        let h = bounds.height

        // Corners — diagonal cursors (NW↔SE and NE↔SW)
        addCursorRect(NSRect(x: 0,     y: h - e, width: e,     height: e    ), cursor: .windowResizeNWSE) // top-left
        addCursorRect(NSRect(x: w - e, y: h - e, width: e,     height: e    ), cursor: .windowResizeNESW) // top-right
        addCursorRect(NSRect(x: 0,     y: 0,     width: e,     height: e    ), cursor: .windowResizeNESW) // bottom-left
        addCursorRect(NSRect(x: w - e, y: 0,     width: e,     height: e    ), cursor: .windowResizeNWSE) // bottom-right

        // Edges
        addCursorRect(NSRect(x: e,     y: h - e, width: w-2*e, height: e    ), cursor: .resizeUpDown)     // top
        addCursorRect(NSRect(x: e,     y: 0,     width: w-2*e, height: e    ), cursor: .resizeUpDown)     // bottom
        addCursorRect(NSRect(x: 0,     y: e,     width: e,     height: h-2*e), cursor: .resizeLeftRight)  // left
        addCursorRect(NSRect(x: w - e, y: e,     width: e,     height: h-2*e), cursor: .resizeLeftRight)  // right
    }
}

private extension NSCursor {
    /// NW↔SE diagonal resize cursor (top-left and bottom-right corners).
    static var windowResizeNWSE: NSCursor { privateCursor("_windowResizeNorthWestSouthEastCursor") }
    /// NE↔SW diagonal resize cursor (top-right and bottom-left corners).
    static var windowResizeNESW: NSCursor { privateCursor("_windowResizeNorthEastSouthWestCursor") }

    private static func privateCursor(_ selectorName: String) -> NSCursor {
        let sel = Selector((selectorName))
        if NSCursor.responds(to: sel),
           let r = NSCursor.perform(sel),
           let cursor = r.takeUnretainedValue() as? NSCursor { return cursor }
        return .crosshair
    }
}
