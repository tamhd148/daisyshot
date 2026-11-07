import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

/// TCC permission status, requests and System Settings deep links.
@MainActor
enum Permissions {
    enum Pane: String {
        case screenRecording = "com.apple.preference.security?Privacy_ScreenCapture"
        case accessibility = "com.apple.preference.security?Privacy_Accessibility"
        case microphone = "com.apple.preference.security?Privacy_Microphone"
        case camera = "com.apple.preference.security?Privacy_Camera"
        case loginItems = "com.apple.LoginItems-Settings.extension"
    }

    static func open(_ pane: Pane) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:" + pane.rawValue)!)
    }

    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Adds Daisyshot to the Screen Recording list (macOS shows its own prompt the first time).
    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func status(_ media: AVMediaType) -> AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: media) }

    /// Asks for camera/microphone if undecided; otherwise sends the user to System Settings.
    static func request(_ media: AVMediaType) {
        if status(media) == .notDetermined {
            AVCaptureDevice.requestAccess(for: media) { _ in }
        } else {
            open(media == .audio ? .microphone : .camera)
        }
    }

    /// True when capturing is allowed; otherwise explains how to grant access (once per launch it also triggers the
    /// system prompt that adds Daisyshot to the list) and returns false.
    @discardableResult
    static func ensureScreenRecording() -> Bool {
        if screenRecording { return true }
        if !askedThisLaunch {
            askedThisLaunch = true
            requestScreenRecording()
            if screenRecording { return true }
        }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Daisyshot needs permission to record your screen"
        a.informativeText = """
            Turn on Daisyshot in System Settings › Privacy & Security › Screen & System Audio Recording. \
            macOS applies the change after Daisyshot restarts.
            """
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Relaunch Daisyshot")
        a.addButton(withTitle: "Cancel")
        a.localize()
        switch a.runModal() {
        case .alertFirstButtonReturn: open(.screenRecording)
        case .alertSecondButtonReturn: relaunch()
        default: break
        }
        return false
    }

    private static var askedThisLaunch = false

    /// Quits and starts a fresh copy (permissions like Screen Recording only apply to new processes).
    static func relaunch() {
        let isApp = Bundle.main.bundleURL.pathExtension == "app"
        let path = isApp ? Bundle.main.bundlePath : (Bundle.main.executablePath ?? "")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit so `open` launches a new instance instead of re-activating us.
        let start = isApp ? "/usr/bin/open \"$0\"" : "\"$0\" >/dev/null 2>&1 &"
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; \(start)", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
