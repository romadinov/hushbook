import AVFoundation
import Observation

/// Records a voice note to a temporary file. The caller encrypts it and the plaintext file is deleted right away.
@MainActor @Observable
final class VoiceRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0          // 0…1, for the meter
    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?

    enum Failure: LocalizedError {
        case denied
        var errorDescription: String? {
            #if os(iOS)
            "Hushbook can't use the microphone. Allow it in Settings → Privacy & Security → Microphone."
            #else
            "Hushbook can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
            #endif
        }
    }

    func start() async throws {
        guard !isRecording else { return }
        #if os(iOS)
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.denied }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #else
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.denied }
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
                                       AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
        self.recorder = recorder
        isRecording = true
        elapsed = 0
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                self.elapsed = r.currentTime
                self.level = max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
            }
        }
    }

    /// Stops and returns the recorded file and its length. Nil if nothing usable was recorded.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        meterTask?.cancel()
        self.recorder = nil
        isRecording = false
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        guard duration > 0.5 else { try? FileManager.default.removeItem(at: recorder.url); return nil }
        return (recorder.url, duration)
    }

    func cancel() {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        meterTask?.cancel()
        self.recorder = nil
        isRecording = false
    }
}
