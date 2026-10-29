import SwiftUI

/// Day One-style journal colours. The chosen one tints the whole app; the root view is rebuilt when it changes.
enum JournalColor: String, CaseIterable, Identifiable {
    case red, blue, green, orange, purple, teal, pink, charcoal
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .red: Color(red: 0.78, green: 0.28, blue: 0.40)
        case .blue: Color(red: 0.17, green: 0.62, blue: 0.94)
        case .green: Color(red: 0.24, green: 0.64, blue: 0.40)
        case .orange: Color(red: 0.93, green: 0.51, blue: 0.20)
        case .purple: Color(red: 0.53, green: 0.36, blue: 0.82)
        case .teal: Color(red: 0.13, green: 0.62, blue: 0.64)
        case .pink: Color(red: 0.90, green: 0.36, blue: 0.62)
        case .charcoal: Color(red: 0.25, green: 0.27, blue: 0.31)
        }
    }

    static var current: JournalColor {
        JournalColor(rawValue: UserDefaults.standard.string(forKey: "journalColor") ?? "") ?? .red
    }
}

enum Theme {
    static var accent: Color { JournalColor.current.color }
    static var accentDeep: Color { accent.mix(with: .black, by: 0.25) }
    static var headerGradient: LinearGradient {
        LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct MonthSection: Identifiable {
    let id: Date
    let title: String
    let entries: [Entry]
}

func monthSections(_ entries: [Entry]) -> [MonthSection] {
    let cal = Calendar.current
    let groups = Dictionary(grouping: entries) { cal.dateInterval(of: .month, for: $0.date)!.start }
    return groups.keys.sorted(by: >).map { month in
        MonthSection(id: month, title: month.formatted(.dateTime.month(.wide).year()),
                     entries: groups[month]!.sorted { $0.date > $1.date })
    }
}

/// Day One's date tile: weekday over a large day number in a rounded box; blank for later entries that day.
struct DateColumn: View {
    let date: Date
    let visible: Bool
    var selected = false

    var body: some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Color.black.opacity(0.55) : Color.secondary)
            Text(date.formatted(.dateTime.day(.twoDigits)))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? Color.black : Calendar.current.isDateInToday(date) ? Theme.accent : Color.primary)
                .monospacedDigit()
        }
        .frame(width: 52, height: 56)
        .background(selected ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(selected ? 0 : 0.12)))
        .opacity(visible ? 1 : 0)
    }
}

struct EntryRow: View {
    let entry: Entry
    var showDate = true
    var selected = false

    var body: some View {
        // In a narrow column the photo goes first, so the text never squeezes into a sliver.
        ViewThatFits(in: .horizontal) {
            row(withPhoto: true)
            row(withPhoto: false)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, selected ? 10 : 0)
        .background(selected ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private var secondary: Color { selected ? .white.opacity(0.75) : .secondary }

    private func row(withPhoto: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            DateColumn(date: entry.date, visible: showDate, selected: selected)
            VStack(alignment: .leading, spacing: 3) {
                if entry.isEmpty {
                    Text("New Entry").font(.headline).foregroundStyle(secondary)
                } else {
                    if !entry.title.isEmpty {
                        Text(entry.title).font(.headline).lineLimit(2)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    if !entry.preview.isEmpty {
                        Text(entry.preview).font(.subheadline).foregroundStyle(secondary).lineLimit(2)
                    }
                }
                HStack(spacing: 6) {
                    Text(entry.date.formatted(date: .omitted, time: .shortened)).fixedSize()
                    if entry.starred { Image(systemName: "star.fill").foregroundStyle(selected ? .white : .yellow) }
                    if !entry.audio.isEmpty { Image(systemName: "waveform") }
                    if !entry.tags.isEmpty {
                        Text(entry.tags.map { "#\($0)" }.joined(separator: " "))
                            .foregroundStyle(selected ? Color.white : Theme.accent).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.8))
                .lineLimit(1)
                .padding(.top, 2)
            }
            .frame(minWidth: withPhoto ? 150 : 0, idealWidth: 150, maxWidth: .infinity, alignment: .leading)   // ViewThatFits measures ideal width
            .layoutPriority(1)
            if withPhoto, let first = entry.photoIDs.first {
                PhotoThumb(id: first, side: 72, cornerRadius: 10)
                    .overlay(alignment: .bottomLeading) {
                        if entry.photoIDs.count > 1 {
                            Label("\(entry.photoIDs.count)", systemImage: "photo")
                                .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                .shadow(radius: 2).padding(5)
                        }
                    }
            }
        }
    }
}

/// Decrypts on a background thread; shows a placeholder until the photo has synced.
struct PhotoThumb: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.displayScale) private var scale
    let id: UUID
    var side: CGFloat? = nil
    var cornerRadius: CGFloat = 8
    var maxPixel: Int? = nil
    @State private var image: CGImage?

