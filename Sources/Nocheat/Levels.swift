import SwiftUI

/// Live loudness of the two audio channels, written from the audio threads and read by the UI
/// on every frame. Values rise instantly and fall off smoothly, like a level meter.
final class LevelStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Channel: (level: Double, at: TimeInterval)] = [:]
    /// Seconds for a level to fall to about a third once the sound stops.
    private let release = 0.22

    /// Feeds a chunk of PCM16 audio.
    func feed(_ channel: Channel, _ pcm: Data) {
        let count = pcm.count / 2
        guard count > 0 else { return }
        let sum: Double = pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).reduce(0) { $0 + Double($1) * Double($1) }
        }
        let rms = (sum / Double(count)).squareRoot() / 32768
        // Speech sits around 0.01–0.2 RMS; the square root spreads that over most of the 0–1 range.
        let level = min(1, rms.squareRoot() * 2.4)
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        values[channel] = (max(level, decayed(channel, now)), now)
        lock.unlock()
    }

    func level(_ channel: Channel) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return decayed(channel, ProcessInfo.processInfo.systemUptime)
    }

    func reset() {
        lock.lock()
        values = [:]
        lock.unlock()
    }

    private func decayed(_ channel: Channel, _ now: TimeInterval) -> Double {
        guard let v = values[channel] else { return 0 }
        return v.level * exp(-(now - v.at) / release)
    }
}

/// The strip above the transcript: who is speaking right now. Candidate on the left and you on
/// the right, matching the sides of the chat bubbles.
struct SpeakerSignals: View {
    let levels: LevelStore

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack {
                Signal(name: "CANDIDATE", level: levels.level(.candidate), time: t, mirrored: false)
                Spacer()
                Signal(name: "YOU", level: levels.level(.interviewer), time: t, mirrored: true)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
    }
}

/// A name and a small waveform. Silent: a row of dots. Speaking: the bars swell with the voice,
/// each moving at its own pace, and the name brightens.
private struct Signal: View {
    let name: String
    let level: Double
    let time: TimeInterval
    let mirrored: Bool

    private static let bars = 7
    /// Below this the channel counts as silent (room noise, residual echo).
    private static let floor = 0.16

    var body: some View {
        let voice = max(0, (level - Self.floor) / (1 - Self.floor))
        let speaking = voice > 0
        HStack(spacing: 8) {
            if mirrored { label(speaking) }
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<Self.bars, id: \.self) { i in
                    Capsule()
                        .fill(Color.primary.opacity(speaking ? 1 : 0.28))
                        .frame(width: 3, height: height(i, voice))
                }
            }
            .frame(height: 22)
            if !mirrored { label(speaking) }
        }
    }

    private func label(_ speaking: Bool) -> some View {
        Text(name)
            .font(.system(size: 9, weight: .medium)).tracking(1)
            .foregroundStyle(Color.primary.opacity(speaking ? 1 : 0.4))
            .animation(.easeOut(duration: 0.25), value: speaking)
    }

    /// Bars are tallest in the middle; each one wobbles on its own rhythm so the shape feels alive.
    private func height(_ i: Int, _ voice: Double) -> CGFloat {
        guard voice > 0 else { return 3 }
        let centre = 1 - abs(Double(i) - Double(Self.bars - 1) / 2) / Double(Self.bars)
        let wobble = 0.62 + 0.38 * sin(time * (7 + Double(i % 3) * 2.3) + Double(i) * 1.7)
        return 3 + CGFloat(19 * min(1, voice * 1.5) * centre * wobble)
    }
}
