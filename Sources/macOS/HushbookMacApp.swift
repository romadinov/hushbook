import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: DiaryStore?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Diagnostic: `Hushbook --transcribe-test a.m4a b.wav` prints what voice notes would transcribe to.
        if let i = CommandLine.arguments.firstIndex(of: "--transcribe-test") {
            let files = CommandLine.arguments[(i + 1)...]
            Task { @MainActor in
                for file in files {
                    let t0 = Date()
                    let samples = (try? AudioSamples.load16k(URL(fileURLWithPath: file))) ?? []
                    let result = await Transcriber.shared.transcribe(samples)
                    print("\(file) [\(result.language)] \(String(format: "%.1fs", Date().timeIntervalSince(t0))): \(result.text)")
                }
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--keychain-selftest") {
            let result = BiometricUnlock.selfTest()
            print("biometry: \(result.kind) remembered: \(BiometricUnlock.rememberedUntil.map { "\($0)" } ?? "none") SecItemAdd: \(result.status) \(SecCopyErrorMessageString(result.status, nil) as String? ?? "")")
            exit(0)
        }
        #if DEBUG
        Self.snapshotIfRequested()
        #endif
        NSApplication.shared.registerForRemoteNotifications()
        // Lock straight away when the Mac sleeps, the screen locks or another user takes over.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.store?.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.store?.lock() }
            })
    }

    #if DEBUG
    /// `HUSHBOOK_SNAPSHOT=/path.png`: render the main window into a PNG (no Screen Recording permission needed), quit.
    static func snapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["HUSHBOOK_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["HUSHBOOK_SNAPSHOT_DELAY"] ?? "") ?? 5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
               let view = window.contentView?.superview ?? window.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
    #endif

    func applicationDidResignActive(_ notification: Notification) { store?.didEnterBackground() }
    func applicationDidBecomeActive(_ notification: Notification) { store?.didBecomeActive() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct HushbookMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = DiaryStore()

    /// Picks a Day One export (.zip or unzipped folder), unzips it to a temporary folder and imports it.
    @MainActor private func importDayOne() async {
        let panel = NSOpenPanel()
        panel.title = "Choose a Day One JSON export"
        panel.message = "In Day One: File → Export → JSON. Choose the .zip it creates (or the unzipped folder)."
        panel.allowedContentTypes = [.zip, .folder]
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var folder = url
        var temp: URL?
        if url.pathExtension.lowercased() == "zip" {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hushbook-import-\(UUID().uuidString)")
            temp = dir
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", url.path, dir.path]
            try? ditto.run()
            await Task.detached { ditto.waitUntilExit() }.value
            guard ditto.terminationStatus == 0 else { store.importResult = "Couldn't unzip \(url.lastPathComponent)."; return }
            folder = dir
        }
        await store.importDayOne(folder: folder)
        if let temp { try? FileManager.default.removeItem(at: temp) }   // the unzipped copy is plaintext
    }

    var body: some Scene {
        Window("Hushbook", id: "main") {
            Group {
                if store.phase == .unlocked { SplitHome() } else { LockView() }
            }
            .frame(minWidth: 1000, minHeight: 560)
            .tint(Theme.accent)
            .id(store.journalColor)   // Theme.accent is read when views are built
            .environment(store)
            .onAppear { delegate.store = store }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Entry") { NotificationCenter.default.post(name: .newEntry, object: nil) }
                    .keyboardShortcut("n")
                    .disabled(store.phase != .unlocked)
            }
            CommandGroup(replacing: .importExport) {
                Button("Import from Day One…") { Task { await importDayOne() } }
                    .disabled(store.phase != .unlocked || store.importProgress != nil)
            }
            CommandMenu("Diary") {
                Button("Lock") { store.lock() }
                    .keyboardShortcut("l")
                    .disabled(store.phase != .unlocked)
                Button("Lock and Require Password") { store.lockAndRequirePassword() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(store.phase != .unlocked)
                Divider()
                Button("Sync Now") { store.syncNow() }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            Group {
                if store.phase == .unlocked { SettingsView() }
                else { Text("Unlock the diary to change settings.").padding(40) }
            }
            .environment(store)
        }
    }
}
