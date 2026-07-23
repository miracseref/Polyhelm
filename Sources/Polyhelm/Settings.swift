import Foundation
import SwiftUI

/// User preferences, persisted to UserDefaults.
///
/// Plain computed properties rather than `@AppStorage` — that wrapper only
/// republishes correctly inside a View, and these are read from AppKit too.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private func flag(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    var soundsEnabled: Bool {
        get { flag("sounds", default: true) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "sounds") }
    }

    /// Route PreToolUse approvals to the notch. Off by default: it changes where
    /// permission prompts appear, which shouldn't happen without a deliberate opt-in.
    var notchApprovals: Bool {
        get { flag("notchApprovals", default: false) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "notchApprovals") }
    }

    /// Focus the panel when an approval arrives so ⏎/⎋ work immediately.
    /// Off by default — it pulls keyboard focus out of whatever you were typing in.
    var focusOnApproval: Bool {
        get { flag("focusOnApproval", default: false) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "focusOnApproval") }
    }

    /// Seconds an approval card waits before handing the prompt back to the terminal.
    /// Capped below the hook's `curl -m 58` so the decision always beats the wire.
    var approvalTimeout: Double {
        get { min(defaults.object(forKey: "approvalTimeout") as? Double ?? 45, 50) }
        set { objectWillChange.send(); defaults.set(min(newValue, 50), forKey: "approvalTimeout") }
    }

    private init() {}
}
