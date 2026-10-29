import SwiftUI
import AppKit

extension Notification.Name {
    static let newEntry = Notification.Name("HushbookNewEntry")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: DiaryStore?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
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

    func applicationDidResignActive(_ notification: Notification) { store?.didEnterBackground() }
    func applicationDidBecomeActive(_ notification: Notification) { store?.didBecomeActive() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct HushbookMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = DiaryStore()

    var body: some Scene {
        Window("Hushbook", id: "main") {
            Group {
                if store.phase == .unlocked { MacHome() } else { LockView() }
            }
            .frame(minWidth: 820, minHeight: 520)
            .environment(store)
            .onAppear { delegate.store = store }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Entry") { NotificationCenter.default.post(name: .newEntry, object: nil) }
                    .keyboardShortcut("n")
                    .disabled(store.phase != .unlocked)
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
