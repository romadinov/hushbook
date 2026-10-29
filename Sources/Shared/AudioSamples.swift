import AVFoundation
import Accelerate

enum AudioSamples {
    /// Decodes any audio file into 16 kHz mono Float samples, the input both speech models expect.
    static func load16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw CocoaError(.fileReadCorruptFile) }
        let inCapacity: AVAudioFrameCount = 16_384
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCapacity)!
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024)
        var finished = false
        while true {
            let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384)!
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if finished { outStatus.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: input, frameCount: inCapacity)
                } catch { finished = true; outStatus.pointee = .endOfStream; return nil }
                if input.frameLength == 0 { finished = true; outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            if let data = output.floatChannelData, output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return samples
    }

    /// Phrases of 16 kHz speech, split at pauses of ≥ 0.18 s (energy below an adaptive noise floor).
    /// Phrases shorter than a second join the previous one; none is longer than `maxSeconds`.
    static func phrases(_ samples: [Float], maxSeconds: Double = 25) -> [Range<Int>] {
        let frame = 480   // 30 ms
        let count = samples.count / frame
        guard count > 10 else { return samples.isEmpty ? [] : [0..<samples.count] }
        var rms = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { p in
            for i in 0..<count { vDSP_rmsqv(p.baseAddress! + i * frame, 1, &rms[i], vDSP_Length(frame)) }
        }
        let sorted = rms.sorted()
        let floor = sorted[count / 5], loud = sorted[count * 9 / 10]
        let threshold = floor + (loud - floor) * 0.15
        let minPause = 6    // frames = 0.18 s: sentence breaks, not gaps between words
        var cuts: [Int] = []
        var run = 0
        for i in 0..<count {
            if rms[i] < threshold { run += 1 } else {
                if run >= minPause, i - run > 0 { cuts.append((i - run / 2) * frame) }   // middle of the pause
                run = 0
            }
        }
        var ranges: [Range<Int>] = []
        var start = 0
        for cut in cuts + [samples.count] where cut > start {
            if cut - start < 16_000, let last = ranges.popLast() { ranges.append(last.lowerBound..<cut) }
            else { ranges.append(start..<cut) }
            start = cut
        }
        // Long phrases without pauses: hard-split to the window size.
        let limit = Int(maxSeconds * 16_000)
        return ranges.flatMap { r -> [Range<Int>] in
            stride(from: r.lowerBound, to: r.upperBound, by: limit).map { $0..<min($0 + limit, r.upperBound) }
        }
    }
}
