import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AudioModel

    private let maxVisibleRows = 8
    private let rowHeight: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("App Volume")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            if model.permission == .denied {
                PermissionNotice()
            }

            if model.apps.isEmpty {
                Text("No apps with audio")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else if model.apps.count > maxVisibleRows {
                ScrollView { rows }
                    .frame(height: CGFloat(maxVisibleRows) * rowHeight)
            } else {
                rows
            }

            Divider()
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

            Toggle(isOn: Binding(get: { model.launchesAtLogin }, set: model.setLaunchesAtLogin)) {
                Text("Launch at Login")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)

            MenuRow(title: "Quit AppVolume") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 12)
        .frame(width: 300)
        .onAppear(perform: model.popoverDidOpen)
        // Das Popover-Fenster bleibt nach dem ersten Öffnen bestehen; deshalb zusätzlich bei jedem Einblenden.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.popoverDidOpen()
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(model.apps) { app in
                AppRow(app: app, setting: model.setting(for: app.id), model: model)
                    .frame(height: rowHeight)
            }
        }
    }
}

/// Eine App: Icon, Name, Stumm-Button und Lautstärkeregler.
private struct AppRow: View {
    let app: AudioApp
    let setting: AppSetting
    let model: AudioModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(verbatim: app.name)
                        .lineLimit(1)
                    Spacer()
                    Group {
                        if setting.isMuted {
                            Text("Muted")
                        } else {
                            Text(verbatim: setting.volume.formatted(.percent.precision(.fractionLength(0))))
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Button {
                        model.toggleMute(for: app.id)
                    } label: {
                        Image(systemName: setting.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: setting.volume)
                            .frame(width: 20, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(setting.isMuted ? Text("Unmute") : Text("Mute"))
                    .accessibilityLabel(setting.isMuted ? Text("Unmute") : Text("Mute"))

                    Slider(
                        value: Binding(get: { setting.volume }, set: { model.setVolume($0, for: app.id) }),
                        in: 0...1,
                        onEditingChanged: { model.setEditing($0, for: app.id) }
                    )
                    .controlSize(.small)
                    .opacity(setting.isMuted ? 0.5 : 1)
                    .accessibilityLabel(Text(verbatim: app.name))
                }
            }
        }
        .padding(.horizontal, 14)
    }
}

/// Hinweis, wenn die Berechtigung „Systemaudio aufnehmen" abgelehnt wurde.
private struct PermissionNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Permission required", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
            Text("To change the volume of individual apps, allow AppVolume under “System Audio Recording Only” in Privacy & Security.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}

/// Eintrag im Stil einer Menüzeile mit Hervorhebung unter dem Mauszeiger.
private struct MenuRow: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
    }
}
