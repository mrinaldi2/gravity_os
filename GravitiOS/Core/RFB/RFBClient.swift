import CoreGraphics
import Foundation
import Network

/// A VNC (RFB 3.8) client for macOS Screen Sharing: signs in, keeps a
/// framebuffer current and sends pointer, key and clipboard events.
/// Reading and decoding run off the main actor; callbacks come back on it.
final class RFBClient: @unchecked Sendable {
    enum State: Equatable {
        case connecting
        case signingIn
        case connected(name: String)
        case failed(String)
        case closed
    }

    struct Credentials {
        var username: String
        var password: String
    }

    var onState: (@MainActor (State) -> Void)?
    var onImage: (@MainActor (CGImage) -> Void)?
    var onClipboard: (@MainActor (String) -> Void)?

    private let connection: NWConnection
    private let credentials: Credentials
    private let queue = DispatchQueue(label: "gravitios.rfb")
    private var buffer: [UInt8] = []
    private var bufferOffset = 0
    private var task: Task<Void, Never>?
    private var framebuffer = Framebuffer(width: 1, height: 1)
    private var inflater: Inflater?

    // Encodings, in the order the Mac should prefer them.
    private static let encodings: [Int32] = [16, 5, 1, 0, -223]  // ZRLE, Hextile, CopyRect, Raw, DesktopSize

