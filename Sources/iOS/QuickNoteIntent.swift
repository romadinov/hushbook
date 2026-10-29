import AppIntents

/// "Quick Note" for Shortcuts, Siri, Spotlight, Control Center and the Action button: opens the quick note sheet,
/// which works without unlocking the diary.
struct QuickNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Note"
    static let description = IntentDescription("Write a diary note without unlocking. It can be read only after unlocking Hushbook.")
    static let supportedModes: IntentModes = .foreground

    func perform() async throws -> some IntentResult {
        await MainActor.run { QuickNoteDraft.shared.isPresented = true }
        return .result()
    }
}

struct HushbookShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: QuickNoteIntent(), phrases: ["Quick note in \(.applicationName)", "New \(.applicationName) note"],
                    shortTitle: "Quick Note", systemImageName: "square.and.pencil")
    }
}
