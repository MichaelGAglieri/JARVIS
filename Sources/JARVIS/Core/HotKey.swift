import Carbon
import Foundation

/// Global shortcuts (⌃⌥Space to speak, ⌃⌥P for privacy), active even
/// when JARVIS is not in front. Uses the Carbon APIs: no Accessibility
/// permission is needed.
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handler: EventHandlerRef?
    private static var nextID: UInt32 = 1
    private var ref: EventHotKeyRef?
    private let id: UInt32

    init(keyCode: Int = kVK_Space, modifiers: Int = controlKey | optionKey, action: @escaping () -> Void) {
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.actions[id] = action
        if HotKey.handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                let action = HotKey.actions[hotKeyID.id]
                DispatchQueue.main.async { action?() }
                return noErr
            }, 1, &spec, nil, &HotKey.handler)
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4A_52_56_53), id: id)  // "JRVS"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }
}
