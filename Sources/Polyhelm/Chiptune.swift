import AVFoundation
import Foundation

/// Synthesized 8-bit event sounds — square waves with a short decay envelope,
/// generated at runtime so the app ships no audio assets.
///
/// Each cue is rendered to a PCM buffer off the audio thread and handed to an
/// `AVAudioPlayerNode`. Nothing locks or allocates during rendering, which is the
/// rule for real-time audio — an earlier version held an `NSLock` inside the
/// render callback and could stall the audio thread behind the main thread.
final class Chiptune {
    static let shared = Chiptune()

    /// Read from the main actor on every event; written only from there too.
    var enabled: Bool {
        get { _enabled.withLock { $0 } }
        set { _enabled.withLock { $0 = newValue } }
    }
    private let _enabled = Mutex(true)

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let sampleRate: Double = 44_100

    /// Cues are identical every time, so render once and replay.
    private var cache: [SessionState: AVAudioPCMBuffer] = [:]
    private let cacheQueue = DispatchQueue(label: "polyhelm.chiptune")

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.22
        // Deliberately NOT started here. A running AVAudioEngine keeps its render
        // and messenger threads alive and burns ~7% CPU around the clock even
        // while rendering pure silence.
    }

    /// Idle teardown. Long enough that a burst of events doesn't thrash the
    /// engine, short enough that a quiet app costs nothing.
    private let idleTimeout: TimeInterval = 5
    private var stopWorkItem: DispatchWorkItem?

    /// Must be called on `cacheQueue`.
    private func ensureRunning() {
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                NSLog("Polyhelm: audio engine failed to start — \(error)")
                return
            }
        }
        if !player.isPlaying { player.play() }

        stopWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.engine.isRunning else { return }
            self.player.stop()
            self.engine.stop()
        }
        stopWorkItem = work
        cacheQueue.asyncAfter(deadline: .now() + idleTimeout, execute: work)
    }

    func play(for state: SessionState) {
        guard enabled, let notes = Self.cue(for: state) else { return }
        cacheQueue.async { [weak self] in
            guard let self else { return }
            let buffer: AVAudioPCMBuffer
            if let cached = self.cache[state] {
                buffer = cached
            } else {
                guard let rendered = self.render(notes) else { return }
                self.cache[state] = rendered
                buffer = rendered
            }
            self.ensureRunning()
            // .interrupts so a burst of events doesn't queue into a traffic jam.
            self.player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        }
    }

    // MARK: - Synthesis

    private typealias Note = (frequency: Double, seconds: Double)

    private static func cue(for state: SessionState) -> [Note]? {
        switch state {
        case .needsInput: return [(660, 0.07), (880, 0.13)]           // rising ask
        case .done:       return [(880, 0.06), (1174, 0.05), (1568, 0.12)]
        case .error:      return [(440, 0.09), (330, 0.16)]           // falling
        case .working:    return [(1046, 0.035)]                      // blip
        case .idle:       return nil
        }
    }

    private func render(_ notes: [Note]) -> AVAudioPCMBuffer? {
        let frames = notes.reduce(0) { $0 + Int(sampleRate * $1.seconds) }
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        var cursor = 0
        for note in notes {
            let count = Int(sampleRate * note.seconds)
            var phase = 0.0
            let increment = 2 * Double.pi * note.frequency / sampleRate
            for frame in 0..<count {
                let progress = Double(frame) / Double(max(count, 1))
                // Short attack avoids a click; linear decay keeps it punchy, not buzzy.
                let attack = progress < 0.02 ? progress / 0.02 : 1
                let envelope = (1 - progress) * attack
                channel[cursor + frame] = Float((sin(phase) >= 0 ? 1.0 : -1.0) * envelope)
                phase += increment
                if phase > 2 * .pi { phase -= 2 * .pi }
            }
            cursor += count
        }
        return buffer
    }
}

/// Tiny lock wrapper so `enabled` is safe to touch from either side.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
