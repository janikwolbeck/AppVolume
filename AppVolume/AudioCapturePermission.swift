import Foundation

/// Berechtigung „Systemaudio aufnehmen" (TCC-Dienst kTCCServiceAudioCapture).
///
/// Apple bietet dafür keine öffentliche API zum Abfragen oder Anfordern. Ohne Abfrage würde ein
/// Tap bei fehlender Berechtigung die App stummschalten, ohne dass wir ihren Ton wiedergeben
/// dürfen. Deshalb werden die beiden TCC-Funktionen zur Laufzeit nachgeladen. Fehlen sie in
/// einer künftigen macOS-Version, gilt die Berechtigung als erteilt und das System fragt selbst
/// nach, sobald der erste Tap angelegt wird.
enum AudioCapturePermission {
    enum Status {
        case authorized, denied, undetermined
    }

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let framework, let symbol = dlsym(framework, "TCCAccessPreflight") else { return .authorized }
        switch unsafeBitCast(symbol, to: PreflightFunction.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// Zeigt den Systemdialog (nur solange noch nicht entschieden wurde). `completion` läuft auf dem Main-Thread.
    static func request(completion: @escaping () -> Void) {
        guard let framework, let symbol = dlsym(framework, "TCCAccessRequest") else {
            completion()
            return
        }
        unsafeBitCast(symbol, to: RequestFunction.self)(service, nil) { _ in
            DispatchQueue.main.async(execute: completion)
        }
    }
}
