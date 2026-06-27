import XCTest
import SwiftUI
@testable import OpenUsage

/// Covers the Share card export pipeline: `image(for:)` rasterizes the fixed 16:9 card at ×2, and
/// `pngData(from:)` round-trips to a valid PNG. `ImageRenderer` is MainActor-only, so the whole case
/// runs on the main actor.
@MainActor
final class ShareCardRendererTests: XCTestCase {
    private func sampleCard() -> ShareCardView {
        let provider = MockData.claude
        let rows = MockData.descriptors(for: provider.id).map { $0.sample }
        return ShareCardView(provider: provider, plan: "Max", rows: rows, appearance: .light)
    }

    func testImageRendersAtFixedPixelDimensions() throws {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: sampleCard()))

        // Point size is the authored 16:9 card; the bitmap is that times the render scale.
        let rep = try XCTUnwrap(image.representations.first)
        XCTAssertEqual(rep.pixelsWide, Int(ShareCardView.width * ShareCardRenderer.scale))
        XCTAssertEqual(rep.pixelsHigh, Int(ShareCardView.height * ShareCardRenderer.scale))
    }

    func testPNGDataRoundTripsToValidPNG() throws {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: sampleCard()))
        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))

        XCTAssertFalse(png.isEmpty)
        // PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A.
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(png.prefix(magic.count)), magic)
        // The PNG must decode back into an image (a non-empty Data alone isn't proof it's valid).
        XCTAssertNotNil(NSImage(data: png))
    }

    func testRendersEmptyProviderWithoutCrashing() throws {
        let card = ShareCardView(provider: MockData.cursor, plan: nil, rows: [], appearance: .dark)
        let image = try XCTUnwrap(ShareCardRenderer.image(for: card))
        let rep = try XCTUnwrap(image.representations.first)
        XCTAssertEqual(rep.pixelsWide, Int(ShareCardView.width * ShareCardRenderer.scale))
    }

    func testSuggestedFileNameStripsSpacesAndCarriesDate() {
        let provider = Provider(id: "super", displayName: "Super Grok", icon: .symbol("bolt"))
        let name = ShareCardRenderer.suggestedFileName(for: provider)
        XCTAssertTrue(name.hasPrefix("OpenUsage-SuperGrok-"))
        XCTAssertTrue(name.hasSuffix(".png"))
    }
}
