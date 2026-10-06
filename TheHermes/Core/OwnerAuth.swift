import Foundation
import LocalAuthentication

/// Face ID (or the device passcode) before the phone acts as the owner in a
/// way that changes bot permissions (UX-023 decision 2; H-118): publishing or
/// confirming a ruling whose option grants extras.
enum OwnerAuth {
    enum Failure: LocalizedError, Equatable {
        case unavailable
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "Set up Face ID or a passcode on this iPhone to publish a ruling that grants access, or rule on it on the desktop."
            case .cancelled:
                "Not published: Face ID wasn’t confirmed."
            }
        }
    }

    /// Throws unless the owner confirms. `reason` shows under the Face ID prompt.
    static func confirm(_ reason: String) async throws {
        #if DEBUG
        // UI tests on a simulator without Face ID: -ownerAuthStub pass|fail.
        switch UserDefaults.standard.string(forKey: "ownerAuthStub") {
        case "pass": return
        case "fail": throw Failure.cancelled
        default: break
        }
        #endif
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { throw Failure.unavailable }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw Failure.cancelled
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.cancelled
        }
    }
}
