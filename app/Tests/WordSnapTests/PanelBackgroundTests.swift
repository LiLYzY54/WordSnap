import AppKit
import XCTest
@testable import WordSnap

@MainActor
final class PanelBackgroundTests: XCTestCase {
    func testTraditionalMaterialKeepsContentAboveBlurAndFillsResizedPanel() throws {
        // Exercise the fallback even when tests run on macOS 26 or later.
        let background = PanelBackgroundView(preferLiquidGlass: false)
        let content = NSView()
        background.setContentView(content)
        background.cornerRadius = 30
        let material = try XCTUnwrap(background.subviews.first as? NSVisualEffectView)
        XCTAssertEqual(material.material, .hudWindow)
        XCTAssertEqual(material.blendingMode, .behindWindow)
        XCTAssertEqual(material.state, .active)
        XCTAssertTrue(background.subviews.last === content)

        for height in [68.0, 320.0, 68.0] {
            background.frame = NSRect(x: 0, y: 0, width: 680, height: height)
            background.layoutSubtreeIfNeeded()
            XCTAssertEqual(content.frame, background.bounds)
            XCTAssertEqual(material.frame, background.bounds)
        }
        XCTAssertEqual(background.layer?.cornerRadius, 30)
        XCTAssertEqual(background.layer?.masksToBounds, true)
    }

    func testDefaultMaterialMatchesHostAndRetainsHostedContent() throws {
        let background = PanelBackgroundView()
        let content = NSView()
        background.setContentView(content)
        background.cornerRadius = 30
        if #available(macOS 26.0, *) {
            let glass = try XCTUnwrap(background.subviews.first as? NSGlassEffectView)
            XCTAssertTrue(glass.contentView === content)
            XCTAssertEqual(glass.style, .regular)
            XCTAssertEqual(glass.cornerRadius, 30)
        } else {
            XCTAssertTrue(background.subviews.first is NSVisualEffectView)
            XCTAssertTrue(background.subviews.last === content)
        }
    }
}
