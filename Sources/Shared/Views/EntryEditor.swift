import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct PhotoRef: Identifiable { let id: UUID }

/// Writing and reading are the same screen, as in Day One. Saves as you type; an entry left empty is discarded.
struct EntryEditor: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var autofocus = false
    var onDelete: () -> Void = {}

    @State private var draft: Entry
    @State private var addedPhotos: Set<UUID> = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showDate = false
    @State private var confirmDelete = false
    @State private var deleted = false
    @State private var viewing: PhotoRef?
    @State private var newTag = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var addingPhotos = 0
    @State private var recorder = VoiceRecorder()
    @State private var addedAudio: Set<UUID> = []
    @State private var recordError: String?
    @FocusState private var tagFocused: Bool

    init(entry: Entry, autofocus: Bool = false, onDelete: @escaping () -> Void = {}) {
        _draft = State(initialValue: entry)
        self.autofocus = autofocus
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Day One for Mac: date on top, then text, photos and voice notes in one scroll, tags and tools below.
            HStack {
                dateLabel
                Spacer()
                starButton
                moreMenu
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DiaryTextView(text: $draft.text, autofocus: autofocus && draft.text.isEmpty, scrolls: false, onImages: add)
                    ForEach(draft.photoIDs, id: \.self) { id in
                        InlinePhoto(id: id)
                            .onTapGesture { viewing = PhotoRef(id: id) }
                            .contextMenu { photoMenu(id) }
                            .padding(.horizontal, 28)
                    }
                    voiceNotes.padding(.horizontal, 28)
                    if let location = draft.location {
                        LocationCard(location: location, height: 170).padding(.horizontal, 28)
                    }
                }
                .padding(.bottom, 24)
            }
            if recorder.isRecording {
                RecordingBar(recorder: recorder, onStop: stopRecording, onCancel: recorder.cancel)
            }
            Divider()
            HStack(spacing: 0) {
                tagBar.frame(maxWidth: .infinity, alignment: .leading)
                actionBar
            }
            #else
            photos
            voiceNotes.padding(.horizontal, 18).padding(.top, draft.audio.isEmpty ? 0 : 10)
            DiaryTextView(text: $draft.text, autofocus: autofocus && draft.text.isEmpty, onImages: add)
            if let location = draft.location {
                LocationRow(location: location).padding(.horizontal, 18).padding(.top, 6)
            }
            tagBar
            #endif
        }
        .alert("Can't Record", isPresented: Binding(get: { recordError != nil }, set: { if !$0 { recordError = nil } })) {
            Button("OK") { recordError = nil }
        } message: {
            Text(recordError ?? "")
        }
        .onAppear { store.editorOpened(draft.id) }
        .task { await addLocationIfNew() }
        .onChange(of: store.finishedTranscripts.keys.map(\.uuidString).sorted()) { _, _ in
            for note in draft.audio {
                guard let result = store.takeTranscript(note.id) else { continue }
                draft.apply(transcript: result.text, to: note.id)
                if let i = draft.audio.firstIndex(where: { $0.id == note.id }) { draft.audio[i].language = result.language }
            }
        }
        #if os(iOS)
        .navigationTitle(draft.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                starButton
                moreMenu
            }
        }
        .safeAreaInset(edge: .bottom) {
            if recorder.isRecording {
                RecordingBar(recorder: recorder, onStop: stopRecording, onCancel: recorder.cancel)
            } else {
                actionBar.background(.bar)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { if let data = $0.jpegData(compressionQuality: 0.95) { add([data]) } }.ignoresSafeArea()
        }
        .fullScreenCover(item: $viewing) { PhotoViewer(id: $0.id) }
        #else
        .sheet(item: $viewing) { PhotoViewer(id: $0.id) }
        .background(Color(nsColor: .textBackgroundColor))
        #endif
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { add([data]) }
                }
            }
        }
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onDisappear {
            saveTask?.cancel()
            recorder.cancel()
            guard !deleted else { store.editorClosed(draft.id); return }
            store.save(draft)
            store.editorClosed(draft.id)
            store.discardIfEmpty(draft.id)
        }
        .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Entry", role: .destructive) {
                deleted = true
                store.delete(draft)
                onDelete()
                dismiss()
            }
        } message: {
            Text("It will be deleted on all your devices.")
        }
    }

    // MARK: Pieces

    private var dateLabel: some View {
        Button { showDate = true } label: {
            HStack(spacing: 6) {
                Text(draft.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                    .fontWeight(.semibold)
                Text(draft.date.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDate) {
            VStack {
                DatePicker("Entry date", selection: $draft.date).datePickerStyle(.graphical).labelsHidden()
                Button("Now") { draft.date = .now }
            }
            .padding()
            .frame(minWidth: 320)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var starButton: some View {
        Button { draft.starred.toggle() } label: {
            Image(systemName: draft.starred ? "star.fill" : "star")
                .foregroundStyle(draft.starred ? .yellow : .secondary)
        }
        .help(draft.starred ? "Unstar" : "Star")
    }

    private var moreMenu: some View {
        Menu {
            #if os(iOS)
            Button { showDate = true } label: { Label("Change Date", systemImage: "calendar") }
            #endif
            if draft.location == nil {
                Button { Task { await addCurrentLocation() } } label: { Label("Add Current Location", systemImage: "location") }
            } else {
                Button { draft.location = nil } label: { Label("Remove Location", systemImage: "location.slash") }
            }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Entry", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        #if os(macOS)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
    }

    private var actionBar: some View {
        HStack(spacing: 22) {
            Button(action: startRecording) { Image(systemName: "mic") }
                .help("Record a voice note")
                .disabled(recorder.isRecording)
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                Image(systemName: "photo.on.rectangle.angled")
            }
            .help("Add photos from your library")
            #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Image(systemName: "camera") }
            }
            PasteButton(supportedContentTypes: [.image]) { providers in
                for p in providers {
                    _ = p.loadDataRepresentation(for: .image) { data, _ in
                        if let data { Task { @MainActor in add([data]) } }
                    }
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            #endif
            Button { tagFocused = true } label: { Image(systemName: "number") }
                .help("Add a tag")
            #if os(iOS)
            Button { showDate = true } label: { Image(systemName: "calendar") }
            Spacer()
            if addingPhotos > 0 { ProgressView() }
            Text("\(wordCount) words").font(.caption).foregroundStyle(.secondary)
            #else
            if addingPhotos > 0 { ProgressView().controlSize(.small) }
            #endif
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .tint(Theme.accent)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        #if os(iOS)
        .overlay(alignment: .top) { Divider() }
        #endif
    }

    @ViewBuilder private var photos: some View {
        if draft.photoIDs.count == 1, let id = draft.photoIDs.first {
            PhotoThumb(id: id, cornerRadius: 0, maxPixel: 1600)
                .frame(height: 260)
                .frame(maxWidth: .infinity)
                .clipped()
                .onTapGesture { viewing = PhotoRef(id: id) }
                .contextMenu { photoMenu(id) }
        } else if !draft.photoIDs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(draft.photoIDs, id: \.self) { id in
                        PhotoThumb(id: id, side: 130, cornerRadius: 10)
                            .onTapGesture { viewing = PhotoRef(id: id) }
                            .contextMenu { photoMenu(id) }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder private func photoMenu(_ id: UUID) -> some View {
        Button { viewing = PhotoRef(id: id) } label: { Label("View", systemImage: "arrow.up.left.and.arrow.down.right") }
        Button(role: .destructive) { removePhoto(id) } label: { Label("Remove Photo", systemImage: "trash") }
    }

    @ViewBuilder private var voiceNotes: some View {
        if !draft.audio.isEmpty {
            VStack(spacing: 8) {
                ForEach(draft.audio) { note in
                    AudioNoteView(note: note, entryID: draft.id) { removeAudio(note.id) }
                }
            }
        }
    }

    /// New entries remember where they were written, as in Day One.
    private func addLocationIfNew() async {
        guard store.addLocation, draft.location == nil, Date.now.timeIntervalSince(draft.created) < 120 else { return }
        await addCurrentLocation()
    }

    private func addCurrentLocation() async {
        guard let here = await LocationProvider.shared.current() else { return }
        let location = await EntryLocation.describe(here)
        if draft.location == nil { draft.location = location }
    }

    private func startRecording() {
        Task {
            do { try await recorder.start() } catch { recordError = error.localizedDescription }
        }
    }

    private func stopRecording() {
        guard let (url, duration) = recorder.stop() else { return }
        let entryID = draft.id
        Task {
            guard let note = await store.addVoiceNote(file: url, duration: duration, entryID: entryID) else { return }
            draft.audio.append(note)
            addedAudio.insert(note.id)
            store.save(draft)   // so a transcript finishing after the editor closes finds the note
        }
    }

    private func removeAudio(_ id: UUID) {
        draft.audio.removeAll { $0.id == id }
        if addedAudio.remove(id) != nil { store.deleteAudio(id) }   // saved notes are removed when the entry saves
    }

    private var tagBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(draft.tags, id: \.self) { tag in
                        TagChip(tag: tag) { draft.tags.removeAll { $0 == tag } }
                    }
                    TextField("Add tag", text: $newTag)
                        .textFieldStyle(.plain)
                        .focused($tagFocused)
                        .frame(width: 140)
                        .onSubmit(addTag)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                .padding(.horizontal, 18)
            }
            let suggestions = tagSuggestions
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { tag in
                            Button { newTag = tag; addTag() } label: { TagChip(tag: tag).opacity(0.7) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: Actions

    private var tagSuggestions: [String] {
        guard tagFocused else { return [] }
        let q = newTag.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        return store.allTags.map(\.name)
            .filter { !draft.tags.contains($0) && (q.isEmpty || $0.localizedCaseInsensitiveContains(q)) }
            .prefix(12).map { $0 }
    }

    private var wordCount: Int { draft.text.split { $0.isWhitespace || $0.isNewline }.count }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        newTag = ""
        guard !tag.isEmpty, !draft.tags.contains(tag) else { return }
        draft.tags.append(tag)
    }

    private func add(_ images: [Data]) {
        addingPhotos += images.count
        Task {
            for data in images {
                if let id = await store.addPhoto(data) {
                    draft.photoIDs.append(id)
                    addedPhotos.insert(id)
                }
                addingPhotos -= 1
            }
        }
    }

    private func removePhoto(_ id: UUID) {
        draft.photoIDs.removeAll { $0 == id }
        if addedPhotos.remove(id) != nil { store.deletePhoto(id) }   // saved photos are removed when the entry saves
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = draft
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, !deleted else { return }
            store.save(snapshot)
        }
    }
}

#if os(iOS)
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif

/// A photo at full width and its own aspect ratio, as Day One shows photos inside an entry.
struct InlinePhoto: View {
    @Environment(DiaryStore.self) private var store
    let id: UUID
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(cgImage: image).resizable().scaledToFit().frame(maxHeight: 520)
            } else {
                Color.gray.opacity(0.12).frame(height: 240).overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: "\(id)-\(store.photoRevision)") { image = await store.image(id, maxPixel: 2000) }
    }
}
