import CoreAudio
import Foundation

/// Regelt die Lautstärke einer App mit zwei Core-Audio-Process-Taps:
/// - Der Lese-Tap greift ab, was die Prozesse der App auf dem Ausgabegerät spielen. Ein privates
///   Aggregate Device (Ausgabegerät + Lese-Tap) gibt diesen Ton mit eigener Verstärkung wieder aus.
/// - Der Stumm-Tap schaltet die Direktausgabe der App auf diesem Gerät stumm. Das greift erst,
///   wenn er in einem Aggregate Device steckt (gemessen unter macOS 26.2) – deshalb bekommt er
///   ein eigenes, das nie gestartet wird und keine CPU kostet.
/// Die Trennung erlaubt es, die Direktausgabe unabhängig von unserer Wiedergabe stummzuschalten:
/// beim Übernehmen ohne Lücke, und dauerhaft, auch wenn unsere Wiedergabe gerade pausiert.
///
/// Alle Methoden werden auf dem Main-Thread aufgerufen; nur `render` läuft auf dem Audio-Thread.
final class AppTap {
    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed (OSStatus \(status))" }
    }

    /// Wird vom Main-Thread (target) und vom Audio-Thread (beide Felder) verwendet.
    /// Ein einzelner ausgerichteter Float-Schreibzugriff ist auf arm64/x86_64 unteilbar,
    /// deshalb reicht das ohne Lock – Locks sind auf dem Audio-Thread tabu.
    private struct RenderState {
        var target: Float32
        var current: Float32
    }

    /// Verstärkung 0…1. Der Audio-Thread blendet innerhalb eines Puffers (~5 ms) dorthin über.
    var gain: Float {
        didSet { state.pointee.target = gain }
    }

    private let readDescription: CATapDescription
    private let muteDescription: CATapDescription
    private let state: UnsafeMutablePointer<RenderState>
    private var readTapID = AudioObjectID.unknown
    private var muteTapID = AudioObjectID.unknown
    private var muteAggregateID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    private var isTakingOver: Bool
    private var pendingStop: DispatchWorkItem?

    /// - Parameter takingOver: Die App spielt gerade hörbar. Ihre Direktausgabe verstummt dann
    ///   erst, sobald unsere Wiedergabe läuft – so entsteht beim Übernehmen keine Lücke.
    ///   Sonst ist die Direktausgabe sofort stumm, auch wenn unsere Wiedergabe noch nicht läuft.
    init(name: String, processes: [AudioObjectID], outputDeviceUID: String, gain: Float, takingOver: Bool) throws {
        self.gain = gain
        isTakingOver = takingOver
        state = .allocate(capacity: 1)
        state.initialize(to: RenderState(target: gain, current: 0))

        // Taps direkt am Stream des Ausgabegeräts: gleiches Format und gleicher Takt wie das Gerät.
        // Das hält die Verzögerung klein (gemessen ~13 ms statt ~70 ms beim Stereo-Mixdown-Tap)
        // und lässt Ton unberührt, den die App auf einem anderen Gerät ausgibt.
        readDescription = CATapDescription(processes: processes, deviceUID: outputDeviceUID, stream: 0)
        readDescription.name = name
        readDescription.isPrivate = true
        readDescription.muteBehavior = .unmuted

        muteDescription = CATapDescription(processes: processes, deviceUID: outputDeviceUID, stream: 0)
        muteDescription.name = name
        muteDescription.isPrivate = true
        muteDescription.muteBehavior = .muted

        do {
            if !takingOver { try muteDirectOutput() }
            try build(name: name, outputDeviceUID: outputDeviceUID)
        } catch {
            invalidate()
            throw error
        }
    }

    deinit {
        invalidate()
        state.deallocate()
    }

    private func build(name: String, outputDeviceUID: String) throws {
        var status = AudioHardwareCreateProcessTap(readDescription, &readTapID)
        guard status == noErr else { throw Failure(step: "create tap", status: status) }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: readDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
        guard status == noErr else { throw Failure(step: "create aggregate device", status: status) }

        // `render` rechnet mit verschachtelten 32-Bit-Float-Samples (HAL-Standard). Bei allem
        // anderen lieber gar nicht eingreifen, als Störgeräusche auszugeben.
        let streams = aggregateID.readObjectIDs(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            + aggregateID.readObjectIDs(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        for stream in streams {
            let format = stream.read(kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
            let isInterleavedFloat32 = format.mFormatID == kAudioFormatLinearPCM
                && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                && format.mBitsPerChannel == 32
            guard isInterleavedFloat32 else { throw Failure(step: "check stream format", status: kAudioDeviceUnsupportedFormatError) }
        }

        // Kleiner Puffer für geringe Verzögerung. Schlägt das fehl, gilt die Standardgröße.
        var bufferFrames: UInt32 = 256
        var bufferAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(aggregateID, &bufferAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferFrames)

        // Der Block darf nur den rohen Zeiger festhalten: kein self, keine Swift-Objekte auf dem Audio-Thread.
        let state = self.state
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            AppTap.render(input: input, output: output, state: state)
        }
        guard status == noErr, ioProcID != nil else { throw Failure(step: "create IO proc", status: status) }
    }

    /// Ersetzt die abgegriffenen Prozesse, ohne die Taps neu aufzubauen (z. B. neuer Browser-Helper).
    func setProcesses(_ processes: [AudioObjectID]) throws {
        guard processes != readDescription.processes else { return }
        readDescription.processes = processes
        muteDescription.processes = processes
        try apply(muteDescription, to: muteTapID)
        try apply(readDescription, to: readTapID)
    }

    /// Startet oder stoppt die Wiedergabe. Gestoppt bleibt die Direktausgabe der App stumm,
    /// es läuft aber kein Audio-Thread mehr – so kostet eine stille App keine CPU.
    func setRunning(_ shouldRun: Bool) throws {
        pendingStop?.cancel()
        pendingStop = nil

        if shouldRun {
            guard !isRunning else { return }
            // Bei der Übernahme von voller Lautstärke aus überblenden, sonst kurz einblenden.
            state.pointee.current = isTakingOver ? 1 : 0
            isTakingOver = false
            let status = AudioDeviceStart(aggregateID, ioProcID)
            guard status == noErr else { throw Failure(step: "start playback", status: status) }
            isRunning = true
        } else if isRunning {
            // Kurz nachlaufen lassen, damit die Rampe auf 0 ausklingt und kurze Pausen
            // der App keinen Neustart der Wiedergabe kosten.
            let stop = DispatchWorkItem { [weak self] in self?.stop() }
            pendingStop = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: stop)
        }
        isTakingOver = false
        try muteDirectOutput()
    }

    /// Gibt alle Core-Audio-Objekte frei. Danach spielt die App wieder direkt und unverändert.
    func invalidate() {
        pendingStop?.cancel()
        pendingStop = nil
        // Erst die Direktausgabe freigeben, dann unsere Wiedergabe beenden: lieber wenige
        // Millisekunden Überlappung als eine Lücke.
        if muteAggregateID != .unknown {
            AudioHardwareDestroyAggregateDevice(muteAggregateID)
            muteAggregateID = .unknown
        }
        if muteTapID != .unknown {
            AudioHardwareDestroyProcessTap(muteTapID)
            muteTapID = .unknown
        }
        if let ioProcID {
            stop()
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != .unknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if readTapID != .unknown {
            AudioHardwareDestroyProcessTap(readTapID)
            readTapID = .unknown
        }
    }

    private func stop() {
        guard isRunning else { return }
        AudioDeviceStop(aggregateID, ioProcID)
        isRunning = false
    }

    /// Schaltet die Direktausgabe der App auf dem Ausgabegerät stumm.
    private func muteDirectOutput() throws {
        guard muteTapID == .unknown else { return }
        var status = AudioHardwareCreateProcessTap(muteDescription, &muteTapID)
        guard status == noErr else { throw Failure(step: "create mute tap", status: status) }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: muteDescription.name,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: muteDescription.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &muteAggregateID)
        guard status == noErr else { throw Failure(step: "mute direct output", status: status) }
    }

    private func apply(_ description: CATapDescription, to tapID: AudioObjectID) throws {
        guard tapID != .unknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var reference = Unmanaged.passUnretained(description)
        let size = UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size)
        let status = AudioObjectSetPropertyData(tapID, &address, 0, nil, size, &reference)
        guard status == noErr else { throw Failure(step: "update tap", status: status) }
    }

    /// Audio-Thread: kopiert den Tap-Stream mit Verstärkung auf das Ausgabegerät.
    /// Keine Allokationen, keine Locks, keine Objective-C-Aufrufe.
    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        state: UnsafeMutablePointer<RenderState>
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let start = state.pointee.current
        let end = state.pointee.target
        state.pointee.current = end
        guard start != 0 || end != 0 else { return }

        // Die Streams des Ausgabegeräts (z. B. das Mikrofon eines Headsets) kommen zuerst,
        // der Tap-Stream ist immer der letzte Eingangspuffer.
        guard !inputs.isEmpty else { return }
        let source = inputs[inputs.count - 1]
        let sourceChannels = Int(source.mNumberChannels)
        guard let sourceData = source.mData, sourceChannels > 0 else { return }
        let sourceSamples = sourceData.assumingMemoryBound(to: Float32.self)
        let sourceFrames = Int(source.mDataByteSize) / (sourceChannels * MemoryLayout<Float32>.size)

        var firstChannel = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            defer { firstChannel += channels }
            guard let data = buffer.mData, channels > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float32.self)
            let frames = min(sourceFrames, Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float32>.size))
            guard frames > 0 else { continue }
            let step = (end - start) / Float32(frames)

            // Der Tap hat das Format des Geräte-Streams, die Kanäle werden 1:1 übernommen.
            for channel in 0..<channels where firstChannel + channel < sourceChannels {
                let sourceChannel = firstChannel + channel
                var gain = start
                for frame in 0..<frames {
                    gain += step
                    samples[frame * channels + channel] = sourceSamples[frame * sourceChannels + sourceChannel] * gain
                }
            }
        }
    }
}
