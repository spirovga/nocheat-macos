import AVFoundation
import CoreAudio

/// Stream channel ids, matching the backend protocol.
enum Channel: UInt8 {
    case interviewer = 0  // microphone
    case candidate = 1    // call audio played by this Mac
}

/// Converts whatever the device delivers to PCM16LE, 16 kHz, mono.
final class PCMConverter {
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: output)
            // Voice processing can deliver extra channels; the first one carries the cleaned-up voice.
            if buffer.format.channelCount > 2 { converter?.channelMap = [0] }
        }
        guard let converter, buffer.frameLength > 0 else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: Int(out.frameLength) * 2)
    }
}

/// Microphone: the interviewer's own voice.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let converter = PCMConverter()

    func start(onAudio: @escaping (Data) -> Void) throws {
        let input = engine.inputNode
        // Echo cancellation: without headphones the microphone also hears the candidate coming out
        // of the speakers. Voice processing subtracts what this Mac is playing from the mic signal,
        // so the candidate's words are not transcribed a second time as the interviewer's.
        try input.setVoiceProcessingEnabled(true)
        // Voice processing lowers other apps' volume by default; keep the call at normal loudness.
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CaptureError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 4800, format: format) { [converter] buffer, _ in
            if let data = converter.convert(buffer) { onAudio(data) }
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// System audio through a Core Audio process tap: what this Mac plays, i.e. the candidate's voice
/// in the call. It needs only the "System Audio Recording" permission; nothing on screen is captured.
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let converter = PCMConverter()
    private let queue = DispatchQueue(label: "anticheating.system-audio")
    private let lock = NSLock()
    private var sound = false

    /// True once the tap has delivered anything but digital silence. Without the System Audio
    /// Recording permission macOS still runs the tap but feeds it zeros, and reports no error.
    var heardSound: Bool { lock.withLock { sound } }

    func start(onAudio: @escaping (Data) -> Void) throws {
        lock.withLock { sound = false }
        // A tap on everything the system plays (this app itself plays nothing).
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.uuid = UUID()
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(tap, &tapID))

        // A tap is read through a private aggregate device that contains only the tap. It must not
        // include the output device: the microphone's voice processing takes that device over, and
        // an aggregate built around it then stops delivering audio.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Human or AI tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        do {
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID))

            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd))
            guard let format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError.systemAudio(0) }

            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [converter, weak self] _, input, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                      let data = converter.convert(buffer) else { return }
                if let self, !self.heardSound, data.contains(where: { $0 != 0 }) { self.lock.withLock { self.sound = true } }
                onAudio(data)
            })
            try check(AudioDeviceStart(deviceID, procID))
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw CaptureError.systemAudio(status) }
    }
}

enum CaptureError: LocalizedError {
    case noMicrophone, microphoneDenied
    case systemAudio(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "No microphone found."
        case .systemAudio(let code): "Could not capture the call audio (error \(code)). Allow it in System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only, then start again."
        case .microphoneDenied: "Microphone access is off. Enable it in System Settings › Privacy & Security › Microphone."
        }
    }
}
