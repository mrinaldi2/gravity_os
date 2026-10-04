import XCTest
@testable import TheHermes

/// The board contract's golden fixtures, vendored from the daemon repo with
/// its schema (contract/), decode as the generated types: the same files
/// Rust round-trips and vitest checks.
final class ContractTests: XCTestCase {
    private static let contract = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contract")

    /// Each fixture, named after its `BoardContract` field, and its type.
    private static let entities: [String: any Codable.Type] = [
        "card": BoardItemCard.self, "column": BoardColumn.self, "comment": BoardItemComment.self,
        "event": BoardItemEvent.self, "item": BoardItem.self, "link": BoardItemLink.self,
        "role": BoardProjectRole.self, "settings": BoardSettings.self, "template": BoardTemplate.self,
        "unmet": BoardUnmet.self,
    ]

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.contract.appendingPathComponent("fixtures/board/\(name).json"))
    }

    private func schema() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.contract.appendingPathComponent("board.schema.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// JSON without its nulls: the generated types leave a nil out when they
    /// encode, where the daemon writes an explicit null.
    private func withoutNulls(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.filter { !($0.value is NSNull) }.mapValues(withoutNulls)
        }
        if let array = value as? [Any] { return array.map(withoutNulls) }
        return value
    }

    func testEveryFixtureDecodesAndRoundTrips() throws {
        for (name, type) in Self.entities {
            let data = try fixture(name)
            let decoded: any Codable
            do {
                decoded = try Contracts.decoder().decode(type, from: data)
            } catch {
                XCTFail("\(name).json does not decode as \(type): \(error)")
                continue
            }
            let encoded = try Contracts.encoder().encode(decoded)
            let original = withoutNulls(try JSONSerialization.jsonObject(with: data))
            let again = withoutNulls(try JSONSerialization.jsonObject(with: encoded))
            XCTAssertEqual(original as? NSDictionary, again as? NSDictionary, "\(name).json changes on a round trip")
        }
    }

    func testFixturesTogetherAreTheWholeContract() throws {
        var whole: [String: Any] = [:]
        for name in Self.entities.keys {
            whole[name] = try JSONSerialization.jsonObject(with: fixture(name))
        }
        let data = try JSONSerialization.data(withJSONObject: whole)
        XCTAssertNoThrow(try Contracts.decoder().decode(BoardContract.self, from: data))
    }

    func testFixturesSchemaAndTestsNameTheSameEntities() throws {
        let properties = try XCTUnwrap(schema()["properties"] as? [String: Any])
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.contract.appendingPathComponent("fixtures/board").path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
        XCTAssertEqual(Set(properties.keys), Set(Self.entities.keys), "a schema entity has no type mapping here")
        XCTAssertEqual(Set(files), Set(Self.entities.keys), "a fixture is missing, or one has no entity")
    }

    func testTheAppSpeaksTheSchemaVersion() throws {
        let contract = try XCTUnwrap(schema()["x-contract"] as? [String: Any])
        XCTAssertEqual(contract["name"] as? String, "board")
        XCTAssertEqual(Contracts.client["board"], contract["version"] as? Int)
    }

    func testOptionalsSentAsExplicitNullDecodeAsNil() throws {
        let item = try Contracts.decoder().decode(BoardItem.self, from: fixture("item"))
        XCTAssertNil(item.parentID)
        XCTAssertNil(item.releaseID)
        XCTAssertEqual(item.blocked?.by, "H-016")
        XCTAssertEqual(item.acceptanceCriteria.count, 2)
        XCTAssertNil(item.acceptanceCriteria[1].checkedAt)
    }

    func testDatesWithFractionalSeconds() throws {
        let json = #"{"reason": "Waiting", "since": "2026-10-04T09:12:33.123456Z", "by": null}"#
        let blocked = try Contracts.decoder().decode(BoardBlocked.self, from: Data(json.utf8))
        XCTAssertEqual(blocked.since.timeIntervalSince1970, 1_791_105_153.123, accuracy: 0.001)
    }

    func testHelloContracts() {
        XCTAssertEqual(Contracts.served(by: ["contracts": ["board": 1, "releases": 2]]), ["board": 1, "releases": 2])
        XCTAssertEqual(Contracts.served(by: ["server_version": "0.13.0"]), [:], "a daemon from before contracts")
    }
}
