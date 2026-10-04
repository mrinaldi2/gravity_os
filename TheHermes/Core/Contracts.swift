import Foundation

/// The typed wire contracts this app speaks, each with its own version
/// (H-020 §1.4). Their types are generated from vendored JSON Schemas into
/// `Core/Generated/`; this is the hand-written part around them.
enum Contracts {
    /// What the app sends in `hello`. A breaking change on the daemon bumps a
    /// number; an additive one keeps it.
    static let client: [String: Int] = ["board": 1]

    /// The contracts a daemon serves, from `hello_ok`: empty for a daemon
    /// from before contracts.
    static func served(by hello: JSONDict) -> [String: Int] {
        guard let map = hello.dict("contracts") else { return [:] }
        var served: [String: Int] = [:]
        for (name, value) in map {
            if let number = value as? NSNumber { served[name] = number.intValue }
        }
        return served
    }

    /// Decodes contract JSON: RFC 3339 timestamps with or without fractional
    /// seconds, and optional fields sent as explicit null.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an RFC 3339 timestamp: \(text)")
        }
        return decoder
    }

    /// Encodes as the daemon does: RFC 3339 timestamps in UTC.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter().string(from: date))
        }
        return encoder
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
