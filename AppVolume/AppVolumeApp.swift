import SwiftUI

@main
struct AppVolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Reine Menüleisten-App: kein Dock-Symbol (LSUIElement in Info.plist), kein Hauptfenster.
        MenuBarExtra("AppVolume", systemImage: "slider.horizontal.3") {
            PopoverView(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Hält das Modell, damit gespeicherte Lautstärken schon beim Start angewendet werden –
/// nicht erst, wenn das Popover zum ersten Mal geöffnet wird.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AudioModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
