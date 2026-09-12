import AppKit
import SwiftUI
import InventoryCore

/// SwiftUI's Settings scene has one window. Window close, rather than view
/// disappearance or focus, owns resumption (sheets and focus changes don't).
@MainActor
final class SettingsWindowLifecycle {
    static let shared = SettingsWindowLifecycle()
    private weak var window: NSWindow?
    private var keyObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?

    func prepareToOpen() { SettingsWorkGate.shared.setPaused(true) }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        prepareToOpen()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        self.window = window
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil
        ) { _ in
            MainActor.assumeIsolated { SettingsWorkGate.shared.setPaused(true) }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                SettingsWorkGate.shared.setPaused(false)
            }
        }
    }
}

struct SettingsWindowObserver: NSViewRepresentable {
    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { SettingsWindowLifecycle.shared.attach(window) }
        }
    }
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ view: WindowView, context: Context) {
        if let window = view.window { SettingsWindowLifecycle.shared.attach(window) }
    }
}
