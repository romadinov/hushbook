import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()   // CKSyncEngine fetches when iCloud pushes a change
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

/// The "Quick Note" Home Screen quick action (touch and hold the app icon).
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    static let quickNoteAction = "com.romadinov.hushbook.quicknote"

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if options.shortcutItem?.type == Self.quickNoteAction { QuickNoteDraft.shared.isPresented = true }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        let handled = shortcutItem.type == Self.quickNoteAction
        if handled { QuickNoteDraft.shared.isPresented = true }
        completionHandler(handled)
    }
}

@main
struct HushbookApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = DiaryStore()

    var body: some Scene {
        WindowGroup {
            RootView().environment(store)
        }
    }
}

struct RootView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Bindable private var quickNote = QuickNoteDraft.shared

    var body: some View {
        ZStack {
            Group {
                if store.phase != .unlocked {
                    LockView()
                } else if sizeClass == .regular {
                    SplitHome()      // iPad full screen or wide Split View: Mac-style three columns
                } else {
                    PhoneHome()
                }
            }
            .tint(Theme.accent)
            .id(store.journalColor)   // Theme.accent is read when views are built
            if scenePhase != .active && store.phase == .unlocked { PrivacyCover() }
        }
        .sheet(isPresented: $quickNote.isPresented) {
            QuickNoteView { quickNote.isPresented = false }.tint(Theme.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: store.didEnterBackground()
            case .active: store.didBecomeActive()
            default: break
            }
        }
    }
}
