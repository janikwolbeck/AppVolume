# AppVolume

Per-app volume control for the macOS menu bar. Turn down or mute any running app on its own,
without installing an audio driver.

## Features

- A volume slider (0–100 %) and a mute button for every app that has audio
- Apps with several processes, such as browsers and their helpers, appear as one entry
- Settings are saved per app and applied again after the app or the Mac restarts
- Keeps working when the output device changes (headphones, Bluetooth, external speakers)
- Optional launch at login
- Menu bar only: no Dock icon, no main window
- English and German

## Requirements

- macOS 14.2 or later. Developed and tested on macOS 26.2 on Apple silicon; older versions and
  Intel Macs are untested.
- To build: the Xcode Command Line Tools (`xcode-select --install`). Xcode itself is not needed.

## Install

Clone the repository and run the build script:

```sh
./Scripts/build.sh
```

This creates `build/AppVolume.app` and `build/AppVolume.dmg` for the architecture of the Mac it
runs on. Open the DMG, drag **AppVolume** onto **Applications**, and start it from there. The
slider icon appears in the menu bar.

### Gatekeeper

The app is signed ad hoc and not notarized.

- On the Mac that built it, it opens without a warning.
- If the DMG comes from another Mac (download, AirDrop), macOS blocks the first launch. Close
  the dialog, then go to *System Settings → Privacy & Security* and click **Open Anyway** next
  to AppVolume. Alternatively: `xattr -dr com.apple.quarantine /Applications/AppVolume.app`

## Permission

On first launch macOS asks whether AppVolume may record system audio. Allow it: this is the
only way an app can pick up another app's sound and play it back at a different volume.
Nothing is recorded, stored or sent anywhere.

If you declined, the popover shows a notice with a button that opens the right settings pane:
*Privacy & Security → Screen & System Audio Recording → System Audio Recording Only*.

Because of the ad hoc signature, macOS treats every new build as a different app, so the
permission no longer matches. If volume control stops working after a rebuild and no prompt
appears, run `tccutil reset AudioCapture de.janikwolbeck.AppVolume` and restart the app.

## Usage

- Click the menu bar icon to see all apps with audio.
- Drag a slider to change that app's volume. 50 % on the slider is about half as loud (−12 dB).
- Click the speaker button to mute or unmute. Moving the slider also unmutes.
- **Launch at Login** toggles autostart. It is switched on automatically the first time the app
  starts from an Applications folder.

Apps at 100 % that are not muted are left completely untouched.

## How it works

AppVolume uses Core Audio process taps (`AudioHardwareCreateProcessTap`, available since
macOS 14.2). For each app you adjust, one tap reads what the app plays on the output device,
and a private aggregate device plays it back with the chosen gain. A second tap mutes the
app's direct output.

- Only adjusted apps are tapped, and playback runs only while such an app is running audio.
- Everything is driven by system notifications; there is no polling.
- If AppVolume quits or crashes, macOS removes the taps and every app plays normally again.

Measured on an M2 MacBook Air: under 0.02 % CPU when idle, about 0.2 % while two adjusted apps
are playing, and about 13 ms of added delay for adjusted apps.

Two things have no public API, so AppVolume looks up system functions at runtime: checking
and requesting the audio permission, and finding the app a helper process belongs to. If
either function is missing, the app falls back to simpler behavior. This also means the app
is not suitable for the Mac App Store.

## Limitations

- AppVolume controls what an app plays on the **default output device**. Sound an app sends to
  a different device (for example Zoom using a headset that is not the default) is unchanged.
- Aggregate and multi-output devices created in Audio MIDI Setup are not supported as the
  default output. Apps play unchanged while one is selected.
- On devices with more than one output stream, only the first stream is controlled.
- System sounds do not belong to an app and cannot be controlled.
- When an adjusted app starts playing after silence, roughly the first 25 ms are dropped.

## Uninstall

1. Switch off **Launch at Login** in the popover, then choose **Quit AppVolume**.
2. Delete `AppVolume` from the Applications folder.
3. Optionally remove the saved settings and the permission:

   ```sh
   defaults delete de.janikwolbeck.AppVolume
   tccutil reset AudioCapture de.janikwolbeck.AppVolume
   ```

## Project layout

| Path | Purpose |
| --- | --- |
| `AppVolume/AppVolumeApp.swift` | Entry point, menu bar item |
| `AppVolume/PopoverView.swift` | Popover user interface |
| `AppVolume/AudioModel.swift` | App list, settings, launch at login, tap management |
| `AppVolume/AppTap.swift` | Process taps and gain-controlled playback for one app |
| `AppVolume/AudioCapturePermission.swift` | Audio permission check and request |
| `AppVolume/CoreAudioSupport.swift` | Core Audio helpers |
| `Scripts/build.sh` | Builds the app and the DMG |
| `Scripts/make-icon.swift` | Regenerates `AppIcon.icns` (`swift Scripts/make-icon.swift`) |

Swift and SwiftUI, no external dependencies. The build script is the tested way to build.
`AppVolume.xcodeproj` is included for working on the code in Xcode 15.2 or later, but it has
not been verified in Xcode.
