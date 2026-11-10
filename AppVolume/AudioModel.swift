import AppKit
import CoreAudio
import os
import ServiceManagement
import UniformTypeIdentifiers

/// Eine App in der Liste. `id` ist die Bundle-ID.
struct AudioApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
}

/// Gespeicherte Einstellung einer App.
struct AppSetting: Equatable {
    /// Reglerposition 0…1.
    var volume: Double = 1
    var isMuted = false

    var isDefault: Bool { volume >= 1 && !isMuted }

    /// Quadratische Kennlinie: 50 % am Regler klingen ungefähr halb so laut (−12 dB).
    var gain: Float { isMuted ? 0 : Float(volume * volume) }
}

/// Zustand der App: Liste der Audio-Apps, Einstellungen pro Bundle-ID und die aktiven Taps.
/// Arbeitet rein ereignisgesteuert auf dem Main-Thread – im Leerlauf läuft hier nichts.
final class AudioModel: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var settings: [String: AppSetting] = [:]
    @Published private(set) var permission = AudioCapturePermission.status
    @Published private(set) var launchesAtLogin = false

    /// Alle Audio-Prozesse einer App (Hauptprozess und Helper), zusammengefasst über die Bundle-ID.
    private struct ProcessGroup {
        let app: NSRunningApplication
        var processes: [AudioObjectID] = []
        /// Mindestens ein Prozess betreibt gerade Audio-Ein-/Ausgabe.
        var isRunning = false
        /// Mindestens ein Prozess gibt gerade Ton aus.
        var isPlaying = false
    }

    private var groups: [String: ProcessGroup] = [:]
    private var taps: [String: AppTap] = [:]
    private var editing: Set<String> = []
    private var observedProcesses: Set<AudioObjectID> = []
    private var observedDevices: Set<AudioObjectID> = []
    private var outputDevice = AudioObjectID.unknown
    private var outputDeviceUID: String?
    private var refreshIsScheduled = false

    private let defaults = UserDefaults.standard
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "AppVolume"
    private lazy var log = Logger(subsystem: ownBundleID, category: "audio")

    private enum Key {
        static let settings = "AppSettings"
        static let didConfigureLoginItem = "DidConfigureLoginItem"
    }

    // MARK: - Lebenszyklus

    func start() {
        loadSettings()

        AudioObjectID.system.observe(kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.setNeedsRefresh() }
        AudioObjectID.system.observe(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.outputDeviceChanged() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setNeedsRefresh() }
        }

        updateOutputDevice()
        configureLoginItemOnFirstLaunch()
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        refresh()
        log.notice("Started. Permission: \(String(describing: self.permission), privacy: .public), launch at login: \(self.launchesAtLogin), output: \(self.outputDeviceUID ?? "none", privacy: .public)")

        if permission == .undetermined {
            AudioCapturePermission.request { [weak self] in self?.updatePermission() }
        }
    }

    /// Beim Beenden alle Taps freigeben, damit jede App sofort wieder unverändert spielt.
    func stop() {
        taps.values.forEach { $0.invalidate() }
        taps.removeAll()
    }

    /// Das Popover wurde geöffnet: Dinge nachziehen, die außerhalb der App geändert werden können.
    func popoverDidOpen() {
        updatePermission()
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Bedienung

    func setting(for id: String) -> AppSetting {
        settings[id] ?? AppSetting()
    }

    func setVolume(_ volume: Double, for id: String) {
        // Den Regler zu bewegen hebt die Stummschaltung auf, wie beim Systemregler.
        store(AppSetting(volume: min(max(volume, 0), 1), isMuted: false), for: id)
    }

    func toggleMute(for id: String) {
        var setting = setting(for: id)
        setting.isMuted.toggle()
        store(setting, for: id)
    }

    /// Während der Regler gezogen wird, bleibt der Tap bestehen – auch wenn er kurz 100 % überstreicht.
    func setEditing(_ isEditing: Bool, for id: String) {
        if isEditing {
            editing.insert(id)
        } else {
            editing.remove(id)
            reconcileTaps()
        }
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Einstellungen

    private func store(_ setting: AppSetting, for id: String) {
        guard setting != self.setting(for: id) else { return }
        settings[id] = setting.isDefault ? nil : setting
        // Nur Abweichungen vom Standard speichern.
        defaults.set(settings.mapValues { ["volume": $0.volume, "muted": $0.isMuted] as [String: Any] }, forKey: Key.settings)
        reconcileTaps()
    }

    private func loadSettings() {
        guard let stored = defaults.dictionary(forKey: Key.settings) else { return }
        for (id, value) in stored {
            guard let entry = value as? [String: Any] else { continue }
            let volume = (entry["volume"] as? Double) ?? 1
            let setting = AppSetting(volume: min(max(volume, 0), 1), isMuted: (entry["muted"] as? Bool) ?? false)
            if !setting.isDefault { settings[id] = setting }
        }
    }

    /// Autostart beim ersten Start einschalten – aber nur aus einem Programme-Ordner heraus,
    /// damit der Login-Eintrag nicht auf ein Disk-Image oder Build-Verzeichnis zeigt.
    private func configureLoginItemOnFirstLaunch() {
        guard !defaults.bool(forKey: Key.didConfigureLoginItem),
              Bundle.main.bundlePath.contains("/Applications/") else { return }
        defaults.set(true, forKey: Key.didConfigureLoginItem)
        setLaunchesAtLogin(true)
    }

    private func updatePermission() {
        let status = AudioCapturePermission.status
        guard status != permission else { return }
        permission = status
        log.notice("Permission: \(String(describing: status), privacy: .public)")
        reconcileTaps()
    }

    // MARK: - Audio-Apps ermitteln

    /// Mehrere Systemmeldungen in Folge (z. B. beim Start einer App) lösen nur eine Aktualisierung aus.
    private func setNeedsRefresh() {
        guard !refreshIsScheduled else { return }
        refreshIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshIsScheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        let processes = AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyProcessObjectList)
        var groups: [String: ProcessGroup] = [:]

        for process in processes.sorted() {
            if observedProcesses.insert(process).inserted {
                // Gemessen unter macOS 26.2: „IsRunningOutput" allein wird nicht bei jedem Wechsel
                // gemeldet (z. B. nicht beim ersten Start eines neuen Prozesses), „IsRunning" schon.
                for selector in [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningOutput] {
                    process.observe(selector) { [weak self] in self?.setNeedsRefresh() }
                }
            }
            let pid = process.read(kAudioProcessPropertyPID, default: pid_t(-1))
            guard pid > 0, let app = owningApp(of: pid), let id = app.bundleIdentifier, id != ownBundleID else { continue }
            var group = groups[id] ?? ProcessGroup(app: app)
            group.processes.append(process)
            if process.read(kAudioProcessPropertyIsRunning, default: UInt32(0)) != 0 { group.isRunning = true }
            if process.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0 { group.isPlaying = true }
            groups[id] = group
        }
        observedProcesses.formIntersection(processes)
        self.groups = groups

        // Sichtbar: normale Apps mit Audio-Anbindung; Hintergrund-Apps nur, solange sie spielen
        // oder angepasst sind; außerdem laufende Apps mit gespeicherter Einstellung.
        var visible: [String: NSRunningApplication] = [:]
        for (id, group) in groups where group.app.activationPolicy == .regular || group.isPlaying || settings[id] != nil {
            visible[id] = group.app
        }
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, settings[id] != nil, visible[id] == nil { visible[id] = app }
        }
        let apps = visible
            .map { id, app in
                AudioApp(id: id, name: app.localizedName ?? id, icon: app.icon ?? NSWorkspace.shared.icon(for: .application))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if apps.map(\.id) != self.apps.map(\.id) || apps.map(\.name) != self.apps.map(\.name) {
            self.apps = apps
        }

        reconcileTaps()
    }

    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

    /// Liefert zu einem Prozess die Anwendung, zu der er gehört. Helper-Prozesse (Browser-Tabs,
    /// WebKit, Electron) meldet macOS über ihren „verantwortlichen" Prozess; dafür gibt es keine
    /// öffentliche API, deshalb wird die Funktion zur Laufzeit gesucht. Fehlt sie, bleibt der
    /// Weg über die Elternprozesse.
    private static let responsiblePID: ResponsiblePIDFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    private func owningApp(of pid: pid_t) -> NSRunningApplication? {
        var candidate = pid
        if let responsible = Self.responsiblePID?(pid), responsible > 0 { candidate = responsible }
        for _ in 0..<8 where candidate > 1 {
            if let app = NSRunningApplication(processIdentifier: candidate), app.bundleIdentifier != nil { return app }
            candidate = Self.parentPID(of: candidate)
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    // MARK: - Taps

    /// Ein Tap existiert nur für Apps, deren Einstellung vom Standard abweicht. Alle anderen bleiben unberührt.
    private func wantsTap(_ id: String) -> Bool {
        guard permission == .authorized, outputDeviceUID != nil, groups[id] != nil else { return false }
        return settings[id] != nil || editing.contains(id)
    }

    /// Gleicht die aktiven Taps mit Einstellungen, laufenden Prozessen und Ausgabegerät ab.
    /// - Parameter takingOver: false, wenn bestehende Taps ersetzt werden (Gerätewechsel) –
    ///   die Apps sind dann bereits stumm und es gibt nichts nahtlos zu übernehmen.
    private func reconcileTaps(takingOver: Bool = true) {
        for id in Array(taps.keys) where !wantsTap(id) {
            removeTap(id)
        }
        guard let outputDeviceUID else { return }

        for (id, group) in groups where wantsTap(id) {
            let setting = setting(for: id)
            // Wiedergabe nur, solange die App Audio betreibt und etwas zu hören wäre.
            let shouldRun = group.isRunning && (setting.gain > 0 || editing.contains(id))
            do {
                if let tap = taps[id] {
                    try tap.setProcesses(group.processes)
                } else {
                    taps[id] = try AppTap(
                        name: "AppVolume: \(id)",
                        processes: group.processes,
                        outputDeviceUID: outputDeviceUID,
                        gain: setting.gain,
                        takingOver: takingOver && shouldRun
                    )
                    log.notice("Tap created for \(id, privacy: .public): \(group.processes.count) process(es), volume \(setting.volume), muted \(setting.isMuted)")
                }
                taps[id]?.gain = setting.gain
                try taps[id]?.setRunning(shouldRun)
            } catch {
                // Im Fehlerfall die App lieber unverändert spielen lassen als stumm.
                log.error("Tap for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                removeTap(id)
            }
        }
    }

    private func removeTap(_ id: String) {
        guard let tap = taps.removeValue(forKey: id) else { return }
        tap.invalidate()
        log.notice("Tap removed for \(id, privacy: .public)")
    }

    // MARK: - Ausgabegerät

    private func updateOutputDevice() {
        outputDevice = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID.unknown)
        // Selbst angelegte Sammelgeräte (Hauptgerät, Gerät mit mehreren Ausgängen) liefern am Tap
        // keinen Ton (gemessen). Dort wird nicht eingegriffen, die Apps spielen unverändert.
        let isAggregate = outputDevice.read(kAudioDevicePropertyTransportType, default: UInt32(0)) == kAudioDeviceTransportTypeAggregate
        outputDeviceUID = outputDevice == .unknown || isAggregate ? nil : outputDevice.readString(kAudioDevicePropertyDeviceUID)

        // Ändert das Gerät seine Abtastrate (z. B. Bluetooth-Kopfhörer im Gesprächsmodus),
        // werden die Taps ebenfalls neu aufgebaut.
        observedDevices.formIntersection(AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyDevices))
        if outputDevice != .unknown, observedDevices.insert(outputDevice).inserted {
            let device = outputDevice
            device.observe(kAudioDevicePropertyNominalSampleRate) { [weak self] in
                if self?.outputDevice == device { self?.outputDeviceChanged() }
            }
        }
    }

    /// Kopfhörer, Bluetooth, externe Lautsprecher: Taps auf dem neuen Gerät neu aufbauen.
    /// Die alten Taps werden erst danach freigegeben, damit keine App zwischendurch laut wird.
    private func outputDeviceChanged() {
        updateOutputDevice()
        log.notice("Output device: \(self.outputDeviceUID ?? "none", privacy: .public)")
        let previous = taps
        taps.removeAll()
        reconcileTaps(takingOver: false)
        previous.values.forEach { $0.invalidate() }
    }
}
