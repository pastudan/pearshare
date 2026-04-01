import AppKit
import SwiftUI

let kScreenShareBorderWindowTitle = "PearShare-ScreenShareBorder"

// MARK: - ScreenShareBorderWindow

/// Full-screen transparent overlay that draws an animated glowing border around the host's
/// display during an active screen-share. Excluded from the SCKit capture stream via its
/// window title so the viewer never sees it. Click-through and harmless.
final class ScreenShareBorderWindow: NSWindow {

    static func make(screen: NSScreen) -> ScreenShareBorderWindow {
        let w = ScreenShareBorderWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.title = kScreenShareBorderWindowTitle
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = NSHostingView(rootView: ScreenShareBorderView())
        view.wantsLayer = true
        // Set contentView first, then clear the layer background — AppKit can reset the
        // layer when the view becomes a contentView, so the order matters here.
        w.contentView = view
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return w
    }
}

// MARK: - ScreenShareBorderView

private struct ScreenShareBorderView: View {
    var body: some View {
        Rectangle()
            .strokeBorder(Color.pearGreen.opacity(0.8), lineWidth: 3)
            .background(Color.clear)
            .ignoresSafeArea()
    }
}