    init(host: String, port: Int, credentials: Credentials) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 5900,
                                  using: .tcp)
        self.credentials = credentials
    }

    func start() {
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        connection.cancel()
    }

    // MARK: Session

    private func run() async {
        do {
            await report(.connecting)
            try await waitUntilReady()
            try await handshake()
            try await sendFormatAndEncodings()
            requestUpdate(incremental: false)
            try await messageLoop()
        } catch is CancellationError {
            await report(.closed)
        } catch {
            connection.cancel()
            await report(.failed(error.localizedDescription))
        }
    }

    private func report(_ state: State) async {
        await MainActor.run { [onState] in onState?(state) }
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // State updates arrive on `queue` only, one at a time.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            connection.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    once.done = true
                    continuation.resume(throwing: RFBError.protocolError(
                        "Could not reach Screen Sharing on the Mac (\(error.localizedDescription)). Is it turned on?"))
                case .cancelled:
                    once.done = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func handshake() async throws {
        let version = String(decoding: try await read(12), as: UTF8.self)
        guard version.hasPrefix("RFB ") else { throw RFBError.protocolError("That port is not a screen-sharing server.") }
        let minor = Int(version.dropFirst(8).prefix(3)) ?? 3
        let modern = minor >= 7
        send(Array((modern ? "RFB 003.008\n" : "RFB 003.003\n").utf8))

        await report(.signingIn)
        var type: UInt8
        if modern {
            let count = Int(try await u8())
            if count == 0 { throw RFBError.auth(try await reason()) }
            let offered = try await read(count)
            if offered.contains(30), !credentials.username.isEmpty {
                type = 30
            } else if offered.contains(2) {
                type = 2
            } else if offered.contains(1) {
                type = 1
            } else if offered.contains(30) {
                throw RFBError.auth("Enter the Mac's user name and password.")
            } else {
                throw RFBError.auth("The Mac asked for a sign-in method GravitiOS does not support (\(offered)).")
            }
            send([type])
        } else {
            type = UInt8(truncatingIfNeeded: try await u32())
            if type == 0 { throw RFBError.auth(try await reason()) }
        }

        switch type {
        case 30:
            let generator = try await read(2)
            let length = Int(try await u16())
            let prime = try await read(length)
            let serverKey = try await read(length)
            send(try RFBCrypto.appleResponse(generator: generator, prime: prime, serverKey: serverKey,
                                             username: credentials.username, password: credentials.password))
        case 2:
            let challenge = try await read(16)
            send(try RFBCrypto.vncResponse(challenge: challenge, password: credentials.password))
        default:
            break
        }
        if modern || type != 1 {
            if try await u32() != 0 {
                let why = modern ? (try? await reason()) : nil
                throw RFBError.auth(why.flatMap { $0.isEmpty ? nil : "The Mac refused the sign-in: \($0)" }
                                    ?? "The Mac refused the user name or password.")
            }
        }

        send([1])  // ClientInit: share the session with anyone else watching
        let width = Int(try await u16())
        let height = Int(try await u16())
        _ = try await read(16)  // the server's pixel format; ours replaces it
        let name = String(decoding: try await read(Int(try await u32())), as: UTF8.self)
        framebuffer = Framebuffer(width: width, height: height)
        await report(.connected(name: name))
    }

    private func sendFormatAndEncodings() async throws {
        // 32 bits per pixel, 24-bit colour, little-endian, 0x00RRGGBB.
        send([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        var message: [UInt8] = [2, 0] + be16(Self.encodings.count)
        for encoding in Self.encodings { message += be32(UInt32(bitPattern: encoding)) }
        send(message)
    }

    private func messageLoop() async throws {
        while !Task.isCancelled {
            switch try await u8() {
            case 0:
                try await framebufferUpdate()
                if let image = framebuffer.image() {
                    await MainActor.run { [onImage] in onImage?(image) }
                }
                requestUpdate(incremental: true)
            case 1:
                _ = try await read(3)
                let count = Int(try await u16())
                _ = try await read(count * 6)
            case 2:
                break  // bell
            case 3:
                _ = try await read(3)
                let text = String(decoding: try await read(Int(try await u32())), as: UTF8.self)
                await MainActor.run { [onClipboard] in onClipboard?(text) }
            case let other:
                throw RFBError.protocolError("The Mac sent a message GravitiOS does not understand (\(other)).")
            }
        }
    }

    private func framebufferUpdate() async throws {
        _ = try await u8()
        let count = Int(try await u16())
        for _ in 0..<count {
            let x = Int(try await u16()), y = Int(try await u16())
            let w = Int(try await u16()), h = Int(try await u16())
            let encoding = Int32(bitPattern: try await u32())
            switch encoding {
            case 0:
                let bytes = try await read(w * h * 4)
                bytes.withUnsafeBufferPointer { raw in
                    framebuffer.withRect(x: x, y: y, w: w, h: h) { out in
                        for i in Swift.stride(from: 0, to: raw.count, by: 4) {
                            out.put(UInt32(raw[i]) | UInt32(raw[i + 1]) << 8 | UInt32(raw[i + 2]) << 16)
                        }
                    }
                }
            case 1:
                let sx = Int(try await u16()), sy = Int(try await u16())
                framebuffer.copy(fromX: sx, fromY: sy, toX: x, toY: y, w: w, h: h)
            case 5:
                try await hextile(x: x, y: y, w: w, h: h)
            case 16:
                let length = Int(try await u32())
                let compressed = try await read(length)
                if inflater == nil { inflater = try Inflater() }
                try ZRLE.decode(try inflater!.inflate(compressed), x: x, y: y, w: w, h: h, into: framebuffer)
            case -223:
                framebuffer.resize(width: w, height: h)
            default:
                throw RFBError.protocolError("The Mac used a screen encoding GravitiOS does not support (\(encoding)).")
            }
        }
    }

    private func hextile(x: Int, y: Int, w: Int, h: Int) async throws {
        var background: UInt32 = 0, foreground: UInt32 = 0
        for ty in Swift.stride(from: y, to: y + h, by: 16) {
            let th = min(16, y + h - ty)
            for tx in Swift.stride(from: x, to: x + w, by: 16) {
                let tw = min(16, x + w - tx)
                let flags = try await u8()
                if flags & 1 != 0 {
                    let bytes = try await read(tw * th * 4)
                    framebuffer.withRect(x: tx, y: ty, w: tw, h: th) { out in
                        for i in Swift.stride(from: 0, to: bytes.count, by: 4) {
                            out.put(UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16)
                        }
                    }
                    continue
                }
                if flags & 2 != 0 { background = try await pixel() }
                framebuffer.fill(x: tx, y: ty, w: tw, h: th, color: background)
                if flags & 4 != 0 { foreground = try await pixel() }
                guard flags & 8 != 0 else { continue }
                let subrects = Int(try await u8())
                for _ in 0..<subrects {
                    let color = flags & 16 != 0 ? try await pixel() : foreground
                    let position = try await u8(), size = try await u8()
                    framebuffer.fill(x: tx + Int(position >> 4), y: ty + Int(position & 15),
                                     w: Int(size >> 4) + 1, h: Int(size & 15) + 1, color: color)
                }
            }
        }
    }

    // MARK: Input (any thread)

    func pointer(x: Int, y: Int, buttons: UInt8) {
        send([5, buttons] + be16(max(0, x)) + be16(max(0, y)))
    }

    func key(_ keysym: UInt32, down: Bool) {
        send([4, down ? 1 : 0, 0, 0] + be32(keysym))
    }

    /// The Mac's clipboard is Latin-1 in RFB; other characters are dropped.
    func sendClipboard(_ text: String) {
        let bytes = text.unicodeScalars.compactMap { $0.value < 256 ? UInt8($0.value) : nil }
        send([6, 0, 0, 0] + be32(UInt32(bytes.count)) + bytes)
    }

    private func requestUpdate(incremental: Bool) {
        send([3, incremental ? 1 : 0, 0, 0, 0, 0] + be16(framebuffer.width) + be16(framebuffer.height))
    }

    // MARK: Wire

    private func send(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .idempotent)
    }

    /// Reads exactly `count` bytes, refilling from the socket in large chunks
    /// so that byte-at-a-time parsing stays cheap.
    private func read(_ count: Int) async throws -> [UInt8] {
        while buffer.count - bufferOffset < count {
            if bufferOffset > 0 {
                buffer.removeFirst(bufferOffset)
                bufferOffset = 0
            }
            let chunk = try await receive(atLeast: count - buffer.count)
            buffer.append(contentsOf: chunk)
        }
        let out = Array(buffer[bufferOffset..<bufferOffset + count])
        bufferOffset += count
        return out
    }

    private func receive(atLeast minimum: Int) async throws -> [UInt8] {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(minimum, 1 << 20)) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: RFBError.protocolError(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                } else if complete {
                    continuation.resume(throwing: RFBError.closed)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    private func u8() async throws -> UInt8 { try await read(1)[0] }

    private func u16() async throws -> UInt16 {
        let b = try await read(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    private func u32() async throws -> UInt32 {
        let b = try await read(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    private func pixel() async throws -> UInt32 {
        let b = try await read(4)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16
    }

    private func reason() async throws -> String {
        String(decoding: try await read(Int(try await u32())), as: UTF8.self)
    }

    private func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}
