import SwiftUI

/// Shown whenever the diary key isn't in memory: first-run setup, the iCloud check, and unlocking.
struct LockView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var password = ""
    @State private var confirm = ""
    @State private var message: String?
    @State private var working = false
    @State private var shake = 0
    @FocusState private var focused: Field?

    private enum Field { case password, confirm }

    var body: some View {
        ZStack {
            Theme.headerGradient.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "book.closed.fill").font(.system(size: 64))
                    Image(systemName: "lock.fill").font(.system(size: 24))
                        .padding(7).background(Theme.blueDeep, in: Circle()).offset(x: 14, y: 8)
                }
                Text("Hushbook").font(.largeTitle.bold())
                switch store.phase {
                case .checkingCloud:
                    ProgressView().tint(.white)
                    Text("Looking for your diary in iCloud…").font(.callout).opacity(0.85)
                case .needsSetup:
                    setup
                default:
                    unlock
                }
                if let message {
                    Text(message).font(.callout.weight(.medium)).multilineTextAlignment(.center)
                        .padding(10).background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                }
                Spacer()
                Spacer()
            }
            .frame(maxWidth: 380)
            .padding(28)
            .foregroundStyle(.white)
        }
        .task(id: store.phase) {
            if store.phase == .locked { await tryBiometrics() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, store.phase == .locked { Task { await tryBiometrics() } }
        }
    }

    private var unlock: some View {
        VStack(spacing: 14) {
            Text("Your diary is locked.").font(.callout).opacity(0.85)
            field("Diary password", text: $password, focus: .password)
                .onSubmit { Task { await submitUnlock() } }
                .modifier(Shake(animatableData: CGFloat(shake)))
            Button { Task { await submitUnlock() } } label: {
                Text("Unlock").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButton())
            .disabled(password.isEmpty || working)
            if store.useBiometrics && BiometricUnlock.kind != .none {
                Button { Task { await tryBiometrics(userInitiated: true) } } label: {
                    Label("Unlock with \(BiometricUnlock.kindName)", systemImage: BiometricUnlock.symbol)
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .padding(.top, 4)
            }
            if working { ProgressView().tint(.white) }
        }
        .onAppear { if !store.canUseBiometrics { focused = .password } }
    }

    private var setup: some View {
        VStack(spacing: 14) {
            Text("Choose a diary password. It's separate from your device passcode, which can never open this diary.")
                .font(.callout).multilineTextAlignment(.center).opacity(0.9)
            field("New password", text: $password, focus: .password)
                .onSubmit { focused = .confirm }
            field("Repeat password", text: $confirm, focus: .confirm)
                .onSubmit { Task { await submitSetup() } }
            Button { Task { await submitSetup() } } label: {
                Text("Create Diary").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButton())
            .disabled(password.count < 6 || working)
            Text("There's no way to recover entries if you forget it. After you type it, \(BiometricUnlock.kind == .none ? "this device" : BiometricUnlock.kindName) keeps the diary unlockable for \(store.rememberDays) days.")
                .font(.footnote).multilineTextAlignment(.center).opacity(0.75)
            Button("Look in iCloud again") { Task { await store.lookForExistingDiary() } }
                .buttonStyle(.plain).font(.footnote.weight(.semibold))
            if working { ProgressView().tint(.white) }
        }
        .onAppear { focused = .password }
    }

    private func field(_ title: String, text: Binding<String>, focus: Field) -> some View {
        SecureField(title, text: text, prompt: Text(title).foregroundStyle(.white.opacity(0.6)))
            .textFieldStyle(.plain)
            .focused($focused, equals: focus)
            .tint(.white)   // the caret takes the tint; the default blue vanishes on the blue background
            .padding(12)
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            // Not .password: the system would offer to save it in Passwords, which the device passcode opens.
            .textContentType(nil)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
    }

    private func tryBiometrics(userInitiated: Bool = false) async {
        guard !working else { return }
        guard store.canUseBiometrics else {
            if userInitiated {
                message = "Enter your password once. After that, \(BiometricUnlock.kindName) unlocks Hushbook for \(store.rememberDays) day\(store.rememberDays == 1 ? "" : "s")."
                focused = .password
            }
            return
        }
        #if os(iOS)
        guard scenePhase == .active else { return }
        #endif
        working = true
        message = await store.unlockWithBiometrics()
        working = false
        if store.phase == .locked { focused = .password }
    }

    private func submitUnlock() async {
        guard !password.isEmpty, !working else { return }
        working = true
        let ok = await store.unlock(password: password)
        working = false
        password = ""
        if ok { message = nil } else {
            message = "Wrong password."
            withAnimation(.default) { shake += 1 }
            focused = .password
        }
    }

    private func submitSetup() async {
        guard password.count >= 6 else { message = "Use at least 6 characters."; return }
        guard password == confirm else { message = "The passwords don't match."; return }
        working = true
        await store.createDiary(password: password)
        working = false
        password = ""; confirm = ""; message = nil
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 12)
            .foregroundStyle(Theme.blueDeep)
            .background(.white.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.5),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}

/// Covers the window whenever the app isn't frontmost on iPhone, so the app switcher never shows entries.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Theme.headerGradient.ignoresSafeArea()
            Image(systemName: "book.closed.fill").font(.system(size: 64)).foregroundStyle(.white)
        }
    }
}
