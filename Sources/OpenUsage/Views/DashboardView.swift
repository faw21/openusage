import SwiftUI
import AppKit

/// The popover content: the provider/metric list (or the Customize / Settings screen) as a scroll
/// view between fixed chrome — a top back/title bar on Customize/Settings, and a single bottom footer
/// (app identity / Customize pin summary + the glass Customize/Settings buttons) with the resize
/// handle folded into it.
///
/// The chrome is fixed: it's keyed off `layout.screen` and applied uniformly in `screenView`, so on a
/// screen switch only the content slides while the footer and top bar stay put. Each screen's scroll
/// content underlaps the footer with the native soft scroll-edge fade (`softBottomScrollEdge` →
/// `.scrollEdgeEffectStyle(.soft)`, macOS 26+) — Apple's blurred boundary, not a custom gradient or a
/// material bar. On macOS 15 the footer/top bar still pin via `safeAreaInset`, just without the blur
/// (content scrolls flush). The popover height is clamped to a share of the hosting screen so it never
/// overflows when many widgets are added.
struct DashboardView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @State private var listContentHeight: CGFloat = 300
    @State private var customizeContentHeight: CGFloat = 220
    @State private var settingsContentHeight: CGFloat = 480
    @State private var usableHeight: CGFloat = ScreenHeightReader.smallestUsableHeight()
    @State private var didInitialRefresh = false
    @State private var hasMeasuredCustomizeContent = false
    @State private var hasMeasuredSettingsContent = false
    @State private var reorderLift: ReorderLift?
    @State private var showingResetCustomizationConfirmation = false
    /// True while the user is dragging the resize grip, so the first drag event begins the resize once.
    @State private var resizingPanel = false
    /// Horizontal screen-switch slide: 0 shows the outgoing screen, 1 the incoming one. Drives both the
    /// page offset and the interpolated popover height, so the slide and the resize share one spring.
    @State private var slideProgress: CGFloat = 1
    /// The `layout.screenSlideID` whose slide has begun animating. Until it catches up to the store's
    /// id, a freshly-started transition pins to the outgoing screen so the first frame never flashes
    /// the destination.
    @State private var animatedSlideID = 0
    /// Reset to the top whenever the popover closes, so it never reopens mid-scroll.
    @State private var dashboardScrollPosition = ScrollPosition(edge: .top)
    /// Row rhythm and the Customize height seed track the global density setting live.
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    private static let outerPadding: CGFloat = 14
    /// Breathing room between the bottom of the scrolling content and the pinned footer. Kept small
    /// because the native scroll edge effect — not whitespace — provides the visual separation.
    private static let contentBottomGap: CGFloat = 12
    /// Footer content starts at the same standard padding as the provider containers.
    private static let footerHorizontalPadding: CGFloat = outerPadding
    private static let reorderSpace = "popoverReorderSpace"
    /// One width across both densities — switching density shouldn't move the popover's left edge.
    private static let popoverWidth: CGFloat = 320
    /// Fixed height of the Customize / Settings back nav bar. A constant (not measured) so the popover
    /// height math stays deterministic — the bar pins itself to exactly this height.
    private static let topBarHeight: CGFloat = 44
    /// Combined height of the bottom chrome — the footer row (identity / pin summary + glass buttons)
    /// plus the resize handle folded directly beneath it into one pinned unit. A constant (not
    /// measured), like `topBarHeight`, so the popover height math stays deterministic; tuned to the
    /// rendered footer-row + handle height.
    private static let footerHeight: CGFloat = 68

    /// Never grow taller than 85% of the *hosting* screen's usable height; scroll beyond that. All
    /// three screens (dashboard, Customize, Settings) share this one cap so they feel consistent —
    /// each fits its content exactly until it would exceed the cap, then scrolls.
    private var maxHeight: CGFloat {
        floor(usableHeight * 0.85)
    }

    /// The pinned chrome that lives outside the scroll region, so the scroll area's cap is the popover
    /// cap minus that fixed chrome. The footer is on every screen; Customize and Settings add the
    /// pinned back nav bar on top, so their chrome is taller by exactly that bar.
    private func chromeHeight(for screen: PopoverScreen) -> CGFloat {
        Self.footerHeight + (screen == .dashboard ? 0 : Self.topBarHeight)
    }

    private func maxScrollHeight(for screen: PopoverScreen) -> CGFloat {
        max(120, maxHeight - chromeHeight(for: screen))
    }

    /// The scroll area fits its content exactly until it would exceed the cap, then it scrolls.
    private var dashboardScrollHeight: CGFloat {
        min(listContentHeight, maxScrollHeight(for: .dashboard))
    }

    private var customizeScrollHeight: CGFloat {
        let contentHeight = hasMeasuredCustomizeContent ? customizeContentHeight : estimatedCustomizeContentHeight
        return min(contentHeight, maxScrollHeight(for: .customize))
    }

    /// Settings fits its content exactly, like the dashboard and Customize, up to the global cap.
    /// Before the first measurement an estimate seeds the height so the flip lands close and the
    /// real measurement only fine-tunes it.
    private var settingsScrollHeight: CGFloat {
        let contentHeight = hasMeasuredSettingsContent ? settingsContentHeight : estimatedSettingsContentHeight
        return min(contentHeight, maxScrollHeight(for: .settings))
    }

    private func scrollHeight(for screen: PopoverScreen) -> CGFloat {
        switch screen {
        case .dashboard: dashboardScrollHeight
        case .customize: customizeScrollHeight
        case .settings: settingsScrollHeight
        }
    }

    /// A screen's full popover height: its scroll content plus that screen's pinned chrome.
    private func screenHeight(for screen: PopoverScreen) -> CGFloat {
        scrollHeight(for: screen) + chromeHeight(for: screen)
    }

    private var popoverHeight: CGFloat {
        screenHeight(for: layout.screen)
    }

    /// The popover height to apply while a screen-switch slide is playing: it interpolates from the
    /// outgoing screen's height to the incoming one's on `slideProgress` — the *same* value that drives
    /// the horizontal offset — so the box resizing and the screens sliding read as one coordinated
    /// motion instead of two animations on separate clocks. At rest it's simply the current screen's
    /// height; before the slide actually starts it sits at the outgoing screen's height to match the
    /// pinned offset, so nothing jumps ahead of the slide.
    private var animatedPopoverHeight: CGFloat {
        guard isSliding else { return popoverHeight }
        let fromHeight = screenHeight(for: layout.screenSlideFrom)
        guard animatedSlideID == layout.screenSlideID else { return fromHeight }
        return fromHeight + slideProgress * (popoverHeight - fromHeight)
    }

    /// Cold-start estimate for Customize content. Without this, the first click into Customize starts from an
    /// arbitrary seed height, then jumps when the real `ScrollView` measurement arrives. The constants mirror
    /// `CustomizeView`'s row/block spacing closely enough to choose the same clamped height before first layout.
    private var estimatedCustomizeContentHeight: CGFloat {
        let groups = layout.customizeGroups
        guard !groups.isEmpty else { return 104 }
        let providerHeaderHeight: CGFloat = density == .compact ? 26 : 30
        let providerHeaderToCardSpacing: CGFloat = density.headerToCardSpacing + 2
        let metricRowHeight = density.estimatedMetricRowHeight
        let dividerRowHeight = density.customizeDividerRowHeight
        let providerSpacing = density.sectionSpacing
        let verticalPadding: CGFloat = 24
        // Each provider card carries one "Shown on expand" divider row in addition to its metric rows.
        let blocks = groups.reduce(CGFloat.zero) { total, group in
            total
                + providerHeaderHeight
                + providerHeaderToCardSpacing
                + CGFloat(group.metrics.count) * metricRowHeight
                + dividerRowHeight
        }
        return verticalPadding + blocks + CGFloat(max(0, groups.count - 1)) * providerSpacing
    }

    /// Cold-start estimate for Settings content, same role as the Customize estimate above. The
    /// constants mirror `SettingsScreen`: five sections (a caption header over a card) holding
    /// twelve fixed control rows (Startup 2, Appearance 5, Usage Display 2, Advanced 3) plus one
    /// row per registered provider.
    private var estimatedSettingsContentHeight: CGFloat {
        let sectionCount: CGFloat = 5
        let sectionHeaderHeight: CGFloat = 16
        let fixedRowCount: CGFloat = 12
        let rowCount = fixedRowCount + CGFloat(container.registry.providers.count)
        let verticalPadding: CGFloat = 24
        return verticalPadding
            + sectionCount * (sectionHeaderHeight + density.headerToCardSpacing)
            + rowCount * density.estimatedMetricRowHeight
            + (sectionCount - 1) * density.sectionSpacing
    }

    var body: some View {
        modeBody
            .frame(width: Self.popoverWidth)
            // Fill the panel (the host window is the user-set, screen-clamped size); the scroll views
            // inside handle overflow. The panel no longer sizes to content, so switching screens never
            // resizes the window — the slide plays over a static frame, with no resize stutter.
            .frame(maxHeight: .infinity, alignment: .top)
            // Paint the opaque tray behind all content (and the footer) so the whole popover reads as
            // one solid panel — the data region never shows the desktop through it. Outermost so the
            // footer, header, and scroll content all sit on it; separation from the footer comes from
            // the native soft scroll-edge fade (not a distinct bar). The resize handle is folded into
            // the footer (see `footerBar`), so there's no separate root-level dragger inset anymore.
            .background(PopoverSurface())
            .overlay(alignment: .topLeading) {
                if let reorderLift {
                    ReorderLiftPreview(lift: reorderLift)
                }
            }
            .coordinateSpace(name: Self.reorderSpace)
            .background(ScreenHeightReader(usableHeight: $usableHeight))
            .background(
                // Esc backs out of Customize / Settings first; only from the dashboard does it close
                // the popover. Return opens Customize from the dashboard (the same affordance the
                // footer's Customize button carries) and returns to the
                // dashboard from Customize or Settings — matching Esc and the prominent "Done" control,
                // never jumping Settings → Customize. Always consumed, so a bare Return can't fall
                // through and dismiss the popover.
                PopoverKeyReader(
                    onEscape: {
                        guard layout.screen != .dashboard else { return false }
                        withAnimation(Motion.modeSwitch) { layout.screen = .dashboard }
                        return true
                    },
                    onReturn: {
                        let target: PopoverScreen = layout.screen == .dashboard ? .customize : .dashboard
                        withAnimation(Motion.modeSwitch) { layout.screen = target }
                        return true
                    },
                    // ⌘, toggles Settings, on this always-on monitor so it fires from every screen —
                    // including Settings, which has no footer. Handling it here (and consuming it) is
                    // also what lets the More menu's Settings item carry ⌘, purely as a label without a
                    // second SwiftUI registration fighting it. (#717 made footers per-page and dropped
                    // the Settings footer, so the old footer-hosted shortcut button no longer fired
                    // there — ⌘, fell through to AppKit and defocused the panel.)
                    onSettings: {
                        withAnimation(Motion.modeSwitch) {
                            layout.screen = layout.screen == .settings ? .dashboard : .settings
                        }
                        return true
                    }
                )
            )
            .background(
                PopoverVisibilityReader { visible in
                    if !visible { resetTransientState() }
                }
            )
            // A screen switch can tear the list down mid-drag, in which case the gesture's
            // `onEnded` never fires — clear the lift here or its overlay survives onto the new
            // screen.
            .onChange(of: layout.screen) {
                reorderLift = nil
                layout.cancelDrag()
            }
            // Each screen switch: pin to the outgoing screen for one render (`slideProgress = 0`),
            // then spring to the incoming one on the next runloop tick. Deferring the animation one
            // tick is what makes it animate — setting 0 then 1 in the same closure collapses to a
            // no-op (SwiftUI animates from the last *committed* value). `slideProgress` drives the
            // page offset and the interpolated height together, so the slide and the resize are one motion.
            .onChange(of: layout.screenSlideID) { _, id in
                guard id != 0 else { return }
                slideProgress = 0
                animatedSlideID = id
                Task { @MainActor in
                    withAnimation(Motion.spring) { slideProgress = 1 }
                }
            }
            .onChange(of: layout.customizeGroups.map { group in
                "\(group.provider.id):\(group.metrics.map(\.id).joined(separator: ","))"
            }) {
                hasMeasuredCustomizeContent = false
            }
            .task {
                guard !didInitialRefresh else { return }
                didInitialRefresh = true
                await dataStore.refreshAll()
            }
    }

    private func resetTransientState() {
        // Backstop for any popover-close path the status-item controller's hide doesn't cover: clear a
        // tooltip the cursor was resting on, since the closed popover fires no hover-exit. The Usage
        // Trend hover popover rides the same backstop.
        HoverTooltips.dismissAll()
        TrendHoverState.dismissAll()
        if layout.screen != .dashboard { layout.screen = .dashboard }
        reorderLift = nil
        layout.cancelDrag()
        // If the popover closes mid-resize (e.g. the global hotkey fires while dragging), the grip's
        // `onEnded` never runs — settle it here so the flag can't stay stuck (which would make the next
        // drag jump from a stale start height), and the dragged height is still persisted.
        if resizingPanel {
            resizingPanel = false
            MenuBarPopover.endResize?()
        }
        dashboardScrollPosition.scrollTo(edge: .top)
    }

    /// The popover's screens as a horizontal pager. At rest only the current screen is mounted (one
    /// page at offset 0), so drag-reorder's coordinate math and the footer's scroll-edge underlap are
    /// exactly what they'd be with the screen rendered alone. During a switch the outgoing and incoming
    /// screens are both mounted, ordered left-to-right by `slideRank`, and slid by a pure offset — while
    /// the chrome (top bar + footer), keyed off `layout.screen` in `screenView`, is identical on both
    /// pages, so it stays visually fixed while only the content slides beneath it.
    ///
    /// Why an offset and not a SwiftUI `.transition`: the cards' fill is translucent `.quaternary`
    /// glass. Any transition carrying `.opacity` composites a screen into a transparency layer where
    /// that material has no vibrant backdrop to sample and resolves to its opaque near-white base — a
    /// white flash across the grey cards (the regression this removes; it has no clean SwiftUI fix).
    /// A pure offset never touches opacity, so the glass keeps sampling the live popover backdrop. The
    /// pages are a `ForEach` keyed by screen, so the incoming page keeps its identity (and scroll
    /// position) when the slide collapses back to one page. `.animation(nil, value:)` stops the
    /// one-frame structural re-layout at the start of a switch from inheriting the footer buttons'
    /// mode-switch animation — only `slideProgress` animates the offset (and, in step, the height).
    private var modeBody: some View {
        let pages = slidePages
        return HStack(alignment: .top, spacing: 0) {
            ForEach(pages, id: \.self) { screen in
                screenView(screen)
                    .frame(width: Self.popoverWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: Self.popoverWidth, alignment: .leading)
        .offset(x: slideOffset(pages))
        .animation(nil, value: layout.screenSlideID)
    }

    /// True from the moment `layout.screen` changes until the slide reaches the incoming screen.
    private var isSliding: Bool {
        layout.screenSlideID != 0
            && (layout.screenSlideID != animatedSlideID || slideProgress < 1)
    }

    /// One page at rest (the current screen); the two involved screens in left-to-right rank order
    /// while a switch animates.
    private var slidePages: [PopoverScreen] {
        guard isSliding else { return [layout.screen] }
        let from = layout.screenSlideFrom
        let to = layout.screen
        return from.slideRank < to.slideRank ? [from, to] : [to, from]
    }

    /// Horizontal offset that places the outgoing screen at `slideProgress == 0` and the incoming one
    /// at `1`. Pinned to the outgoing screen until this transition's animation has actually started, so
    /// the first frame after a switch shows the screen being left — never a flash of the destination.
    private func slideOffset(_ pages: [PopoverScreen]) -> CGFloat {
        guard isSliding, pages.count > 1 else { return 0 }
        let fromOffset = -CGFloat(pages.firstIndex(of: layout.screenSlideFrom) ?? 0) * Self.popoverWidth
        let toOffset = -CGFloat(pages.firstIndex(of: layout.screen) ?? 0) * Self.popoverWidth
        let progress = animatedSlideID == layout.screenSlideID ? slideProgress : 0
        return fromOffset + progress * (toOffset - fromOffset)
    }

    /// Builds one screen: its scroll body wrapped in the fixed chrome. The chrome (top bar + footer
    /// with the folded-in resize handle) is keyed off `layout.screen` — the *destination* — not the
    /// per-page `screen`, so during a switch both mounted pages render identical chrome pinned to the
    /// same edges. The chrome therefore stays put while only the content offsets beneath it (the
    /// "one fixed footer / top bar doesn't slide" behaviour). The soft scroll-edge styles and the
    /// pinned bars attach to each page's scroll view (`MeasuredScrollScreen`), the documented place for
    /// them. Identity stays stable across the slide via the `ForEach` key in `modeBody`.
    @ViewBuilder
    private func screenView(_ screen: PopoverScreen) -> some View {
        scrollBody(for: screen)
            .softTopScrollEdge()
            .softBottomScrollEdge()
            .pinnedTopBar(spacing: 0) { fixedTopBar }
            .pinnedFooter(spacing: 0) { footerBar(for: layout.screen) }
    }

    /// The scrolling content for a screen, without chrome — this is the part that slides during a
    /// switch (its `screen` is the per-page one, so each mounted page shows its own content).
    @ViewBuilder
    private func scrollBody(for screen: PopoverScreen) -> some View {
        switch screen {
        case .dashboard:
            scrollingDashboard
        case .customize:
            CustomizeView(
                contentHeight: $customizeContentHeight,
                hasMeasuredContent: $hasMeasuredCustomizeContent,
                reorderSpaceName: Self.reorderSpace,
                reorderLift: $reorderLift
            )
        case .settings:
            SettingsScreen(
                contentHeight: $settingsContentHeight,
                hasMeasuredContent: $hasMeasuredSettingsContent
            )
        }
    }

    /// The fixed top back/title bar, keyed off `layout.screen` so it's identical on both slide pages
    /// (no horizontal travel): the back nav bar on Customize/Settings, nothing on the dashboard. Its
    /// `topBarHeight` is reserved per screen in `chromeHeight(for:)`; the dashboard reserves none.
    @ViewBuilder
    private var fixedTopBar: some View {
        switch layout.screen {
        case .dashboard:
            EmptyView()
        case .customize:
            navBar(title: "Customize", showsReset: true)
        case .settings:
            navBar(title: "Settings")
        }
    }

    /// The resize grabber, folded into the bottom of `footerBar` so it reads as one unit with the
    /// footer (not a detached strip below it). The drag is measured in `.global` space — pinned to the
    /// panel's fixed top edge — so the handle moving as the panel grows doesn't feed back into the
    /// gesture; it drives the host panel through `MenuBarPopover`, which resizes synchronously so the
    /// content can't lag the frame. The pointer style gives the standard resize cursor.
    private var resizeDragger: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            // A taller hit area than the 4pt handle, with extra room below so the handle sits up off
            // the window's rounded bottom edge instead of hugging it. `contentShape` comes after the
            // padding so the whole padded strip is draggable, not just the visible capsule.
            .padding(.top, 8)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
            // The grabber sits at the bottom of the footer on every screen, so it reads the same on all
            // three — the footer (and thus the handle) is the same fixed chrome everywhere now.
            .pointerStyle(.frameResize(position: .bottom))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !resizingPanel {
                            resizingPanel = true
                            MenuBarPopover.beginResize?()
                        }
                        MenuBarPopover.resizeBy?(value.translation.height)
                    }
                    .onEnded { _ in
                        resizingPanel = false
                        MenuBarPopover.endResize?()
                    }
            )
    }

    /// The widget list as a scroll view that fills the region the footer leaves. The content scrolls
    /// under the footer with the native soft scroll-edge fade (`softTopScrollEdge`/`softBottomScrollEdge`
    /// are applied uniformly in `screenView`). Unlike Customize/Settings it tracks the dashboard's own
    /// scroll position, so that modifier stays here on the scroll view.
    private var scrollingDashboard: some View {
        MeasuredScrollScreen(onMeasure: { newValue in
            if newValue > 0 { listContentHeight = newValue }
        }) {
            widgetContent
                .padding(.horizontal, Self.outerPadding)
                .padding(.top, density.contentTopPadding)
                .padding(.bottom, Self.contentBottomGap)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($dashboardScrollPosition)
    }

    @ViewBuilder
    private var widgetContent: some View {
        if layout.displayGroups.isEmpty {
            Text("Turn on Customize to choose what to show.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
        } else {
            WidgetGroupedListView(
                reorderSpaceName: Self.reorderSpace,
                reorderLift: $reorderLift
            )
        }
    }

    // MARK: - Pinned top nav bar

    /// The back nav bar pinned above Customize and Settings — the macOS-native place for a back
    /// affordance (top-leading), replacing the old trailing footer "Done" button. It's fixed chrome:
    /// applied uniformly in `screenView` via `pinnedTopBar` and keyed off `layout.screen` (see
    /// `fixedTopBar`), so it doesn't slide with the pages — it appears in place when entering
    /// Customize/Settings and clears on the dashboard, while the content slides beneath it. Its
    /// `barGlass()` (Liquid Glass) background lenses the content scrolling under it — the same
    /// content-aware glass as the footer.
    private func navBar(title: String, showsReset: Bool = false) -> some View {
        HStack(spacing: 10) {
            backButton
            Text(title)
                .font(.headline)
            Spacer(minLength: 8)
            if showsReset {
                resetCustomizationButton
            }
        }
        .padding(.horizontal, Self.footerHorizontalPadding)
        .frame(height: Self.topBarHeight)
        .frame(maxWidth: .infinity)
        // Same content-aware Liquid Glass as the footer (`barGlass`) — the matching top/bottom chrome.
        .barGlass()
        .confirmationDialog(
            "Reset Customization?",
            isPresented: $showingResetCustomizationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                layout.resetToDefault()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores the default metrics, order, and menu-bar pins. Provider settings are unchanged.")
        }
    }

    /// The round glass back button (chevron leading), matching the footer's glass control idiom. Esc
    /// and the system shortcuts back out too; this is the visible, expected affordance.
    private var backButton: some View {
        Button {
            withAnimation(Motion.modeSwitch) { layout.screen = .dashboard }
        } label: {
            Label("Back", systemImage: "chevron.backward")
                .labelStyle(.iconOnly)
                .frame(width: 16, height: 16)
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .hoverTooltip("Back")
        .accessibilityLabel("Back")
    }

    private var resetCustomizationButton: some View {
        Button {
            showingResetCustomizationConfirmation = true
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .labelStyle(.titleAndIcon)
        }
        .glassButtonStyle()
        .controlSize(.small)
        .hoverTooltip("Reset Customization")
        .accessibilityLabel("Reset Customization")
    }

    // MARK: - Pinned footer

    /// The bottom chrome as one unit: the footer row — app identity + live refresh countdown (or the
    /// Customize pin summary) plus the glass Customize/Settings buttons — with the resize handle folded
    /// directly beneath it. Pinned via `pinnedFooter` (`safeAreaBar` on macOS 26; `safeAreaInset` on
    /// macOS 15).
    ///
    /// Its background is `barGlass()` — content-aware Liquid Glass (`glassEffect`) that lenses the
    /// in-app data scrolling beneath it, so the footer reads as real glass over the content (and stays
    /// consistent regardless of what's behind the window; the body stays opaque). A custom `safeAreaBar`
    /// gets no automatic system glass on macOS 27, so this explicit background is REQUIRED — without it
    /// the footer is transparent and content bleeds through. On Settings the trailing buttons are empty
    /// (`HeaderView` only shows them on the dashboard), leaving just the identity line.
    @ViewBuilder
    private func footerBar(for screen: PopoverScreen) -> some View {
        VStack(spacing: 0) {
            Group {
                if screen == .customize {
                    // Customize summarizes the layout — active (enabled) metrics and how many are pinned —
                    // centered, using the same middot the metric rows use.
                    Text(layout.pinLimitNotice ?? "\(activeMetricCount) active · \(layout.pinnedCount) pinned")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(layout.pinLimitNotice == nil ? AnyShapeStyle(.secondary) : Theme.notice)
                        .denyShake(trigger: layout.pinNoticeShakeTrigger)
                        .frame(maxWidth: .infinity)
                        .animation(Motion.spring, value: layout.pinLimitNotice)
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        footerIdentity
                        Spacer(minLength: 8)
                        HeaderView(screen: screen)
                    }
                }
            }
            .padding(.horizontal, Self.footerHorizontalPadding)
            .padding(.top, 12)
            // Tight to the resize handle just below, so the footer row and handle read as one cluster.
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)

            resizeDragger
        }
        // Content-aware Liquid Glass: `glassEffect` lenses the in-app data scrolling under the footer
        // (not the desktop), so it stays consistent regardless of what's behind the window. Renders on
        // macOS 26+, including the macOS 27 (Golden Gate) beta; macOS 15 falls back to a frosted material.
        .barGlass()
    }

    /// Count of enabled ("active") metrics across providers — the "N active" half of the Customize footer
    /// summary. Pinned metrics are a subset of these.
    private var activeMetricCount: Int {
        layout.customizeGroups.reduce(0) { count, group in
            count + group.metrics.filter { layout.isMetricEnabled($0.id) }.count
        }
    }

    /// Leading side of the footer. Normal mode shows the app name with the live "Next update in …"
    /// line beneath it; Customize mode shows the pin count ("4 pinned") in the same slot.
    /// Settings keeps the normal identity — the version line doubles as the About info there.
    /// A denied pin attempt swaps either line for the reason (in orange), played with the macOS
    /// deny shake — the wrong-password idiom — on every blocked click.
    @ViewBuilder
    private var footerIdentity: some View {
        // Both lines share the same font and muted style so the footer reads as one block.
        VStack(alignment: .leading, spacing: 0) {
            Text("OpenUsage \(AppInfo.version)")
            if let notice = layout.pinLimitNotice {
                Text(notice)
                    .foregroundStyle(Theme.notice)
                    // This label is inserted by the denial itself, so it must shake on mount.
                    .denyShake(trigger: layout.pinNoticeShakeTrigger, shakeOnAppear: true)
            } else {
                nextUpdateButton
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .animation(Motion.spring, value: layout.pinLimitNotice)
    }

    /// Ticks once a second so the "Next update in …" copy counts down live, and doubles as the manual
    /// refresh control: clicking it (or ⌘R) forces a fresh pass immediately. While a refresh is in
    /// flight it reads "Updating…" with a small system spinner after the text.
    private var nextUpdateButton: some View {
        Button {
            refreshNow()
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    Text(updateStatusText(now: context.date))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if isUpdating {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .hoverTooltip("Refresh now (⌘R)")
        .disabled(isUpdating)
    }

    private func refreshNow() {
        guard !isUpdating else { return }
        Task { await dataStore.refreshAll(force: true) }
    }

    private var isUpdating: Bool {
        !dataStore.refreshingProviderIDs.isEmpty
    }

    /// "Updating…" during an in-flight refresh, otherwise a live countdown to the next scheduled pass
    /// (last completed pass + the refresh interval). Falls back to a full interval before the first pass.
    private func updateStatusText(now: Date) -> String {
        if isUpdating {
            return "Updating…"
        }
        let interval = RefreshSetting.interval
        let base = dataStore.lastRefreshAt ?? now
        let remaining = max(0, base.addingTimeInterval(interval).timeIntervalSince(now))
        let totalSeconds = Int(remaining.rounded(.up))
        if totalSeconds >= 60 {
            let minutes = Int((Double(totalSeconds) / 60).rounded(.up))
            return "Next update in \(minutes)m"
        }
        return "Next update in \(totalSeconds)s"
    }
}

/// The popover's opaque backdrop tray, painted behind all content so the popover reads as one solid
/// panel — the data region never shows the desktop through it. Matches the AppKit panel backdrop
/// (`StatusItemController`'s `NSBox`) — both `Theme.traySurface`. The footer draws its own frosted
/// glass bar on top of this (in-window), so glass stays chrome over solid content. Never hit-tests,
/// so it can't steal clicks from the content above it.
private struct PopoverSurface: View {
    var body: some View {
        Theme.traySurface
            .allowsHitTesting(false)
    }
}
