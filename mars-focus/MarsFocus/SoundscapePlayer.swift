import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// Ambient focus sounds, synthesized on the fly (no bundled audio needed):
/// white noise, a rain-like filtered noise, and a deep brown rumble.
@MainActor
final class SoundscapePlayer: ObservableObject {
    enum Sound: String, CaseIterable, Identifiable {
        case off = "Off"
        case rain = "Rain"
        case white = "White"
        case deep = "Deep"

        var id: String { rawValue }
    }

    @Published private(set) var current: Sound = .off

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let generator = NoiseGenerator()

    func select(_ sound: Sound) {
        current = sound
        guard sound != .off else { stop(); return }
        generator.mode = sound
        startEngineIfNeeded()
    }

    func stop() {
        current = .off
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startEngineIfNeeded() {
        guard sourceNode == nil else {
            if !engine.isRunning { try? engine.start() }
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let generator = self.generator
        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            generator.render(frameCount: frameCount, into: audioBufferList)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode,
                       format: engine.outputNode.inputFormat(forBus: 0))
        engine.mainMixerNode.outputVolume = 0.28
        sourceNode = node
        try? engine.start()
    }
}

/// Runs on the realtime audio thread — keep it allocation-free and simple.
final class NoiseGenerator: @unchecked Sendable {
    var mode: SoundscapePlayer.Sound = .white

    private var seed: UInt64 = 0x9E3779B97F4A7C15
    private var lowPass: Float = 0
    private var brown: Float = 0

    func render(frameCount: AVAudioFrameCount, into audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let mode = self.mode
        for frame in 0..<Int(frameCount) {
            // xorshift64 — fast, allocation-free randomness for the DSP thread.
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            let white = Float(seed & 0xFFFFFF) / Float(0xFFFFFF) * 2 - 1
            let sample: Float
            switch mode {
            case .white:
                sample = white * 0.35
            case .rain:
                // Softened noise with a light patter of the raw signal on top.
                lowPass += 0.06 * (white - lowPass)
                sample = lowPass * 1.6 + white * 0.06
            case .deep:
                // Brown noise: integrated white, gently leaked to stay bounded.
                brown = (brown + 0.02 * white) * 0.998
                sample = brown * 3.2
            case .off:
                sample = 0
            }
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                data.assumingMemoryBound(to: Float.self)[frame] = sample
            }
        }
    }
}
