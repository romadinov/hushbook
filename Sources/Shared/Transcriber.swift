import Foundation
import Observation
import WhisperKit

/// On-device speech to text for voice notes; audio never leaves the device.
/// Whisper (WhisperKit, Core ML) tells Russian from English and transcribes English; Russian goes to GigaAM v3,
/// which is markedly better at Russian. Both models are downloaded once into Application Support.
@MainActor @Observable
final class Transcriber {
    static let shared = Transcriber()

    enum Status: Equatable { case notDownloaded, downloading(Double), loading, ready, failed(String) }
    enum Mode: String, CaseIterable, Identifiable {
        case auto, russian, english
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: "Detect (Russian or English)"
            case .russian: "Always Russian"
            case .english: "Always English"
            }
        }
    }

    private(set) var whisperStatus: Status
    private(set) var gigaStatus: Status
    var mode: Mode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "transcriptionMode") } }

    private var whisper: WhisperKit?
    private var whisperTask: Task<WhisperKit?, Never>?
    private var giga: GigaAM?
    private var gigaTask: Task<GigaAM?, Never>?

    static var modelsBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushbook/Models", isDirectory: true)
    }
    static var gigaFolder: URL { modelsBase.appendingPathComponent("GigaAM-v3", isDirectory: true) }

    /// Large-v3 turbo on the Mac; on iPhone what WhisperKit recommends for the device (as in Uberdoer).
    static var whisperVariant: String {
        #if os(macOS)
        "openai_whisper-large-v3-v20240930_turbo_632MB"
        #else
        WhisperKit.recommendedModels().default
        #endif
    }

    private static let whisperFolderKey = "whisper.modelFolder"
    private static var whisperFolder: URL? {
        guard let p = UserDefaults.standard.string(forKey: whisperFolderKey), p.contains(whisperVariant),
              FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    init() {
        // "Ready" = on disk; the models load on first use.
        whisperStatus = Self.whisperFolder == nil ? .notDownloaded : .ready
        gigaStatus = GigaAM.isInstalled(in: Self.gigaFolder) ? .ready : .notDownloaded
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "transcriptionMode") ?? "") ?? .auto
    }

    var whisperDownloaded: Bool { Self.whisperFolder != nil }
    var gigaDownloaded: Bool { GigaAM.isInstalled(in: Self.gigaFolder) }

    // MARK: Whisper

    @discardableResult
    func prepareWhisper() async -> WhisperKit? {
        if let whisper { return whisper }
        if let whisperTask { return await whisperTask.value }
        let task = Task<WhisperKit?, Never> { @MainActor in
            do {
                var folder = Self.whisperFolder
                if folder == nil {
                    whisperStatus = .downloading(0)
                    try FileManager.default.createDirectory(at: Self.modelsBase, withIntermediateDirectories: true)
                    let url = try await WhisperKit.download(variant: Self.whisperVariant, downloadBase: Self.modelsBase) { p in
                        Task { @MainActor in Transcriber.shared.whisperStatus = .downloading(p.fractionCompleted) }
                    }
                    UserDefaults.standard.set(url.path, forKey: Self.whisperFolderKey)
                    folder = url
                }
                whisperStatus = .loading
                let kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder!.path, verbose: false, logLevel: .error,
                                                                prewarm: false, load: true, download: false))
                whisper = kit
                whisperStatus = .ready
                return kit
            } catch {
                whisperStatus = .failed(error.localizedDescription)
                return nil
            }
        }
        whisperTask = task
        let kit = await task.value
        whisperTask = nil
        return kit
    }

    // MARK: GigaAM

    @discardableResult
    func prepareGiga() async -> GigaAM? {
        if let giga { return giga }
        if let gigaTask { return await gigaTask.value }
        let task = Task<GigaAM?, Never> { @MainActor in
            do {
                let folder = Self.gigaFolder
                if !GigaAM.isInstalled(in: folder) {
                    gigaStatus = .downloading(0)
                    try await Self.downloadGiga(to: folder) { p in Transcriber.shared.gigaStatus = .downloading(p) }
                }
                gigaStatus = .loading
                // First load compiles the model for this device (a few seconds), off the main thread.
                let model = try await Task.detached { try GigaAM(folder: folder) }.value
                giga = model
                gigaStatus = .ready
                return model
            } catch {
                gigaStatus = .failed(error.localizedDescription)
                return nil
            }
        }
        gigaTask = task
        let model = await task.value
        gigaTask = nil
        return model
    }

    private static func downloadGiga(to folder: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        let fm = FileManager.default
        let staging = folder.deletingLastPathComponent().appendingPathComponent("GigaAM-v3.partial", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = 442_400_000.0   // approximate size of all files, for the progress bar
        var done = 0.0
        for file in GigaAM.files {
            let dest = staging.appendingPathComponent(file)
            if !fm.fileExists(atPath: dest.path) {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let base = done
                let (temp, response) = try await URLSession.shared.download(from: GigaAM.source.appendingPathComponent(file),
                                                                            delegate: DownloadProgress { fraction, expected in
                    Task { @MainActor in progress(min(1, (base + fraction * expected) / total)) }
                })
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                try fm.moveItem(at: temp, to: dest)
            }
            done += Double((try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0)
            progress(min(1, done / total))
        }
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: staging, to: folder)
    }

    // MARK: Transcription

    /// Transcribes 16 kHz mono samples. Returns the text and the main language ("ru" or "en").
    /// Each phrase gets its own language, so a note that switches between Russian and English is transcribed
    /// rather than translated.
    func transcribe(_ samples: [Float]) async -> (text: String, language: String) {
        guard !samples.isEmpty else { return ("", "en") }
        // Language per phrase, then consecutive phrases in the same language joined (≤25 s) for context.
        var groups: [(language: String, range: Range<Int>)] = []
        for phrase in AudioSamples.phrases(samples) {
            let language = await language(of: Array(samples[phrase]))
            if let last = groups.last, last.language == language, phrase.upperBound - last.range.lowerBound <= 25 * 16_000 {
                groups[groups.count - 1].range = last.range.lowerBound..<phrase.upperBound
            } else {
                groups.append((language, phrase))
            }
        }
        var parts: [String] = []
        var seconds: [String: Int] = [:]
        for group in groups {
            let piece = Array(samples[group.range])
            seconds[group.language, default: 0] += piece.count / 16_000
            let text = group.language == "ru" ? await russian(piece) : await whisper(piece, language: group.language)
            if !text.isEmpty { parts.append(text) }
        }
        let main = seconds.max { $0.value < $1.value }?.key ?? "en"
        return (parts.joined(separator: " "), main)
    }

    private func language(of piece: [Float]) async -> String {
        switch mode {
        case .russian: return "ru"
        case .english: return "en"
        case .auto:
            // WhisperKit reports only the detected language (its probability map has just that one entry).
            guard let kit = await prepareWhisper(), let detected = try? await kit.detectLangauge(audioArray: piece).language
            else { return "en" }
            return Self.russianLike.contains(detected) ? "ru" : "en"
        }
    }

    /// Close relatives Whisper sometimes reports for Russian speech.
    private static let russianLike: Set<String> = ["ru", "uk", "be", "bg", "sr", "mk", "kk"]

    private func russian(_ piece: [Float]) async -> String {
        if let giga = await prepareGiga(),
           let text = try? await Task.detached(operation: { try giga.transcribeWindow(piece) }).value {
            return text
        }
        return await whisper(piece, language: "ru")   // GigaAM unavailable: Whisper still does Russian
    }

    private func whisper(_ piece: [Float], language: String) async -> String {
        guard let kit = await prepareWhisper() else { return "" }
        let options = DecodingOptions(task: .transcribe, language: language, temperatureFallbackCount: 2, usePrefillPrompt: true,
                                      detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: true)
        let results = (try? await kit.transcribe(audioArray: piece, decodeOptions: options)) ?? []
        return Self.clean(results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whisper sometimes "hears" stock phrases in near-silence; drop those.
    static func clean(_ s: String) -> String {
        let junk = ["Продолжение следует", "Субтитры", "Thank you for watching", "Thanks for watching", "[BLANK_AUDIO]", "(music)"]
        var t = s
        for j in junk where t.localizedCaseInsensitiveContains(j) { t = t.replacingOccurrences(of: j, with: "", options: .caseInsensitive) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func deleteModels() {
        whisper = nil; giga = nil
        try? FileManager.default.removeItem(at: Self.modelsBase)
        UserDefaults.standard.removeObject(forKey: Self.whisperFolderKey)
        whisperStatus = .notDownloaded
        gigaStatus = .notDownloaded
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: (Double, Double) -> Void
    init(_ onProgress: @escaping (Double, Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        guard expected > 0 else { return }
        onProgress(Double(written) / Double(expected), Double(expected))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
