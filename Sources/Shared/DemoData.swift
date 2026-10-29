#if DEBUG
import SwiftUI

/// Debug screenshots with a demo diary that never syncs:
/// - Simulator: `SIMCTL_CHILD_HUSHBOOK_DEMO=list|calendar|media|editor|new`
/// - Mac: `HUSHBOOK_DEMO=list HUSHBOOK_DATA_DIR=/tmp/x HUSHBOOK_SNAPSHOT=/tmp/x.png Hushbook` (needs its own data folder)
extension DiaryStore {
    static var demoMode: String? {
        let env = ProcessInfo.processInfo.environment
        #if os(macOS)
        guard env["HUSHBOOK_DATA_DIR"] != nil else { return nil }   // never seed the real diary
        #endif
        return env["HUSHBOOK_DEMO"]
    }

    func seedDemo() async {
        if local.loadVault() == nil { await createDiary(password: "demo-demo") }
        else { _ = await unlock(password: "demo-demo") }
        guard saved.isEmpty else { return }
        let samples: [(Int, String, [String], Bool, CGColor?)] = [
            (0, "Quiet morning\nCoffee on the balcony before anyone woke up. The light over the bay was soft and grey, and for once my head was quiet too.", ["morning", "gratitude"], true, CGColor(srgbRed: 0.2, green: 0.7, blue: 0.75, alpha: 1)),
            (0, "Things I didn't say\nI wanted to tell him how much that conversation hurt. Maybe next week.", ["private"], false, nil),
            (1, "Long walk\nTen kilometres along the coast. Thinking about the job offer — the money is good but the hours would eat everything else.", ["walk", "work"], false, CGColor(srgbRed: 0.95, green: 0.55, blue: 0.2, alpha: 1)),
            (3, "Dinner with Anna\nWe laughed until the waiter brought the bill twice.", ["friends"], true, CGColor(srgbRed: 0.95, green: 0.3, blue: 0.45, alpha: 1)),
            (9, "Monday\nToo many meetings. Wrote nothing worth keeping, except this.", ["work"], false, nil),
            (24, "Rainy weekend\nFinished the novel. The ending was better than I expected.", ["reading"], false, CGColor(srgbRed: 0.35, green: 0.35, blue: 0.85, alpha: 1)),
        ]
        for (ago, text, tags, star, color) in samples {
            var ids: [UUID] = []
            if let color, let data = Self.swatch(color), let id = await addPhoto(data) { ids.append(id) }
            var e = newDraft(date: Calendar.current.date(byAdding: .day, value: -ago, to: .now)!.addingTimeInterval(Double(-ago * 1300)), photoIDs: ids)
            e.text = text; e.tags = tags; e.starred = star
            save(e)
        }
    }

    /// `HUSHBOOK_DEMO_AUDIO=/path.m4a`: attach that recording to the first entry with a photo (it gets transcribed).
    func seedDemoVoiceNote() async -> UUID? {
        guard let path = ProcessInfo.processInfo.environment["HUSHBOOK_DEMO_AUDIO"],
              var entry = saved.first(where: { !$0.photoIDs.isEmpty }) else { return nil }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).\((path as NSString).pathExtension)")
        try? FileManager.default.copyItem(atPath: path, toPath: copy.path)
        let duration = Double((try? AudioSamples.load16k(copy).count) ?? 0) / 16_000
        guard let note = await addVoiceNote(file: copy, duration: duration, entryID: entry.id) else { return nil }
        entry.audio.append(note)
        save(entry)
        return entry.id
    }

    private static func swatch(_ color: CGColor) -> Data? {
        guard let ctx = CGContext(data: nil, width: 600, height: 450, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 450))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.35)); ctx.fillEllipse(in: CGRect(x: 380, y: 260, width: 120, height: 120))
        return ctx.makeImage().flatMap { Images.jpeg($0, quality: 0.9) }
    }
}
#endif
