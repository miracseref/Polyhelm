import AppKit
import Carbon.HIToolbox

/// System-wide hotkey (⌥⌘Space) that summons the island and gives it keyboard focus.
///
/// Uses Carbon's `RegisterEventHotKey` rather than an NSEvent global monitor
/// because that route needs Accessibility permission and sees every keystroke
/// the user types; this sees exactly one combination and needs no grant.
@MainActor
enum HotKey {
    private static var reference: EventHotKeyRef?
    private static var action: (() -> Void)?

    static func register(_ handler: @escaping () -> Void) {
        guard reference == nil else { return }
        action = handler

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Carbon hands back a C function pointer, so no context can be captured.
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.action?() } }
            return noErr
        }, 1, &spec, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x4E_44_43_4B), id: 1) // 'NDCK'
        RegisterEventHotKey(UInt32(kVK_Space),
                            UInt32(optionKey | cmdKey),
                            id,
                            GetApplicationEventTarget(),
                            0,
                            &reference)
    }

    static func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        action = nil
    }
}
