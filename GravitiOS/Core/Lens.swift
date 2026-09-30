import Foundation
import Observation
import UIKit

// Gravity Lens: the companion on the Mac (companion/gravity_lens.py) that
// turns each bot's Claude Code log into readable turns. Its JSON is ours, so
// it is decoded strictly.

struct LensTrigger: Decodable, Hashable {
    /// `message`, `typed`, `background` or `continued`.
    let kind: String
    let from: String
    let msgKind: String
    let text: String
}

struct LensOutcome: Decodable, Hashable {
    /// `text`, `message`, `completed` or `none`.
    let kind: String
    let text: String
    let to: String
}

/// An image a turn touched: one the bot opened, or a file its work mentions.
struct LensImageRef: Decodable, Hashable, Identifiable {
    let id: String
    /// `inline` (kept in the log) or `file` (read from disk when asked for).
    let kind: String
    let name: String
    let path: String
    /// False when the file has since been deleted.
    let exists: Bool?
}

struct LensStats: Decodable, Hashable {
    let images: Int
    let commands: Int
    let reads: Int
    let edits: Int
    let added: Int
    let removed: Int
    let sent: Int
    let incoming: Int
    let errors: Int
    let steps: Int
    let files: [String]
}

struct LensTurn: Decodable, Identifiable, Hashable {
    let id: String
    let startedAt: String
    let updatedAt: String
    let endedAt: String?
    let durationMs: Int?
    /// Still running: no end marker yet and it is the bot's latest turn.
    let open: Bool
    let trigger: LensTrigger
    let outcome: LensOutcome
    let stats: LensStats
    /// Title of the latest step, for "now doing".
    let current: String
    let botId: String?
    let botName: String?
    let cover: LensImageRef?

    var started: Date? { WireDate.parse(startedAt) }
    var updated: Date? { WireDate.parse(updatedAt) }
}

struct LensEvent: Decodable, Identifiable, Hashable {
    let id: String
    let at: String
    /// `tool`, `text`, `incoming`, `sent`, `completed` or `compacted`.
    let kind: String
    let title: String
    let subtitle: String?
    let tool: String?
    let error: Bool?
    let added: Int?
    let removed: Int?
    let path: String?
    let text: String?
    let to: String?
    let from: String?
    let msgKind: String?
    let artifacts: [String]?
    let minor: Bool?
    let hasDetail: Bool?
    let images: [LensImageRef]?

    var date: Date? { WireDate.parse(at) }
}

struct LensEventDetail: Decodable {
    let event: LensEvent?
    let input: String?
    let command: String?
    let output: String?
    let diff: [String]?
    let content: String?
}

struct LensArtifact: Decodable, Identifiable, Hashable {
    let project: String
    let name: String
    let title: String
    let size: Int
    let modifiedAt: String

    var id: String { "\(project)/\(name)" }
    var modified: Date? { WireDate.parse(modifiedAt) }
}

private struct OverviewReply: Decodable {
    struct Row: Decodable {
        let botId: String
        let lastTurn: LensTurn?
    }
    let bots: [Row]
}

private struct TurnsReply: Decodable {
    let turns: [LensTurn]
    let hasMore: Bool?
}

private struct TurnReply: Decodable {
    let turn: LensTurn
    let events: [LensEvent]
}

/// A file or folder on the Mac, from the file browser.
struct MacFile: Decodable, Identifiable, Hashable {
    let name: String
    /// `~/…` for display.
    let path: String
    let kind: String
    let link: Bool
    let size: Int
    let modifiedAt: String
    let type: String

    var id: String { path }
    var isFolder: Bool { kind == "folder" }
    var modified: Date? { WireDate.parse(modifiedAt) }
    var isImage: Bool { type.hasPrefix("image/") }
}

struct MacFolder: Decodable {
    let path: String
    let absolute: String
    let name: String
    let parent: String?
    let roots: [String]
    let entries: [MacFile]

    /// The absolute path of an entry, for copying and sending to bots.
    func absolute(_ file: MacFile) -> String { (absolute as NSString).appendingPathComponent(file.name) }
}

/// One of the Mac's displays, in points, as macOS arranges them.
struct MacDisplay: Codable, Hashable {
    let id: Int
    let main: Bool
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private struct DisplaysReply: Decodable { let displays: [MacDisplay] }
private struct ArtifactsReply: Decodable { let artifacts: [LensArtifact] }
private struct ServerMessage: Decodable { let message: String? }
private struct ArtifactReply: Decodable { let text: String }

enum LensStatus: Equatable {
    case unknown
    case ok
    case unauthorized
    case unreachable(String)

    var label: String {
        switch self {
        case .unknown: "Checking…"
        case .ok: "Connected"
        case .unauthorized: "Token rejected"
        case .unreachable: "Not reachable"
        }
    }
}

@MainActor
@Observable
final class LensStore {
    var status: LensStatus = .unknown
    /// bot id → its latest turn.
    var latest: [String: LensTurn] = [:]
    var feed: [LensTurn] = []
    var artifacts: [LensArtifact] = []

    @ObservationIgnored private let app: AppStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let decoder: JSONDecoder
    @ObservationIgnored private let imageCache = NSCache<NSString, UIImage>()

    static let defaultPort = 49778

    var port: Int {
        let saved = UserDefaults.standard.integer(forKey: "lensPort")
        return saved == 0 ? Self.defaultPort : saved
    }

    init(app: AppStore) {
        self.app = app
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    // MARK: Requests

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        let data = try await fetch(path, query)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DaemonError(code: "decode", message: "Unexpected reply from Gravity Lens (\(error)).")
        }
    }