    var body: some View {
        Color.gray.opacity(0.15)
            .overlay {
                if let image {
                    Image(cgImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: "\(id)-\(store.photoRevision)") {
                let px = maxPixel ?? Int((side ?? 200) * scale)
                image = await store.image(id, maxPixel: px)
            }
    }
}

struct TagChip: View {
    let tag: String
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(tag)")
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                    .buttonStyle(.plain)
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(Theme.accent)
        .background(Theme.accent.opacity(0.12), in: Capsule())
    }
}

/// Day One's Calendar view: months stacked, days with entries filled in blue or with the day's photo.
struct CalendarGrid: View {
    let entries: [Entry]
    let onSelectDay: (Date) -> Void

    private var byDay: [Date: [Entry]] {
        Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.date) }
    }

    private var months: [Date] {
        let cal = Calendar.current
        let now = cal.dateInterval(of: .month, for: .now)!.start
        let earliest = entries.map(\.date).min().map { cal.dateInterval(of: .month, for: $0)!.start } ?? now
        var list: [Date] = []
        var m = now
        while m >= earliest, list.count < 240 {
            list.append(m)
            m = cal.date(byAdding: .month, value: -1, to: m)!
        }
        return list
    }

    var body: some View {
        let days = byDay
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(months, id: \.self) { month in
                MonthGrid(month: month, days: days, onSelectDay: onSelectDay)
            }
        }
        .padding()
    }
}

private struct MonthGrid: View {
    let month: Date
    let days: [Date: [Entry]]
    let onSelectDay: (Date) -> Void

    var body: some View {
        let cal = Calendar.current
        let count = cal.range(of: .day, in: .month, for: month)!.count
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let symbols = cal.veryShortWeekdaySymbols
        let ordered = Array(symbols[(cal.firstWeekday - 1)...] + symbols[..<(cal.firstWeekday - 1)])
        VStack(alignment: .leading, spacing: 10) {
            Text(month.formatted(.dateTime.month(.wide).year())).font(.title3.bold())
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(ordered.indices, id: \.self) { i in
                    Text(ordered[i]).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                // Offsets past the weekday row: blanks first, then the days, so every id is unique.
                ForEach(7..<(7 + lead + count), id: \.self) { slot in
                    let day = slot - 7 - lead + 1
                    if day < 1 {
                        Color.clear.frame(height: 40)
                    } else {
                        let date = cal.date(byAdding: .day, value: day - 1, to: month)!
                        DayCell(day: day, date: date, entries: days[date] ?? [])
                            .onTapGesture { if days[date] != nil { onSelectDay(date) } }
                    }
                }
            }
        }
    }
}

private struct DayCell: View {
    let day: Int
    let date: Date
    let entries: [Entry]

    var body: some View {
        let photo = entries.lazy.compactMap(\.photoIDs.first).first
        ZStack {
            if let photo {
                PhotoThumb(id: photo, side: 40, cornerRadius: 20)
                Circle().fill(.black.opacity(0.25))
            } else if !entries.isEmpty {
                Circle().fill(Theme.accent)
            } else if Calendar.current.isDateInToday(date) {
                Circle().stroke(Theme.accent, lineWidth: 1.5)
            }
            Text("\(day)")
                .font(.subheadline.weight(entries.isEmpty ? .regular : .bold))
                .foregroundStyle(entries.isEmpty ? (date > .now ? Color.secondary.opacity(0.5) : .primary) : .white)
        }
        .frame(width: 40, height: 40)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// Day One's Media view: every photo, newest first, in a tight square grid.
struct MediaGrid: View {
    let entries: [Entry]
    var columns = 3
    let onOpen: (Entry) -> Void

    var body: some View {
        let items = entries.flatMap { e in e.photoIDs.map { (photo: $0, entry: e) } }
        if items.isEmpty {
            ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                   description: Text("Photos you add to entries appear here."))
                .padding(.top, 60)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
                ForEach(items, id: \.photo) { item in
                    Color.clear
                        .aspectRatio(1, contentMode: .fill)
                        .overlay { PhotoThumb(id: item.photo, cornerRadius: 0, maxPixel: 400) }
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen(item.entry) }
                }
            }
        }
    }
}

/// Full-size photo, decrypted in memory only.
struct PhotoViewer: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var image: CGImage?
    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(cgImage: image).resizable().scaledToFit()
                    .scaleEffect(zoom)
                    .gesture(MagnifyGesture().onChanged { zoom = max(1, $0.magnification) }.onEnded { _ in
                        withAnimation { zoom = 1 }
                    })
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.25))
            }
            .buttonStyle(.plain)
            .padding()
            .keyboardShortcut(.cancelAction)
        }
        .task { image = await store.image(id, maxPixel: 4096) }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 450)
        #endif
    }
}

struct DayEntriesView: View {
    @Environment(DiaryStore.self) private var store
    let day: Date
    let onOpen: (Entry) -> Void

    var body: some View {
        let list = store.saved.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
        List(list) { entry in
            Button { onOpen(entry) } label: { EntryRow(entry: entry) }.buttonStyle(.plain)
        }
        .listStyle(.plain)
        .navigationTitle(day.formatted(date: .complete, time: .omitted))
    }
}
