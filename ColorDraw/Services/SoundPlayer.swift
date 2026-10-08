import AVFoundation
import Foundation

/// Plays little synthesized sounds, so the app needs no audio files. Paint colors play the notes
/// of a pentatonic scale (repeating after ten colors), which makes painting sound like playing a
/// xylophone; any mix of notes sounds pleasant.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    static let enabledKey = "soundEnabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private let engine = AVAudioEngine()
    private let speech = AVSpeechSynthesizer()
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var isSetUp = false
    private var voicesAttached = false
    private var lastNote = Date.distantPast

    private lazy var notes: [AVAudioPCMBuffer] = {
        // C major pentatonic, two octaves up from C5.
        let frequencies: [Double] = [523.25, 587.33, 659.25, 783.99, 880.00, 1046.50, 1174.66, 1318.51, 1567.98, 1760.00]
        return frequencies.map { makeBuffer([(frequency: $0, start: 0, length: 0.45)], volume: 0.32) }
    }()

    private lazy var chime = makeBuffer([(1046.50, 0, 0.35), (1318.51, 0.09, 0.35), (1567.98, 0.18, 0.6)], volume: 0.3)
    private lazy var fanfare = makeBuffer(
        [(523.25, 0, 0.3), (659.25, 0.12, 0.3), (783.99, 0.24, 0.3), (1046.50, 0.36, 0.45),
         (783.99, 0.6, 0.9), (1046.50, 0.6, 0.9), (1318.51, 0.6, 0.9)],
        volume: 0.24
    )
    private lazy var oops = makeBuffer([(392.00, 0, 0.18), (329.63, 0.12, 0.3)], volume: 0.2)
    private lazy var tick = makeBuffer([(1568.0, 0, 0.08)], volume: 0.12)

    private init() {}

    func playPaint(colorIndex: Int) {
        // A stroke across many shapes would otherwise turn into a buzz.
        guard Date().timeIntervalSince(lastNote) > 0.07 else { return }
        lastNote = Date()
        play(notes[colorIndex % notes.count])
    }

    /// Says a short phrase out loud, for children who can't read yet. Returns whether it spoke.
    @discardableResult
    func say(_ text: String) -> Bool {
        guard isEnabled, setUpIfNeeded() else { return false }
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        utterance.pitchMultiplier = 1.25
        speech.speak(utterance)
        return true
    }

    func playColorDone() { play(chime) }
    func playPictureDone() { play(fanfare) }
    func playOops() { play(oops) }
    func playTick() { play(tick) }

    private func play(_ buffer: AVAudioPCMBuffer) {
        guard isEnabled, setUpIfNeeded() else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        voice.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !voice.isPlaying { voice.play() }
    }

    /// Gets the audio engine going ahead of the first sound, so the first stroke doesn't stutter.
    func prepare() {
        guard isEnabled else { return }
        _ = setUpIfNeeded()
    }

    private func setUpIfNeeded() -> Bool {
        if isSetUp { return true }
        do {
            // Ambient: mixes with other audio and respects the silent switch.
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            if !voicesAttached {
                for _ in 0..<6 {
                    let voice = AVAudioPlayerNode()
                    engine.attach(voice)
                    engine.connect(voice, to: engine.mainMixerNode, format: format)
                    voices.append(voice)
                }
                voicesAttached = true
            }
            try engine.start()
            isSetUp = true
        } catch {
            // Audio can be busy (say, during a phone call); try again next time.
            return false
        }
        return true
    }

    /// Renders bell-like tones with a quick attack and a soft exponential decay.
    private func makeBuffer(_ tones: [(frequency: Double, start: Double, length: Double)], volume: Float) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let duration = tones.map { $0.start + $0.length }.max() ?? 0.1
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) { samples[i] = 0 }
        for tone in tones {
            let first = Int(tone.start * sampleRate)
            let count = min(Int(tone.length * sampleRate), Int(frameCount) - first)
            guard count > 0 else { continue }
            for n in 0..<count {
                let t = Double(n) / sampleRate
                let attack = min(1, t / 0.006)
                let decay = exp(-t / (tone.length * 0.28))
                let phase = 2 * Double.pi * tone.frequency * t
                let wave = sin(phase) + 0.28 * sin(2 * phase) + 0.08 * sin(3 * phase)
                samples[first + n] += Float(wave * attack * decay) * volume
            }
        }
        for i in 0..<Int(frameCount) { samples[i] = max(-1, min(1, samples[i])) }
        return buffer
    }
}