    private func fetch(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        guard let endpoint = app.endpoint else {
            throw DaemonError(code: "not_connected", message: "No daemon configured.")
        }
        #if DEBUG
        let host = UserDefaults.standard.string(forKey: "lensHost") ?? endpoint.host
        #else
        let host = endpoint.host
        #endif
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw DaemonError(code: "invalid", message: "Bad Lens address.") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                status = .unauthorized
                throw DaemonError(code: "unauthorized", message: "Gravity Lens rejected the device token.")
            }
            guard code == 200 else {
                let message = (try? decoder.decode(ServerMessage.self, from: data))?.message
                throw DaemonError(code: "http_\(code)", message: message ?? "Gravity Lens answered \(code).")
            }
            status = .ok
            return data
        } catch let error as DaemonError {
            throw error
        } catch {
            status = .unreachable(error.localizedDescription)
            throw error
        }
    }

    private func encode(_ part: String) -> String {
        part.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? part
    }

    // MARK: Loading

    func refresh() async {
        async let overview: OverviewReply? = try? get("/v1/overview")
        async let recent: TurnsReply? = try? get("/v1/feed", ["limit": "60"])
        if let overview = await overview {
            latest = Dictionary(overview.bots.compactMap { row in row.lastTurn.map { (row.botId, $0) } },
                                uniquingKeysWith: { first, _ in first })
        }
        if let recent = await recent { feed = recent.turns }
    }

    func turns(bot: String, before: String? = nil) async throws -> (turns: [LensTurn], hasMore: Bool) {
        var query = ["limit": "25"]
        if let before { query["before"] = before }
        let reply: TurnsReply = try await get("/v1/bots/\(encode(bot))/turns", query)
        return (reply.turns, reply.hasMore ?? false)
    }

    func turn(bot: String, id: String) async throws -> (turn: LensTurn, events: [LensEvent]) {
        let reply: TurnReply = try await get("/v1/bots/\(encode(bot))/turns/\(encode(id))")
        return (reply.turn, reply.events)
    }

    func detail(bot: String, event: String) async throws -> LensEventDetail {
        try await get("/v1/bots/\(encode(bot))/events/\(encode(event))")
    }

    enum ImageSource: Hashable {
        case bot(String, LensImageRef)
        case report(project: String, name: String, src: String)

        var title: String {
            switch self {
            case .bot(_, let ref): ref.name
            case .report(_, _, let src): (src as NSString).lastPathComponent
            }
        }
    }

    func image(_ source: ImageSource, thumb: Bool) async throws -> UIImage {
        let key: String
        let path: String
        var query = ["size": thumb ? "thumb" : "full"]
        switch source {
        case .bot(let bot, let ref):
            key = "\(bot)/\(ref.id)"
            path = "/v1/bots/\(encode(bot))/images/\(encode(ref.id))"
        case .report(let project, let name, let src):
            key = "\(project)/\(name)/\(src)"
            path = "/v1/artifacts/\(encode(project))/\(encode(name))/image"
            query["src"] = src
        }
        let cacheKey = "\(key)#\(thumb)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) { return cached }
        let data = try await fetch(path, query)
        guard let image = UIImage(data: data) else {
            throw DaemonError(code: "image", message: "Not an image the phone can show.")
        }
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    // MARK: Displays

    func displays() async throws -> [MacDisplay] {
        let reply: DisplaysReply = try await get("/v1/displays")
        return reply.displays
    }

    // MARK: Files

    func folder(_ path: String, hidden: Bool) async throws -> MacFolder {
        try await get("/v1/files", ["path": path, "hidden": hidden ? "1" : "0"])
    }

    /// Downloads a file into the app's cache under its own name, for preview and sharing.
    func download(_ path: String) async throws -> URL {
        let data = try await fetch("/v1/files/raw", ["path": path])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mac-files/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent((path as NSString).lastPathComponent)
        try data.write(to: url)
        return url
    }

    func fileThumbnail(_ path: String) async throws -> UIImage {
        let key = "file:\(path)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let data = try await fetch("/v1/files/raw", ["path": path, "size": "thumb"])
        guard let image = UIImage(data: data) else { throw DaemonError(code: "image", message: "Not an image.") }
        imageCache.setObject(image, forKey: key)
        return image
    }

    func loadArtifacts() async {
        if let reply: ArtifactsReply = try? await get("/v1/artifacts") { artifacts = reply.artifacts }
    }

    func artifact(project: String, name: String) async throws -> String {
        let reply: ArtifactReply = try await get("/v1/artifacts/\(encode(project))/\(encode(name))")
        return reply.text
    }

    /// `~/.gravity/projects/<project>/artifacts/<name>` → its report, if it is one.
    func report(forPath path: String) -> (project: String, name: String)? {
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.lastIndex(of: "artifacts"), index >= 2, index + 1 < parts.count,
              parts[index - 2] == "projects" else { return nil }
        return (parts[index - 1], parts[index + 1])
    }

    /// Keeps the feed and "now doing" lines fresh while the app is open.
    func poll() async {
        var last = Date.distantPast
        var wasConnected = false
        while !Task.isCancelled {
            let connected = app.status == .connected && !app.inBackground
            let interval: TimeInterval = app.bots.contains { $0.state == .working } ? 4 : 10
            // Straight away on (re)connecting, then on the interval.
            if connected, !wasConnected || Date().timeIntervalSince(last) >= interval {
                await refresh()
                last = Date()
            }
            wasConnected = connected
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
