import AppKit
import SwiftUI

/// Renders a `ShareCardView` into a PNG and hands it to the clipboard or a Save panel. Mirrors
/// `MenuBarStripRenderer`'s `ImageRenderer` → `cgImage` → `NSImage` path (scale 2 for a crisp
/// export), then adds the PNG encode and the two destinations.
@MainActor
enum ShareCardRenderer {
    /// What the Share action should do with the rendered card.
    enum Action {
        case copy
        case save
    }

    /// Off-screen render scale. ×2 matches the menu-bar strip renderer, so the exported PNG is crisp
    /// on Retina displays: a 1200×675 card ships as a 2400×1350 image.
    static let scale: CGFloat = 2

    /// The card rendered to an `NSImage`, or `nil` if `ImageRenderer` produces no CGImage. The
    /// image's point size is the card's authored size; its pixel size is that times `scale`.
    static func image(for view: ShareCardView) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        )
    }

    /// PNG-encodes an `NSImage`, or `nil` if the bitmap can't be formed.
    static func pngData(from image: NSImage) -> Data? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes the card's PNG onto the general pasteboard (replacing its contents). No-op if the PNG
    /// can't be encoded.
    static func copyToPasteboard(_ image: NSImage) {
        guard let png = pngData(from: image) else {
            AppLog.error(.lifecycle, "share card: failed to encode PNG for clipboard")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    /// Presents a Save panel (PNG only) and writes the card on confirm. No-op if the PNG can't be
    /// encoded or the user cancels.
    static func save(_ image: NSImage, suggestedName: String) {
        guard let png = pngData(from: image) else {
            AppLog.error(.lifecycle, "share card: failed to encode PNG for save")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
        } catch {
            AppLog.error(.lifecycle, "share card: failed to write PNG: \(error.localizedDescription)")
        }
    }

    /// Orchestrates a Share action end to end: resolve the provider's visible rows from the data
    /// store, build the card with the effective appearance, render it, and dispatch to the clipboard
    /// or Save panel. The rows mirror what the dashboard shows — always-shown plus expanded only when
    /// the provider's caret is open — so the export matches what the user sees.
    static func share(
        group: ProviderGroup,
        dataStore: WidgetDataStore,
        layout: LayoutStore,
        appearance: ColorScheme,
        action: Action
    ) {
        let visibleWidgets = layout.isProviderExpanded(group.provider.id) ? group.widgets : group.alwaysShownWidgets
        let rows = visibleWidgets.compactMap { widget -> WidgetData? in
            guard let descriptor = layout.descriptor(for: widget) else { return nil }
            return dataStore.data(for: descriptor)
        }
        let view = ShareCardView(
            provider: group.provider,
            plan: dataStore.plan(for: group.provider.id),
            rows: rows,
            appearance: appearance
        )
        guard let image = image(for: view) else {
            AppLog.error(.lifecycle, "share card: ImageRenderer produced no image for \(group.provider.id)")
            return
        }
        switch action {
        case .copy:
            copyToPasteboard(image)
        case .save:
            save(image, suggestedName: suggestedFileName(for: group.provider))
        }
    }

    /// Default export filename, e.g. `OpenUsage-Claude-2026-06-27.png`. Spaces in a display name are
    /// stripped so the suggested name is filesystem-friendly.
    static func suggestedFileName(for provider: Provider) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = formatter.string(from: Date())
        let safeName = provider.displayName.replacingOccurrences(of: " ", with: "")
        return "OpenUsage-\(safeName)-\(date).png"
    }
}
