import CoreGraphics
import Foundation
import Observation
import UIKit

/// Where the Mac's screen is and who signs in. The password is in the Keychain.
struct ScreenSettings {
    static let passwordAccount = "mac-screen-password"

    var host: String
    var port: Int
    var username: String

    static func load(defaultHost: String) -> ScreenSettings {
        let defaults = UserDefaults.standard
        #if DEBUG
        // Simulator runs against demo/fake_screen.py: -screenHost … -screenPort 5901 -screenUser demo -screenPassword demo
        if let host = defaults.string(forKey: "screenHost") {
            return ScreenSettings(host: host, port: defaults.integer(forKey: "screenPort"),
                                  username: defaults.string(forKey: "screenUser") ?? "")
        }
        #endif
        let port = defaults.integer(forKey: "macScreenPort")
        let saved = defaults.string(forKey: "macScreenHost") ?? ""
        return ScreenSettings(host: saved.isEmpty ? defaultHost : saved,
                              port: port == 0 ? 5900 : port,
                              username: defaults.string(forKey: "macScreenUser") ?? "")
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: "macScreenHost")
        defaults.set(port, forKey: "macScreenPort")
        defaults.set(username, forKey: "macScreenUser")
    }

    static var password: String? {
        #if DEBUG
        if let password = UserDefaults.standard.string(forKey: "screenPassword") { return password }
        #endif
        return Keychain.load(account: passwordAccount)
    }
}

/// X11 keysyms the Mac's screen-sharing server understands.
enum Keysym {
    static let backspace: UInt32 = 0xFF08, tab: UInt32 = 0xFF09, returnKey: UInt32 = 0xFF0D
    static let escape: UInt32 = 0xFF1B, delete: UInt32 = 0xFFFF
    static let left: UInt32 = 0xFF51, up: UInt32 = 0xFF52, right: UInt32 = 0xFF53, down: UInt32 = 0xFF54
    static let pageUp: UInt32 = 0xFF55, pageDown: UInt32 = 0xFF56
    static let shift: UInt32 = 0xFFE1, control: UInt32 = 0xFFE3, option: UInt32 = 0xFFE9, command: UInt32 = 0xFFEB

    static func of(_ scalar: Unicode.Scalar) -> UInt32 {
        switch scalar {
        case "\n", "\r": returnKey
        case "\t": tab
        default: scalar.value < 0x100 ? scalar.value : 0x0100_0000 | scalar.value
        }
    }
}

