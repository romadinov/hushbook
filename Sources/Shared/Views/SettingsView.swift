import SwiftUI

struct SettingsView: View {
    @Environment(DiaryStore.self) private var store
    @State private var current = ""
    @State private var new = ""
    @State private var repeatNew = ""
    @State private var passwordMessage: String?
    @State private var changing = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                if BiometricUnlock.kind != .none {
                    Toggle("Unlock with \(BiometricUnlock.kindName)", isOn: $store.useBiometrics)
                }
                Picker("Ask for password every", selection: $store.rememberDays) {
                    Text("Day").tag(1)
                    Text("3 days").tag(3)
                    Text("Week").tag(7)
                    Text("2 weeks").tag(14)
                    Text("30 days").tag(30)
                }
                .disabled(!store.useBiometrics || BiometricUnlock.kind == .none)
                Picker("Lock when away for", selection: $store.autoLockSeconds) {
                    Text("Immediately").tag(0)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("15 minutes").tag(900)
                    Text("1 hour").tag(3600)
                }
                Button("Lock and Require Password Next Time") { store.lockAndRequirePassword() }
            } header: {
                Text("Security")
            } footer: {
                Text("After you type the diary password, \(BiometricUnlock.kind == .none ? "biometrics" : BiometricUnlock.kindName) can unlock this device until the period ends. The device passcode never unlocks the diary, and enrolling a new face or fingerprint requires the password again. Entries and photos are encrypted with AES-256 before they are stored or synced.")
            }

            Section("Appearance") {
                Picker("Journal colour", selection: $store.journalColor) {
                    ForEach(JournalColor.allCases) { c in
                        Label { Text(c.name) } icon: { Image(systemName: "circle.fill").foregroundStyle(c.color) }.tag(c)
                    }
                }
            }

            VoiceSettings()

            Section("Change Password") {
                SecureField("Current password", text: $current)
                SecureField("New password", text: $new)
                SecureField("Repeat new password", text: $repeatNew)
                Button("Change Password") { Task { await changePassword() } }
                    .disabled(current.isEmpty || new.count < 6 || changing)
                if let passwordMessage { Text(passwordMessage).foregroundStyle(.secondary) }
            }

            Section("iCloud Sync") {
                LabeledContent("Status") {
                    if store.syncBusy { ProgressView().controlSize(.small) }
                    else if let error = store.syncError { Text(error).foregroundStyle(.red) }
                    else if let last = store.lastSync { Text("Synced \(last.formatted(.relative(presentation: .named)))") }
                    else { Text("Waiting") }
                }
                Button("Sync Now") { store.syncNow() }
                if store.unreadableCount > 0 {
                    Text("\(store.unreadableCount) entr\(store.unreadableCount == 1 ? "y" : "ies") couldn't be decrypted with this password.")
                        .foregroundStyle(.orange)
                }
            }

            Section("Diary") {
                let stats = store.stats
                LabeledContent("Entries", value: "\(stats.entries)")
                LabeledContent("Days", value: "\(stats.days)")
                LabeledContent("Photos", value: "\(stats.photos)")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(macOS)
        .frame(width: 520, height: 640)
        #endif
    }

    private func changePassword() async {
        guard new == repeatNew else { passwordMessage = "The new passwords don't match."; return }
        changing = true
        let ok = await store.changePassword(current: current, new: new)
        changing = false
        passwordMessage = ok ? "Password changed on all devices." : "The current password is wrong."
        if ok { current = ""; new = ""; repeatNew = "" }
    }
}

private struct VoiceSettings: View {
    @Bindable private var t = Transcriber.shared

    var body: some View {
        Section {
            Picker("Language", selection: $t.mode) {
                ForEach(Transcriber.Mode.allCases) { Text($0.title).tag($0) }
            }
            model("Whisper (English, language detection)", status: t.whisperStatus, size: "≈ 0.6 GB") {
                Task { await t.prepareWhisper() }
            }
            model("GigaAM v3 (Russian)", status: t.gigaStatus, size: "≈ 0.45 GB") {
                Task { await t.prepareGiga() }
            }
            if t.whisperDownloaded || t.gigaDownloaded {
                Button("Delete Speech Models", role: .destructive) { t.deleteModels() }
            }
        } header: {
            Text("Voice Notes")
        } footer: {
            Text("Voice notes are transcribed on this device; audio is never sent anywhere. Whisper tells Russian from English and transcribes English; GigaAM transcribes Russian. Models download once, the first time they're needed.")
        }
    }

    private func model(_ name: String, status: Transcriber.Status, size: String, prepare: @escaping () -> Void) -> some View {
        LabeledContent(name) {
            switch status {
            case .notDownloaded: Button("Download \(size)", action: prepare)
            case .downloading(let p): ProgressView(value: p).frame(width: 120)
            case .loading: Text("Loading…").foregroundStyle(.secondary)
            case .ready: Text("Ready").foregroundStyle(.secondary)
            case .failed(let error): Button("Retry", action: prepare).help(error)
            }
        }
    }
}
