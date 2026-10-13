import Carbon.HIToolbox

/// System-wide shortcuts through Carbon's RegisterEventHotKey, which needs no Accessibility
/// permission (an NSEvent global monitor would).
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    enum Action: UInt32 { case next = 1, removeCurrent }

    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]

    /// Control-Option-Command with the right arrow / delete key.
    private static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let keys: [Action: Int] = [.next: kVK_RightArrow, .removeCurrent: kVK_Delete]

    func enable(next: @escaping () -> Void, removeCurrent: @escaping () -> Void) {
        disable()
        actions = [Action.next.rawValue: next, Action.removeCurrent.rawValue: removeCurrent]

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = id.id
            Task { @MainActor in HotKeys.shared.actions[pressed]?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        for (action, key) in Self.keys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5053_544C), id: action.rawValue) // "PSTL"
            if RegisterEventHotKey(UInt32(key), Self.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    func disable() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        actions = [:]
    }
}
