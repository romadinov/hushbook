import SwiftUI
import PhotosUI

/// Day One for Mac: journals and tags in the sidebar, the timeline in the middle, the entry on the right.
struct MacHome: View {
    @Environment(DiaryStore.self) private var store
    @State private var filter: DiaryFilter? = .all
    @State private var selection: UUID?
    @State private var layout: DiaryLayout = .list
    @State private var search = ""
    @State private var newEntryID: UUID?
    @State private var toDelete: Entry?

    private var visible: [Entry] {
        store.entries(filter ?? .all, search: search).filter { !$0.isEmpty || $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            Group {
                switch layout {
                case .list: timeline
                case .calendar:
                    ScrollView { CalendarGrid(entries: visible.filter { !$0.isEmpty }, onSelectDay: selectDay) }
                case .media:
                    ScrollView { MediaGrid(entries: visible, columns: 4) { selection = $0.id }.padding(2) }
                }
            }
            .frame(minWidth: 340)   // the split view alone let this column shrink to ~200 pt
            .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 560)
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .searchable(text: $search, placement: .toolbar, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Picker("View", selection: $layout) {
                        ForEach(DiaryLayout.allCases) { Image(systemName: $0.symbol).help($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem {
                    Button(action: newEntry) { Label("New Entry", systemImage: "plus") }
                        .help("New Entry (⌘N)")
                }
            }
        } detail: {
            if let id = selection, let entry = store.entry(id) {
                EntryEditor(entry: entry, autofocus: id == newEntryID) { selection = nil }
                    .id(id)
                    .navigationSplitViewColumnWidth(min: 380, ideal: 560)
            } else {
                ContentUnavailableView("No Entry Selected", systemImage: "book.closed",
                                       description: Text("Choose an entry, or press ⌘N to write a new one."))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.accent)
        .onReceive(NotificationCenter.default.publisher(for: .newEntry)) { _ in newEntry() }
        .alert("Day One Import", isPresented: Binding(get: { store.importResult != nil }, set: { if !$0 { store.importResult = nil } })) {
            Button("OK") { store.importResult = nil }
        } message: {
            Text(store.importResult ?? "")
        }
        .onAppear {
            if selection == nil { selection = visible.first?.id }
            if let demo = DiaryStore.demoScreen, let layout = DiaryLayout.allCases.first(where: { $0.rawValue.lowercased() == demo }) {
                self.layout = layout
            }
            #if DEBUG
            if DiaryStore.demoScreen == "voice" {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    if let id = await store.seedDemoVoiceNote() { selection = id }
                }
            }
            #endif
        }
        .onChange(of: store.saved.count) { _, _ in if selection == nil { selection = visible.first?.id } }
        .confirmationDialog("Delete this entry?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Delete Entry", role: .destructive) {
                if let toDelete { if selection == toDelete.id { selection = nil }; store.delete(toDelete) }
            }
        }
    }

    private var title: String {
        switch filter ?? .all {
        case .all: "All Entries"
        case .starred: "Starred"
        case .onThisDay: "On This Day"
        case .tag(let tag): "#\(tag)"
        }
    }

    private var subtitle: String {
        let n = visible.filter { !$0.isEmpty }.count
        return "\(n) entr\(n == 1 ? "y" : "ies")"
    }

    private var sidebar: some View {
        List(selection: $filter) {
            Section {
                SidebarRow(title: "On This Day", symbol: "calendar.badge.clock", color: .orange,
                           count: store.entries(.onThisDay).count).tag(DiaryFilter.onThisDay)
                SidebarRow(title: "Starred", symbol: "star.fill", color: .yellow,
                           count: store.entries(.starred).count).tag(DiaryFilter.starred)
            }
            Section("Journals") {
                SidebarRow(title: "All Entries", symbol: "book.closed.fill", color: Theme.accent, count: store.saved.count)
                    .tag(DiaryFilter.all)
            }
            let tags = store.allTags
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.name) { tag in
                        SidebarRow(title: tag.name, symbol: "number", color: .gray, count: tag.count).tag(DiaryFilter.tag(tag.name))
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let progress = store.importProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 60)
                    Text("Importing \(progress.done) of \(progress.total)").font(.caption).foregroundStyle(.secondary)
                } else {
                if store.syncBusy { ProgressView().controlSize(.small) }
                Text(syncText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { store.lock() } label: { Image(systemName: "lock") }
                    .buttonStyle(.borderless).help("Lock (⌘L)")
            }
            .padding(10)
        }
    }

    private var syncText: String {
        if let error = store.syncError { return error }
        if store.syncBusy { return "Syncing…" }
        if let last = store.lastSync { return "Synced \(last.formatted(date: .omitted, time: .shortened))" }
        return "iCloud"
    }

    /// Day One's list: bold month headers that stay pinned, rows filled with the journal colour when selected.
    private var timeline: some View {
        let sections = monthSections(visible)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(Array(section.entries.enumerated()), id: \.element.id) { i, entry in
                                let sameDay = i > 0 && Calendar.current.isDate(section.entries[i - 1].date, inSameDayAs: entry.date)
                                EntryRow(entry: entry, showDate: !sameDay, selected: entry.id == selection)
                                    .padding(.horizontal, entry.id == selection ? 0 : 10)
                                    .id(entry.id)
                                    .onTapGesture { selection = entry.id }
                                    .contextMenu {
                                        Button(entry.starred ? "Unstar" : "Star") { store.toggleStar(entry) }
                                        Divider()
                                        Button("Delete Entry…", role: .destructive) { toDelete = entry }
                                    }
                                if i < section.entries.count - 1 { Divider().padding(.leading, 74) }
                            }
                        } header: {
                            Text(section.title)
                                .font(.title2.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, proxy); return .handled }
            .onKeyPress(.upArrow) { move(-1, proxy); return .handled }
            .onDeleteCommand { if let id = selection, let entry = store.entry(id) { toDelete = entry } }
        }
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No Entries" : "No Results", systemImage: "book.closed",
                                       description: Text(search.isEmpty ? "Press ⌘N to write your first entry." : ""))
            }
        }
    }

    private func move(_ delta: Int, _ proxy: ScrollViewProxy) {
        let ids = monthSections(visible).flatMap(\.entries).map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) }.map { $0 + delta } ?? 0
        let id = ids[max(0, min(ids.count - 1, index))]
        selection = id
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
    }

    private func selectDay(_ day: Date) {
        selection = visible.last { Calendar.current.isDate($0.date, inSameDayAs: day) }?.id
    }

    private func newEntry() {
        var entry = store.newDraft()
        if case .tag(let tag) = filter {
            entry.tags = [tag]
            store.save(entry)
        } else if filter != .all {
            filter = .all
        }
        layout = .list
        newEntryID = entry.id
        selection = entry.id
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let color: Color
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title).lineLimit(1)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
