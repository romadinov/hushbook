import SwiftUI

enum Theme {
    /// Day One's journal blue.
    static let blue = Color(red: 0.17, green: 0.62, blue: 0.94)
    static let blueDeep = Color(red: 0.08, green: 0.44, blue: 0.80)
    static let headerGradient = LinearGradient(colors: [blue, blueDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
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

/// Day One's left column: weekday over a large day number; blank for later entries on the same day.
struct DateColumn: View {
    let date: Date
    let visible: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Calendar.current.isDateInToday(date) ? Theme.blue : .primary)
        }
        .frame(width: 42)
        .opacity(visible ? 1 : 0)
    }
}

struct EntryRow: View {
    let entry: Entry
    var showDate = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DateColumn(date: entry.date, visible: showDate)
            VStack(alignment: .leading, spacing: 3) {
                if entry.isEmpty {
                    Text("New Entry").font(.headline).foregroundStyle(.secondary)
                } else {
                    if !entry.title.isEmpty {
                        Text(entry.title).font(.headline).lineLimit(1)
                    }
                    if !entry.preview.isEmpty {
                        Text(entry.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                HStack(spacing: 6) {
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                    if entry.starred { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    if !entry.tags.isEmpty {
                        Text(entry.tags.map { "#\($0)" }.joined(separator: " ")).foregroundStyle(Theme.blue).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            if let first = entry.photoIDs.first {
                PhotoThumb(id: first, side: 68)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
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
        .foregroundStyle(Theme.blue)
        .background(Theme.blue.opacity(0.12), in: Capsule())
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
                Circle().fill(Theme.blue)
            } else if Calendar.current.isDateInToday(date) {
                Circle().stroke(Theme.blue, lineWidth: 1.5)
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
