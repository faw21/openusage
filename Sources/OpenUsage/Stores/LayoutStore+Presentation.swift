extension LayoutStore {
    /// Which in-popover screen is showing. Drives the footer buttons, the Esc handler, and the
    /// popover-closed reset alike.
    var screen: PopoverScreen {
        get { navigation.screen }
        set { navigation.screen = newValue }
    }
    /// The screen being left plus a per-switch counter, for DashboardView's horizontal slide.
    var screenSlideFrom: PopoverScreen { navigation.screenSlideFrom }
    var screenSlideID: Int { navigation.screenSlideID }
    /// Whether the Customize screen is showing — a bridge over `screen` for edit-mode call sites.
    var isEditing: Bool {
        get { navigation.isEditing }
        set { navigation.isEditing = newValue }
    }
    /// The provider whose Customize detail (L2) is showing (nil shows the L1 list).
    var customizeProviderID: String? {
        get { navigation.customizeProviderID }
        set { navigation.customizeProviderID = newValue }
    }

    /// Transient explanation for a denied pin attempt; the popover footer renders it in place of the pin
    /// counter. Set by `notePinDenied`, auto-cleared a few seconds later.
    var pinLimitNotice: String? { pinNotice.value }
    /// Bumped on every denied pin click so the footer notice plays its deny shake each time.
    var pinNoticeShakeTrigger: Int { pinNotice.trigger }

    /// Transient "Copied to clipboard" confirmation for the floating pill above the footer.
    var shareConfirmation: Bool { shareNotice.value }
    /// Bumped on every successful share so the pill replays its pop-in even on a repeat copy.
    var shareConfirmationTrigger: Int { shareNotice.trigger }

    /// Transient in-Customize notice (e.g. "Starred for menu bar", or the orange cap denial).
    var customizationNotice: String? { customizeNotice.value?.message }
    /// The notice's tone: `.positive` (green checkmark) or `.notice` (orange denial). Falls back to
    /// `.positive` once cleared (tone is only read while `customizationNotice` is non-nil, so the
    /// snap-back is unobservable — message and tone now clear atomically, which the old split state
    /// machine couldn't guarantee).
    var customizationNoticeTone: CustomizationNoticeTone { customizeNotice.value?.tone ?? .positive }
    /// Bumped on every present so the pill replays its pop-in even when the same notice repeats.
    var customizationNoticeTrigger: Int { customizeNotice.trigger }

    /// Record a successful "Share Screenshot" copy so the floating "Copied to clipboard" pill can
    /// confirm it. Shown for a couple of seconds then cleared — the success-side counterpart to
    /// `notePinDenied`'s transient denial notice, with the same lifecycle.
    func presentShareConfirmation() {
        shareNotice.present(true)
    }

    /// Clear any showing "Copied to clipboard" confirmation and cancel its auto-clear task. Called when
    /// the popover closes so a pill mid-countdown can't reappear stale on the next open — the timer is
    /// otherwise the only clearer, and the layout store outlives the popover.
    func clearShareConfirmation() {
        shareNotice.clear()
    }

    /// Show a transient in-Customize pill (the floating confirmation above the Customize content).
    /// `tone` picks the green success style or the orange denial style. Auto-clears after a couple of
    /// seconds; also cleared on popover close via `clearCustomizationNotice`.
    func presentCustomizationNotice(_ message: String, tone: CustomizationNoticeTone = .positive) {
        customizeNotice.present(CustomizationNoticeContent(message: message, tone: tone))
    }

    /// Clear any showing Customize pill and cancel its auto-clear task. Called when the popover closes
    /// so a pill mid-countdown can't reappear stale on the next open.
    func clearCustomizationNotice() {
        customizeNotice.clear()
    }

    func cancelDrag() {
        draggingID = nil
    }
}
