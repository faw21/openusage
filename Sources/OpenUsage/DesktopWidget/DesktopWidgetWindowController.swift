import AppKit
import SwiftUI

/// Borderless panel that can still become key, so text fields / links inside the widget work without
/// activating the app.
final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosts the big usage/balance dashboard in a movable desktop panel — the desktop-widget surface the
/// user asked for, distinct from the menu-bar popover. Non-activating so it never steals focus, joins
/// all Spaces, remembers its position, and can be pinned on top.
@MainActor
final class DesktopWidgetWindowController {
    private let panel: DesktopPanel

    private var keepOnTop: Bool {
        didSet {
            UserDefaults.standard.set(keepOnTop, forKey: Self.keepOnTopKey)
            applyLevel()
        }
    }

    private static let frameKey = "desktopWidget.frame"
    private static let keepOnTopKey = "desktopWidget.keepOnTop"

    init(container: AppContainer) {
        self.keepOnTop = UserDefaults.standard.bool(forKey: Self.keepOnTopKey)

        let panel = DesktopPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 660),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.panel = panel

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none

        let root = DesktopDashboardView(
            onClose: { [weak self] in self?.hide() },
            onTogglePin: { [weak self] in self?.keepOnTop.toggle() }
        )
        .environment(container)
        .environment(container.dataStore)
        .environment(container.balances)

        let hosting = NSHostingController(rootView: AnyView(root))
        hosting.view.frame = NSRect(x: 0, y: 0, width: 440, height: 660)
        panel.contentViewController = hosting

        applyLevel()
        restoreFrameOrPlaceTopRight()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        saveFrame()
        panel.orderOut(nil)
    }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    var isVisible: Bool { panel.isVisible }

    private func applyLevel() {
        // Floating keeps it above normal windows; otherwise it sits at normal level like a desk widget.
        panel.level = keepOnTop ? .floating : .normal
    }

    private func restoreFrameOrPlaceTopRight() {
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let frame = NSRectFromString(saved)
            if frame.width > 100, frame.height > 100, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
                panel.setFrame(frame, display: false)
                return
            }
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.maxX - panel.frame.width - 32,
                y: visible.maxY - panel.frame.height - 32
            )
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
    }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }
}
