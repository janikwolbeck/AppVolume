import CoreAudio
import Foundation

/// Kleine Helfer für den Zugriff auf Core-Audio-Objekte (HAL).
extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Liest eine Eigenschaft mit festem Speicherlayout (UInt32, pid_t, AudioStreamBasicDescription …).
    /// Nicht für Objekt-Referenzen wie CFString verwenden.
    func read<Value>(_ selector: AudioObjectPropertySelector, default fallback: Value) -> Value {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<Value>.size)
        var value = fallback
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : fallback
    }

    func readString(_ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    func readObjectIDs(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = Self.address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// Meldet Änderungen einer Eigenschaft auf dem Main-Thread. Der Listener bleibt bestehen,
    /// solange das Objekt existiert – das System ruft ihn nur bei echten Änderungen auf (kein Polling).
    func observe(_ selector: AudioObjectPropertySelector, handler: @escaping () -> Void) {
        var address = Self.address(selector)
        AudioObjectAddPropertyListenerBlock(self, &address, .main) { _, _ in handler() }
    }
}
