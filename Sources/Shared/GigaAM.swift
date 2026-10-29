import Foundation
import CoreML
import Accelerate

/// GigaAM v3 end-to-end CTC (Sber, MIT licence): Russian speech recognition with punctuation, run on device through
/// the Core ML conversion at huggingface.co/inhum/gigaam-v3-coreml. The model takes log-mel features of a fixed
/// 25 s window; the feature extractor below reproduces the checkpoint's (n_fft 320, hop 160, 64 HTK mels, no centring)
/// using the filterbank and window tables shipped with the model.
final class GigaAM: @unchecked Sendable {
    static let source = URL(string: "https://huggingface.co/inhum/gigaam-v3-coreml/resolve/main/")!
    static let files = ["gigaam-melfb.f32", "gigaam-vocab.txt", "gigaam-window.f32",
                        "gigaam_v3_e2e.mlpackage/Manifest.json",
                        "gigaam_v3_e2e.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                        "gigaam_v3_e2e.mlpackage/Data/com.apple.CoreML/weights/weight.bin"]
    static let compiledName = "gigaam_v3_e2e.mlmodelc"

    private static let sampleRate = 16_000
    private static let windowSamples = 400_000          // 25 s
    private static let frames = 2499                    // (400000 - 320) / 160 + 1
    private static let nFFT = 320, hop = 160, nMels = 64, nBins = 161
    private static let blank = 256

    private let model: MLModel
    private let melfb: [Float]      // nBins × nMels, row-major
    private let window: [Float]
    private let vocab: [String]
    private let dft: OpaquePointer

    /// `folder` holds the downloaded files; the .mlpackage is compiled once and replaced by the compiled model.
    init(folder: URL) throws {
        let fm = FileManager.default
        let compiled = folder.appendingPathComponent(Self.compiledName)
        if !fm.fileExists(atPath: compiled.path) {
            let package = folder.appendingPathComponent("gigaam_v3_e2e.mlpackage")
            let temp = try MLModel.compileModel(at: package)
            try fm.moveItem(at: temp, to: compiled)
            try? fm.removeItem(at: package)   // 420 MB we no longer need
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: compiled, configuration: config)
        melfb = try Self.floats(folder.appendingPathComponent("gigaam-melfb.f32"))
        window = try Self.floats(folder.appendingPathComponent("gigaam-window.f32"))
        vocab = try String(contentsOf: folder.appendingPathComponent("gigaam-vocab.txt"), encoding: .utf8)
            .components(separatedBy: "\n")
        guard melfb.count == Self.nMels * Self.nBins, window.count == Self.nFFT,
              let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Self.nFFT), .FORWARD) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        dft = setup
    }

    deinit { vDSP_DFT_DestroySetup(dft) }

    static func isInstalled(in folder: URL) -> Bool {
        let fm = FileManager.default
        let model = fm.fileExists(atPath: folder.appendingPathComponent(compiledName).path)
            || fm.fileExists(atPath: folder.appendingPathComponent(files.last!).path)
        return model && files.prefix(3).allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    private static func floats(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { raw in
            (0..<data.count / 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }

    /// Transcribes 16 kHz mono audio of any length, piece by piece.
    func transcribe(_ samples: [Float]) throws -> String {
        try Self.pieces(samples).map { try transcribeWindow(Array(samples[$0])) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// ≤25 s pieces (the model's window), each split at the quietest 100 ms in its last 5 s so words aren't cut.
    static func pieces(_ samples: [Float]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        while start < samples.count {
            var end = min(start + windowSamples, samples.count)
            if end < samples.count { end = quietestSplit(samples, from: start + windowSamples - 5 * sampleRate, to: end) }
            result.append(start..<end)
            start = end
        }
        return result
    }

    private static func quietestSplit(_ s: [Float], from: Int, to: Int) -> Int {
        let step = Self.sampleRate / 10   // 100 ms
        var best = to, bestEnergy = Float.greatestFiniteMagnitude
        var i = from
        while i + step <= to {
            var energy: Float = 0
            s.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + i, 1, &energy, vDSP_Length(step)) }
            if energy < bestEnergy { bestEnergy = energy; best = i + step / 2 }
            i += step
        }
        return best
    }

    /// One piece of at most 25 s.
    func transcribeWindow(_ chunk: [Float]) throws -> String {
        guard chunk.count > Self.nFFT + Self.sampleRate / 10 else { return "" }   // under ~0.1 s
        let realFrames = min((chunk.count - Self.nFFT) / Self.hop + 1, Self.frames)
        let features = try MLMultiArray(shape: [1, NSNumber(value: Self.nMels), NSNumber(value: Self.frames)], dataType: .float32)
        let out = features.dataPointer.assumingMemoryBound(to: Float.self)
        let strideMel = features.strides[1].intValue, strideT = features.strides[2].intValue
        // Padding frames: what the model saw in training for zero-padded audio (log of the clamp floor).
        let floorLog = logf(1e-9)
        for m in 0..<Self.nMels { for t in 0..<Self.frames { out[m * strideMel + t * strideT] = floorLog } }

        var frame = [Float](repeating: 0, count: Self.nFFT)
        var evens = [Float](repeating: 0, count: Self.nFFT / 2), odds = evens
        var re = evens, im = evens
        var power = [Float](repeating: 0, count: Self.nBins)
        var mel = [Float](repeating: 0, count: Self.nMels)
        chunk.withUnsafeBufferPointer { samples in
            for t in 0..<realFrames {
                vDSP_vmul(samples.baseAddress! + t * Self.hop, 1, window, 1, &frame, 1, vDSP_Length(Self.nFFT))
                for k in 0..<Self.nFFT / 2 { evens[k] = frame[2 * k]; odds[k] = frame[2 * k + 1] }
                vDSP_DFT_Execute(dft, evens, odds, &re, &im)
                // vDSP's real DFT is scaled by 2; DC is in re[0] and Nyquist in im[0].
                power[0] = (re[0] / 2) * (re[0] / 2)
                power[Self.nBins - 1] = (im[0] / 2) * (im[0] / 2)
                for k in 1..<Self.nFFT / 2 { power[k] = (re[k] * re[k] + im[k] * im[k]) / 4 }
                // mel (1×64) = power (1×161) · melfb (161×64). The file is bins × mels (torchaudio's layout),
                // whatever the model card says.
                vDSP_mmul(power, 1, melfb, 1, &mel, 1, 1, vDSP_Length(Self.nMels), vDSP_Length(Self.nBins))
                for m in 0..<Self.nMels { out[m * strideMel + t * strideT] = logf(min(max(mel[m], 1e-9), 1e9)) }
            }
        }
        let lengths = try MLMultiArray(shape: [1], dataType: .int32)
        lengths[0] = NSNumber(value: Int32(realFrames))
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["features": features, "feature_lengths": lengths]))

        // Output names are converter-generated: the logits are the 3-D array, the length the 1-element one.
        var logits: MLMultiArray?, validFrames: Int?
        for name in result.featureNames {
            guard let a = result.featureValue(for: name)?.multiArrayValue else { continue }
            if a.shape.count == 3 { logits = a } else if a.count == 1 { validFrames = a[0].intValue }
        }
        guard let logits else { return "" }
        let shaped = MLShapedArray<Float>(converting: logits)
        let steps = min(validFrames ?? shaped.shape[1], shaped.shape[1]), classes = shaped.shape[2]
        let scalars = shaped.scalars
        var pieces: [String] = []
        var previous = -1
        for t in 0..<steps {
            var best = 0, bestValue = -Float.greatestFiniteMagnitude
            for c in 0..<classes where scalars[t * classes + c] > bestValue { bestValue = scalars[t * classes + c]; best = c }
            if best != previous, best != Self.blank, best != 0, best < vocab.count { pieces.append(vocab[best]) }
            previous = best
        }
        return pieces.joined().replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
