import SwiftUI
import PhotosUI

/// Day One's iPhone journal screen: a blue journal header, List / Calendar / Media tabs, and the floating + button.
struct PhoneHome: View {
    @Environment(DiaryStore.self) private var store
    @State private var path: [Route] = []
    @State private var layout: DiaryLayout = DiaryLayout.allCases.first { $0.rawValue.lowercased() == DiaryStore.demoScreen } ?? .list
    @State private var filter: DiaryFilter = .all
    @State private var search = ""
    @State private var showSettings = false
    @State private var showPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var toDelete: Entry?

    enum Route: Hashable { case entry(UUID, isNew: Bool), day(Date) }

    private var visible: [Entry] { store.entries(filter, search: search).filter { !$0.isEmpty } }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if layout == .list { timeline } else { grid }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.blue, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { toolbar }
            .searchable(text: $search, prompt: "Search entries")
            .overlay(alignment: .bottomTrailing) { if search.isEmpty { newEntryButton } }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .entry(let id, let isNew):
                    if let entry = store.entry(id) { EntryEditor(entry: entry, autofocus: isNew) }
                case .day(let day):
                    DayEntriesView(day: day) { path.append(.entry($0.id, isNew: false)) }
                }
            }
        }
        .tint(Theme.blue)
        .task { if DiaryStore.demoScreen == "editor", let e = store.saved.first { path = [.entry(e.id, isNew: false)] } }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView().toolbar { Button("Done") { showSettings = false } } } }
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 20, matching: .images)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task {
                var datas: [Data] = []
                for item in items { if let d = try? await item.loadTransferable(type: Data.self) { datas.append(d) } }
                await newEntry(with: datas)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.95) { Task { await newEntry(with: [data]) } }
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("Delete this entry?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Entry", role: .destructive) { if let toDelete { store.delete(toDelete) } }
        }
    }

    private var title: String {
        switch filter {
        case .all: "Hushbook"
        case .starred: "Starred"
        case .onThisDay: "On This Day"
        case .tag(let tag): "#\(tag)"
        }
    }

    // MARK: Header

    private var header: some View {
        let stats = store.stats
        return VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.largeTitle.bold())
            HStack(spacing: 22) {
                stat(stats.entries, "Entries")
                stat(stats.days, "Days")
                stat(stats.photos, "Photos")
                Spacer()
                if store.syncBusy { ProgressView().tint(.white) }
            }
            HStack(spacing: 22) {
                ForEach(DiaryLayout.allCases) { item in
                    Button { withAnimation(.snappy) { layout = item } } label: {
                        VStack(spacing: 6) {
                            Text(item.rawValue).font(.subheadline.weight(.semibold))
                                .opacity(layout == item ? 1 : 0.7)
                            Capsule().frame(height: 3).opacity(layout == item ? 1 : 0)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.blue)
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(.title3.bold())
            Text(label.uppercased()).font(.caption2.weight(.semibold)).opacity(0.8)
        }
    }

    // MARK: Layouts

    private var timeline: some View {
        List {
            header.listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
            if visible.isEmpty {
                emptyState.listRowSeparator(.hidden)
            }
            ForEach(monthSections(visible)) { section in
                Section {
                    ForEach(Array(section.entries.enumerated()), id: \.element.id) { i, entry in
                        let sameDay = i > 0 && Calendar.current.isDate(section.entries[i - 1].date, inSameDayAs: entry.date)
                        Button { path.append(.entry(entry.id, isNew: false)) } label: {
                            EntryRow(entry: entry, showDate: !sameDay)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { toDelete = entry } label: { Label("Delete", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button { store.toggleStar(entry) } label: {
                                Label(entry.starred ? "Unstar" : "Star", systemImage: entry.starred ? "star.slash" : "star")
                            }
                            .tint(.yellow)
                        }
                    }
                } header: {
                    Text(section.title).font(.headline).foregroundStyle(.primary).textCase(nil)
                }
            }
            Color.clear.frame(height: 80).listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .refreshable { await store.sync.syncNow() }
    }

    private var grid: some View {
        ScrollView {
            VStack(spacing: 0) {
                header.padding(.bottom, 12)
                switch layout {
                case .calendar:
                    CalendarGrid(entries: visible) { day in
                        let items = visible.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
                        if items.count == 1 { path.append(.entry(items[0].id, isNew: false)) } else { path.append(.day(day)) }
                    }
                default:
                    MediaGrid(entries: visible) { path.append(.entry($0.id, isNew: false)) }
                }
                Color.clear.frame(height: 90)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(search.isEmpty ? "No Entries" : "No Results", systemImage: "book.closed")
        } description: {
            Text(search.isEmpty ? "Tap + to write your first entry. Hold it to start with a photo." : "Nothing matches \"\(search)\".")
        }
        .padding(.top, 40)
    }

    // MARK: Toolbar and new entries

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Show", selection: $filter) {
                    Label("All Entries", systemImage: "book").tag(DiaryFilter.all)
                    Label("Starred", systemImage: "star").tag(DiaryFilter.starred)
                    Label("On This Day", systemImage: "clock.arrow.circlepath").tag(DiaryFilter.onThisDay)
                }
                let tags = store.allTags
                if !tags.isEmpty {
                    Picker("Tags", selection: $filter) {
                        ForEach(tags, id: \.name) { tag in
                            Text("#\(tag.name)  \(tag.count)").tag(DiaryFilter.tag(tag.name))
                        }
                    }
                    .pickerStyle(.menu)
                }
            } label: {
                Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(.white)
            }
            .tint(.white)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showSettings = true } label: { Image(systemName: "gearshape").foregroundStyle(.white) }
            Button { store.lock() } label: { Image(systemName: "lock").foregroundStyle(.white) }
        }
    }

    private var newEntryButton: some View {
        Menu {
            Button { showPicker = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .background(Theme.blue, in: Circle())
                .shadow(color: Theme.blueDeep.opacity(0.45), radius: 10, y: 4)
        } primaryAction: {
            newEntry()
        }
        .padding(.trailing, 20)
        .padding(.bottom, 12)
    }

    private func newEntry() {
        let entry = store.newDraft()
        if case .tag(let tag) = filter {
            var tagged = entry
            tagged.tags = [tag]
            store.save(tagged)
        }
        path.append(.entry(entry.id, isNew: true))
    }

    private func newEntry(with images: [Data]) async {
        var ids: [UUID] = []
        for data in images { if let id = await store.addPhoto(data) { ids.append(id) } }
        guard !ids.isEmpty else { return }
        let entry = store.newDraft(photoIDs: ids)
        path.append(.entry(entry.id, isNew: true))
    }
}
