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
