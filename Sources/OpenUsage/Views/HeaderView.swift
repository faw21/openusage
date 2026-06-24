import AppKit
import SwiftUI

/// The footer's lone glass control: a "More" pull-down button (Customize / Settings / Check for Updates /
/// About / Quit). On the dashboard it shows; the Customize and Settings screens carry their own
/// top-leading back button (`DashboardView.navBar`) to return home — the macOS-native place for it — so
/// the footer control simply drops away there rather than morphing into a trailing "Done".
///
/// It's a SwiftUI `Menu` presenting a custom round Liquid Glass button: `.menuStyle(.button)` makes the
/// menu present from a button, `.buttonStyle(.plain)` strips the system button chrome so our
/// `interactiveGlass(in:)` is the only surface, drawing the interactive glass — the system
/// `.buttonStyle(.glass)` renders flat on a `Menu`, which is why this draws the glass itself. The menu
/// renders in its own `NSMenu`-backed window, which `StatusItemController.shouldKeepPanelOpen` already
/// keeps the popover open for (same rule that covers the Settings pickers' popups). The ⌘, / ⏎ key
/// equivalents on the menu items render as shortcut labels and fire while the menu is open; the
/// always-on `PopoverKeyReader` monitor handles those keys the rest of the time (and from screens with
/// no footer, like Settings), so no separate SwiftUI shortcut button is needed.
struct HeaderView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(UpdaterController.self) private var updater
    /// The screen this footer belongs to. Footers are per-page now (they slide with their page), so the
    /// "More" button keys off the page it's drawn in — not the global current screen, which flips at the
    /// start of a slide and would otherwise pop the button off the outgoing page mid-transition.
    let screen: PopoverScreen

    var body: some View {
        leadingControl
            .glassButtonGroup(spacing: 4)
    }

    /// On the dashboard this is the "More" pull-down: an ellipsis on a custom interactive Liquid Glass
    /// round button. `.buttonStyle(.plain)` strips the system button chrome so `interactiveGlass(in:)`
    /// is the only surface (the system glass button style renders flat on a `Menu`);
    /// `.menuIndicator(.hidden)` drops the chevron — the ellipsis already reads as "more". The `Label`
    /// title carries the accessible name for VoiceOver.
    @ViewBuilder
    private var leadingControl: some View {
        if screen == .dashboard {
            Menu {
                moreMenuItems
            } label: {
                Label("More", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .interactiveGlass(in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }

    /// The "More" menu items, mirroring their in-popover entry points. `autoenablesItems` has no SwiftUI
    /// equivalent, so the Check for Updates item disables itself when Sparkle can't currently check — e.g.
    /// dev builds with no feed, or while a check is already in flight. Settings (⌘,) and Customize (⏎)
    /// carry their key equivalents so the menu shows the shortcut labels; the always-on `PopoverKeyReader`
    /// monitor actually handles those keys while the menu is closed (and consumes them, so there's no
    /// second registration to fight), and the menu item only fires while the menu is open — so the two
    /// never double-toggle.
    @ViewBuilder
    private var moreMenuItems: some View {
        Button { toggle(.settings) } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)
        Button { toggle(.customize) } label: {
            Label("Customize", systemImage: "slider.horizontal.3")
        }
        .keyboardShortcut(.return, modifiers: [])
        Button { updater.checkForUpdates() } label: {
            Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!updater.canCheckForUpdates)

        Divider()

        Button { AboutPanel.present() } label: {
            Label("About OpenUsage", systemImage: "info.circle")
        }
        Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
            Label("Quit OpenUsage", systemImage: "power")
        }
        .keyboardShortcut("q") // ⌘Q — unowned elsewhere, so safe to register on the item.
    }

    private func toggle(_ screen: PopoverScreen) {
        withAnimation(Motion.modeSwitch) {
            layout.screen = layout.screen == screen ? .dashboard : screen
        }
    }
}
