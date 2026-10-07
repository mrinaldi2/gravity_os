import UIKit
import XCTest
@testable import TheHermes

/// H-207: card ids in running text are links one by one: each has its own
/// range (for its long-press and hover), and VoiceOver names each
/// "H-293: <title>".
@MainActor
final class LinkedTextTests: XCTestCase {
    private let prefixes: Set<String> = ["HL"]
    private let font = UIFont.preferredFont(forTextStyle: .callout)

    func testEachIdIsItsOwnLink() {
        let text = LinkedTextModel.attributed("Done: **HL-004** is in Review, and HL-005 waits. Branch HL-004-board-chips.",
                                              prefixes: prefixes, font: font, color: .label)
        let links = LinkedTextModel.cardLinks(in: text)
        XCTAssertEqual(links.map(\.id), ["HL-004", "HL-005"], "the branch name stays text")
        let ns = text.string as NSString
        XCTAssertEqual(links.map { ns.substring(with: $0.range) }, ["HL-004", "HL-005"])
        XCTAssertFalse(text.string.contains("**"), "Markdown marks are rendered, not shown")
    }

    func testBoldStaysBoldOnTopOfTheBaseFont() {
        let text = LinkedTextModel.attributed("**HL-004** ok", prefixes: prefixes, font: font, color: .label)
        let first = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertTrue(first?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
        let plain = text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? UIFont
        XCTAssertFalse(plain?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? true)
    }

    func testVoiceOverNamesEachLink() {
        XCTAssertEqual(LinkedTextModel.spokenName("HL-004", title: "Board chips on iPad"), "HL-004: Board chips on iPad")
        XCTAssertEqual(LinkedTextModel.spokenName("HL-004", title: nil), "HL-004, card")

        let view = CardLinkTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        view.attributedText = LinkedTextModel.attributed("See HL-004 and HL-005.", prefixes: prefixes, font: font, color: .label)
        view.links = LinkedTextModel.cardLinks(in: view.attributedText)
        view.title = { $0 == "HL-004" ? "Board chips on iPad" : nil }
        var opened: URL?
        view.open = { opened = $0 }
        let elements = view.accessibilityElements as? [UIAccessibilityElement] ?? []
        XCTAssertEqual(elements.map(\.accessibilityLabel), ["See HL-004 and HL-005.", "HL-004: Board chips on iPad", "HL-005, card"])
        XCTAssertTrue(elements[1].accessibilityTraits.contains(.link))
        XCTAssertTrue(elements[2].accessibilityActivate())
        XCTAssertEqual(opened, CardLinker.url("HL-005"), "activating a link opens that card")
    }

    func testPlainTextHasNoExtraElements() {
        let view = CardLinkTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 60))
        view.attributedText = LinkedTextModel.attributed("Nothing to link, UTF-8.", prefixes: prefixes, font: font, color: .label)
        view.links = LinkedTextModel.cardLinks(in: view.attributedText)
        XCTAssertNil(view.accessibilityElements, "the system reads it as ordinary text")
    }

    func testRunningTextVersusBlockMarkdown() {
        XCTAssertTrue(LinkedTextModel.isRunningText("Done: **HL-004** is in Review.\nNext: HL-005."))
        XCTAssertFalse(LinkedTextModel.isRunningText("## Plan\nHL-004 first"))
        XCTAssertFalse(LinkedTextModel.isRunningText("- HL-004\n- HL-005"))
        XCTAssertFalse(LinkedTextModel.isRunningText("1. HL-004"))
        XCTAssertFalse(LinkedTextModel.isRunningText("| id | title |"))
        XCTAssertFalse(LinkedTextModel.isRunningText("```\nlog\n```"))
        XCTAssertFalse(LinkedTextModel.isRunningText("![shot](a.png)"))
    }

    func testThePointerOrPressFindsTheLinkUnderIt() {
        // Hover (AC1) and the per-link long-press (AC0) both start from the link
        // under the finger or pointer: only that card, never the whole block.
        let view = CardLinkTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        view.textContainerInset = .zero
        view.attributedText = LinkedTextModel.attributed("See HL-004 and HL-005 today.", prefixes: prefixes, font: font, color: .label)
        view.links = LinkedTextModel.cardLinks(in: view.attributedText)
        view.layoutIfNeeded()
        let second = view.rect(for: view.range(of: "HL-005")!)
        XCTAssertFalse(second.isEmpty)
        XCTAssertEqual(view.cardId(at: CGPoint(x: second.midX, y: second.midY)), "HL-005")
        let first = view.rect(for: view.range(of: "HL-004")!)
        XCTAssertEqual(view.cardId(at: CGPoint(x: first.midX, y: first.midY)), "HL-004")
        XCTAssertNil(view.cardId(at: CGPoint(x: 2, y: first.midY)), "plain text: no card")
    }
}
