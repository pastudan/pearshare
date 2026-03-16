import ScreenCaptureKit
import AppKit

/// Checks and requests Screen Recording permission (TCC).
/// ScreenCaptureKit requires the user to grant this in
/// System Settings → Privacy & Security → Screen & System Audio Recording.
enum ScreenCapturePermission {

    enum Status {
        case granted
        case denied
        case notDetermined
    }

    /// Check current permission status without triggering a prompt.
    static func currentStatus() async -> Status {
        do {
            // Calling excludingDesktopWindows triggers the TCC check.
            // If permission is denied it throws; if not determined it prompts.
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return .granted
        } catch let error as SCStreamError {
            if error.code == .userDeclined {
                return .denied
            }
            return .notDetermined
        } catch {
            return .denied
        }
    }

    /// Request permission, then call completion on the main actor with the result.
    /// If already granted, calls completion immediately.
    /// If denied, shows an alert with a button to open System Settings.
    @MainActor
    static func requestIfNeeded() async -> Bool {
        let status = await currentStatus()
        switch status {
        case .granted:
            return true
        case .notDetermined:
            // Trigger the system prompt by trying again
            let retry = await currentStatus()
            return retry == .granted
        case .denied:
            showDeniedAlert()
            return false
        }
    }

    @MainActor
    private static func showDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "PearShare needs Screen Recording permission to share your screen.\n\nOpen System Settings → Privacy & Security → Screen & System Audio Recording and enable PearShare, then relaunch."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}
