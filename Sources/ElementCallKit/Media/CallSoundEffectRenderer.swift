//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Synchronization

/// A short cue mixed over the call, as opposed to the call's own audio.
nonisolated enum CallSoundEffect: CaseIterable, Sendable {
    case join, leave
}

/// The call's sound effects' render path: one source node on the call's own engine, so they go
/// wherever the call's audio goes, at the call's volume, mixed over the voices rather than
/// interrupting them. A separate player would have its own route and volume and follow the ringer
/// switch, which is what spec 024 rules out (R10, R14, R15, R16).
///
/// Built like ``AudioPlaybackRenderer``: it owns its render block, cannot reach the engine, and
/// renders without one in tests. One voice per effect, so a join and a leave close together overlap
/// instead of cutting each other off.
final nonisolated class CallSoundEffectRenderer: @unchecked Sendable {
    /// Web's default effect volume, relative to the call (R14).
    static let gain: Float = 0.5
    
    private let join: Voice
    private let leave: Voice
    
    init(join: [Float], leave: [Float]) {
        self.join = Voice(join)
        self.leave = Voice(leave)
    }
    
    /// From any thread. Restarts that sound from its beginning on the next render.
    func play(_ sound: CallSoundEffect) {
        voice(for: sound).trigger()
    }
    
    /// The block handed to the engine. It captures the renderer and nothing else.
    var renderBlock: AVAudioSourceNodeRenderBlock {
        { [self] _, _, frameCount, audioBufferList in
            render(frameCount: frameCount, audioBufferList: audioBufferList)
        }
    }
    
    /// Runs on the real-time thread: no allocation, no locks, no engine.
    func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let first = buffers.first, let data = first.mData else { return noErr }
        let output = data.assumingMemoryBound(to: Float.self)
        let count = Int(frameCount)
        for index in 0..<count {
            output[index] = 0
        }
        join.mix(into: output, count: count)
        leave.mix(into: output, count: count)
        for index in 0..<count {
            output[index] = min(1, max(-1, output[index]))
        }
        return noErr
    }
    
    private func voice(for sound: CallSoundEffect) -> Voice {
        switch sound {
        case .join: join
        case .leave: leave
        }
    }
    
    /// One sound. The trigger crosses threads as a generation count; the playhead belongs to the
    /// render thread alone, which notices a new generation and starts over.
    private final class Voice: @unchecked Sendable {
        private let samples: UnsafeMutableBufferPointer<Float>
        private let requested = Atomic<UInt32>(0)
        // Render thread only.
        private var started: UInt32 = 0
        private var playhead: Int
        
        init(_ source: [Float]) {
            samples = .allocate(capacity: source.count)
            _ = samples.initialize(from: source)
            // At the end: silent until first triggered.
            playhead = source.count
        }
        
        deinit {
            samples.deallocate()
        }
        
        func trigger() {
            requested.wrappingAdd(1, ordering: .relaxed)
        }
        
        func mix(into output: UnsafeMutablePointer<Float>, count: Int) {
            let generation = requested.load(ordering: .relaxed)
            if generation != started {
                started = generation
                playhead = 0
            }
            let available = min(count, samples.count - playhead)
            guard available > 0 else { return }
            for index in 0..<available {
                output[index] += samples[playhead + index] * CallSoundEffectRenderer.gain
            }
            playhead += available
        }
    }
}

// MARK: - The bundled sounds

nonisolated extension CallSoundEffectRenderer {
    /// A renderer over the bundled files, or nil if they could not be decoded, which is logged: a
    /// call without its join sound is still a call.
    static func bundled() -> CallSoundEffectRenderer? {
        guard let samples = bundledSamples else { return nil }
        return CallSoundEffectRenderer(join: samples.join, leave: samples.leave)
    }
    
    /// Decoded once per process, on first use, and shared by every call after it.
    private static let bundledSamples: (join: [Float], leave: [Float])? = {
        do {
            return try (decode(resource: "join_call"), decode(resource: "left_call"))
        } catch {
            MatrixRTCLog.error("Failed to decode the call sounds: \(error)")
            return nil
        }
    }()
    
    static func decode(resource: String) throws -> [Float] {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "mp3", subdirectory: "Sounds") else {
            throw MatrixRTCError.media("\(resource).mp3 is not in the bundle")
        }
        return try decode(url: url)
    }
    
    /// To the engine's mono Float32. The files are web's, at the engine's own 48 kHz, so this only
    /// averages the channels; a file at any other rate is refused rather than resampled here.
    static func decode(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == AudioFormat.float32.sampleRate, format.commonFormat == .pcmFormatFloat32 else {
            throw MatrixRTCError.media("\(url.lastPathComponent) is \(format), expected \(AudioFormat.float32.sampleRate) Hz Float32")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw MatrixRTCError.media("Could not allocate a buffer for \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw MatrixRTCError.media("\(url.lastPathComponent) decoded without channel data")
        }
        let channelCount = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        let stride = format.isInterleaved ? channelCount : 1
        return (0..<frames).map { frame in
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += format.isInterleaved ? channels[0][frame * stride + channel] : channels[channel][frame]
            }
            return sum / Float(channelCount)
        }
    }
}
