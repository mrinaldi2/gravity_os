import XCTest
@testable import GravitiOS

/// Lists that load a page at a time, as docs/protocol.md describes them.
final class PagingTests: XCTestCase {
    private func file(_ rel: String, _ modified: String) -> ArtifactFile {
        ArtifactFile(["path": "/p/artifacts/\(rel)", "rel": rel, "name": rel, "size": 1,
                      "modified": modified, "mime": "text/markdown"])
    }

    func testAPageOfFilesMergesNewestFirst() {
        let first = [file("b.md", "2026-10-03T10:00:00Z"), file("a.md", "2026-10-03T09:00:00Z")]
        let second = [file("old.md", "2026-10-01T09:00:00Z")]
        let merged = ArtifactPage.merge(first, second)
        XCTAssertEqual(merged.map(\.rel), ["b.md", "a.md", "old.md"])
    }

    func testAnEditedFileMovesUpInsteadOfDoubling() {
        let loaded = [file("b.md", "2026-10-03T10:00:00Z"), file("a.md", "2026-10-03T09:00:00Z")]
        let fresh = [file("a.md", "2026-10-03T11:00:00Z")]
        let merged = ArtifactPage.merge(loaded, fresh)
        XCTAssertEqual(merged.map(\.rel), ["a.md", "b.md"])
    }
}
