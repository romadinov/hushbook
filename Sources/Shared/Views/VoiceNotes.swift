import SwiftUI
import AVFoundation

/// A voice note in an entry: play/pause, progress, and where its transcript is.
struct AudioNoteView: View {
    @Environment(DiaryStore.self) private var store
    let note: AudioNote
    let entryID: UUID
    var onDelete: () -> Void

    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var position: TimeInterval = 0
    @State private var ticker: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: togglePlay) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: min(position, note.duration), total: max(note.duration, 0.1))
                    .tint(Theme.accent)
                HStack(spacing: 6) {
                    Text("\(Self.time(position)) / \(Self.time(note.duration))").monospacedDigit()
                    if let language = note.language { Text(language.uppercased()).fontWeight(.semibold) }
                    Spacer()
                    status
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Menu {
                if note.transcript != nil {
                    Button { store.retranscribe(note, entry: entryID) } label: { Label("Transcribe Again", systemImage: "text.bubble") }
                }
                Button(role: .destructive, action: onDelete) { Label("Delete Voice Note", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 24, height: 24)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(10)
        .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onDisappear { player?.stop(); ticker?.cancel() }
    }

    @ViewBuilder private var status: some View {
        let t = Transcriber.shared
        if store.transcribing.contains(note.id) {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(Self.describe(t.gigaStatus, "Russian model") ?? Self.describe(t.whisperStatus, "speech model") ?? "Transcribing…")
            }
        } else if note.transcript == nil {
            Button("Transcribe") { store.retranscribe(note, entry: entryID) }
                .buttonStyle(.borderless).font(.caption.weight(.semibold))
        } else if note.transcript?.isEmpty == true {
            Text("No speech recognised")
        }
    }

    private static func describe(_ status: Transcriber.Status, _ what: String) -> String? {
        switch status {
        case .downloading(let p): "Downloading \(what) \(Int(p * 100))%"
        case .loading: "Loading \(what)…"
        default: nil
        }
    }

    static func time(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func togglePlay() {
        if playing { player?.pause(); playing = false; ticker?.cancel(); return }
        Task {
            if player == nil, let data = await store.audioData(note.id) {
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try? AVAudioSession.sharedInstance().setActive(true)
                #endif
                player = try? AVAudioPlayer(data: data)
            }
            guard let player else { return }
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            player.play()
            playing = true
            ticker = Task {
                while !Task.isCancelled, player.isPlaying {
                    position = player.currentTime
                    try? await Task.sleep(for: .milliseconds(100))
                }
                position = player.isPlaying ? player.currentTime : (player.currentTime == 0 ? note.duration : player.currentTime)
                playing = player.isPlaying
            }
        }
    }
}

/// Shown while recording: elapsed time, a level meter, cancel and stop.
struct RecordingBar: View {
    let recorder: VoiceRecorder
    var onStop: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(.red).frame(width: 10, height: 10)
                .opacity(Int(recorder.elapsed * 2) % 2 == 0 ? 1 : 0.3)
            Text(AudioNoteView.time(recorder.elapsed)).monospacedDigit().font(.headline)
            LevelMeter(level: recorder.level)
            Button("Cancel", role: .cancel, action: onCancel).buttonStyle(.borderless)
            Button(action: onStop) {
                Label("Done", systemImage: "stop.fill")
                    .font(.headline)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .foregroundStyle(.white)
                    .background(Color.red, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<24, id: \.self) { i in
                Capsule()
                    .fill(Float(i) / 24 < level ? Color.red : Color.gray.opacity(0.25))
                    .frame(width: 3, height: 6 + CGFloat(i % 5) * 3)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.linear(duration: 0.1), value: level)
    }
}
