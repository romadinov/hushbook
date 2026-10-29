#if targetEnvironment(simulator)
import SwiftUI

/// Simulator-only screenshots: `SIMCTL_CHILD_HUSHBOOK_DEMO=list|calendar|media|editor` seeds and unlocks a demo diary.
extension DiaryStore {
    static var demoMode: String? { ProcessInfo.processInfo.environment["HUSHBOOK_DEMO"] }

    func seedDemo() async {
        if local.loadVault() == nil { await createDiary(password: "demo-demo") }
        else { _ = await unlock(password: "demo-demo") }
        guard saved.isEmpty else { return }
        let samples: [(Int, String, [String], Bool, UIColor?)] = [
            (0, "Quiet morning\nCoffee on the balcony before anyone woke up. The light over the bay was soft and grey, and for once my head was quiet too.", ["morning", "gratitude"], true, .systemTeal),
            (0, "Things I didn't say\nI wanted to tell him how much that conversation hurt. Maybe next week.", ["private"], false, nil),
            (1, "Long walk\nTen kilometres along the coast. Thinking about the job offer — the money is good but the hours would eat everything else.", ["walk", "work"], false, .systemOrange),
            (3, "Dinner with Anna\nWe laughed until the waiter brought the bill twice.", ["friends"], true, .systemPink),
            (9, "Monday\nToo many meetings. Wrote nothing worth keeping, except this.", ["work"], false, nil),
            (24, "Rainy weekend\nFinished the novel. The ending was better than I expected.", ["reading"], false, .systemIndigo),
        ]
        for (ago, text, tags, star, color) in samples {
            var ids: [UUID] = []
            if let color, let data = Self.swatch(color), let id = await addPhoto(data) { ids.append(id) }
            var e = newDraft(date: Calendar.current.date(byAdding: .day, value: -ago, to: .now)!.addingTimeInterval(Double(-ago * 1300)), photoIDs: ids)
            e.text = text; e.tags = tags; e.starred = star
            save(e)
        }
    }

    private static func swatch(_ color: UIColor) -> Data? {
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 450)).image { ctx in
            color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 450))
            UIColor.white.withAlphaComponent(0.35).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 380, y: 60, width: 120, height: 120))
        }.jpegData(compressionQuality: 0.9)
    }
}
#endif
