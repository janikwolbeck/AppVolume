// Erzeugt AppVolume/AppIcon.icns in allen benötigten Größen.
// Aufruf aus dem Projektordner:  swift Scripts/make-icon.swift
import AppKit
import SwiftUI

/// Icon im macOS-Raster: 1024er-Fläche, abgerundetes Quadrat 824 × 824 mit Schlagschatten.
struct IconView: View {
    private let knobPositions: [CGFloat] = [0.66, 0.30, 0.52]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.36, green: 0.72, blue: 1.0), Color(red: 0.16, green: 0.30, blue: 0.92)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(
                    // feine Lichtkante oben, wie bei aktuellen System-Icons
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)], startPoint: .top, endPoint: .center), lineWidth: 6))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 12)

            VStack(spacing: 96) {
                ForEach(knobPositions, id: \.self) { position in
                    slider(position: position)
                }
            }
        }
        .frame(width: 824, height: 824)
        .frame(width: 1024, height: 1024)
    }

    private func slider(position: CGFloat) -> some View {
        let width: CGFloat = 560, knob: CGFloat = 116
        let center = knob / 2 + (width - knob) * position
        return ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.32)).frame(width: width, height: 40)
            Capsule().fill(.white).frame(width: center, height: 40)
            Circle()
                .fill(.white)
                .frame(width: knob, height: knob)
                .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
                .offset(x: center - knob / 2)
        }
        .frame(width: width, height: knob)
    }
}

@MainActor
func png(pixels: Int) -> Data {
    let renderer = ImageRenderer(content: IconView())
    renderer.scale = CGFloat(pixels) / 1024
    guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("Icon konnte nicht gerendert werden")
    }
    return data
}

@MainActor
func makeIcon() throws {
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", "AppVolume/AppIcon.icns"]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { fatalError("iconutil fehlgeschlagen") }
    print("AppVolume/AppIcon.icns erzeugt")
}

try MainActor.assumeIsolated { try makeIcon() }