/// One live look at the Mac's screen.
@MainActor
@Observable
final class ScreenSession {
    enum Phase: Equatable {
        case idle, connecting, signingIn
        case live(String)
        case failed(String)
    }

    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let control = Modifiers(rawValue: 4)
        static let shift = Modifiers(rawValue: 8)
    }

    var phase: Phase = .idle
    var image: CGImage?
    /// Latched modifiers, applied to the next key and then released.
    var modifiers: Modifiers = []
    /// Text the Mac put on its clipboard, until dismissed.
    var macClipboard: String?
    /// Where the last tap landed, in screen pixels.
    var lastTap: CGPoint?
    /// How macOS arranges the displays, from Gravity Lens.
    var layout: [MacDisplay] = []
    /// Which display fills the phone; nil shows them all.
    var focus: Int? = UserDefaults.standard.object(forKey: "screenFocus") as? Int {
        didSet { UserDefaults.standard.set(focus, forKey: "screenFocus") }
    }

    @ObservationIgnored private var client: RFBClient?
    @ObservationIgnored private var pointer = CGPoint.zero

    var size: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }

    /// Each display's rectangle within the shared picture, left to right.
    /// Screen Sharing sends every display as one image covering their
    /// combined bounds.
    var displays: [CGRect] {
        guard size.width > 0 else { return [] }
        if layout.count > 1 {
            let union = layout.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            let scale = size.width / union.width
            return layout.map { display in
                CGRect(x: (display.x - union.minX) * scale, y: (display.y - union.minY) * scale,
                       width: display.width * scale, height: display.height * scale).integral
            }
        }
        // Without Gravity Lens: a picture far wider than any one screen is
        // most likely two side by side.
        if layout.isEmpty, size.width / size.height > 2.5 {
            let half = (size.width / 2).rounded()
            return [CGRect(x: 0, y: 0, width: half, height: size.height),
                    CGRect(x: half, y: 0, width: size.width - half, height: size.height)]
        }
        return []
    }

    /// Short names for the display switch: Left and Right, or numbers.
    var displayNames: [String] {
        let rects = displays
        guard rects.count > 1 else { return [] }
        if rects.count == 2 {
            let (a, b) = (rects[0], rects[1])
            if abs(a.midY - b.midY) < abs(a.midX - b.midX) {
                return a.midX < b.midX ? ["Left", "Right"] : ["Right", "Left"]
            }
            return a.midY < b.midY ? ["Top", "Bottom"] : ["Bottom", "Top"]
        }
        return rects.indices.map { String($0 + 1) }
    }

    /// The part of the picture on the phone.
    var focusRect: CGRect? {
        guard let focus, displays.indices.contains(focus) else { return nil }
        return displays[focus]
    }

    /// The main display when there is more than one and nothing is chosen yet.
    func chooseDefaultFocus() {
        guard UserDefaults.standard.object(forKey: "screenFocus") == nil, displays.count > 1 else { return }
        focus = layout.firstIndex(where: \.main) ?? 0
    }

    func connect(_ settings: ScreenSettings) {
        disconnect()
        guard let password = ScreenSettings.password, !password.isEmpty else {
            phase = .failed("Add the Mac's user name and password in Settings → Mac.")
            return
        }
        let client = RFBClient(host: settings.host, port: settings.port,
                               credentials: .init(username: settings.username, password: password))
        client.onState = { [weak self] state in self?.stateChanged(state) }
        client.onImage = { [weak self] image in self?.image = image }
        client.onClipboard = { [weak self] text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { self?.macClipboard = trimmed }
        }
        self.client = client
        client.start()
    }

    func disconnect() {
        client?.stop()
        client = nil
        if case .failed = phase { return }
        phase = .idle
    }

    private func stateChanged(_ state: RFBClient.State) {
        switch state {
        case .connecting: phase = .connecting
        case .signingIn: phase = .signingIn
        case .connected(let name): phase = .live(name)
        case .failed(let message): phase = .failed(message)
        case .closed: if case .live = phase { phase = .idle }
        }
    }

    // MARK: Pointer

    private func at(_ point: CGPoint) -> (Int, Int) {
        let x = Int(max(0, min(point.x, size.width - 1)))
        let y = Int(max(0, min(point.y, size.height - 1)))
        pointer = CGPoint(x: x, y: y)
        return (x, y)
    }

    func move(to point: CGPoint) {
        let (x, y) = at(point)
        client?.pointer(x: x, y: y, buttons: 0)
    }

    func click(at point: CGPoint, button: UInt8 = 1, count: Int = 1) {
        let (x, y) = at(point)
        lastTap = pointer
        withModifiers {
            client?.pointer(x: x, y: y, buttons: 0)
            for _ in 0..<count {
                client?.pointer(x: x, y: y, buttons: button)
                client?.pointer(x: x, y: y, buttons: 0)
            }
        }
    }

    func drag(from start: CGPoint, to end: CGPoint, ended: Bool) {
        let (sx, sy) = at(start)
        let (ex, ey) = at(end)
        client?.pointer(x: sx, y: sy, buttons: 1)
        client?.pointer(x: ex, y: ey, buttons: ended ? 0 : 1)
    }

    /// Positive lines scroll the content down (wheel towards you).
    func scroll(lines: Int) {
        let (x, y) = (Int(pointer.x), Int(pointer.y))
        let button: UInt8 = lines > 0 ? 16 : 8
        for _ in 0..<abs(lines) {
            client?.pointer(x: x, y: y, buttons: button)
            client?.pointer(x: x, y: y, buttons: 0)
        }
    }

    // MARK: Keyboard

    func type(_ text: String) {
        for scalar in text.unicodeScalars { press(Keysym.of(scalar)) }
    }

    func press(_ keysym: UInt32) {
        withModifiers {
            client?.key(keysym, down: true)
            client?.key(keysym, down: false)
        }
    }

    func toggle(_ modifier: Modifiers) {
        if modifiers.contains(modifier) { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
    }

    /// A shortcut such as ⌘C, whatever is latched.
    func shortcut(_ keysym: UInt32, _ held: Modifiers) {
        let saved = modifiers
        modifiers = held
        press(keysym)
        modifiers = saved
    }

    private func withModifiers(_ body: () -> Void) {
        let keys: [(Modifiers, UInt32)] = [(.command, Keysym.command), (.option, Keysym.option),
                                           (.control, Keysym.control), (.shift, Keysym.shift)]
        let held = keys.filter { modifiers.contains($0.0) }.map(\.1)
        for key in held { client?.key(key, down: true) }
        body()
        for key in held.reversed() { client?.key(key, down: false) }
        modifiers = []
    }

    // MARK: Clipboard

    func pasteToMac(_ text: String) {
        client?.sendClipboard(text)
    }
}
