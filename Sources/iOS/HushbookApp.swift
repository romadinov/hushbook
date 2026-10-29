import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()   // CKSyncEngine fetches when iCloud pushes a change
        return true
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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: store.didEnterBackground()
            case .active: store.didBecomeActive()
            default: break
            }
        }
    }
}
