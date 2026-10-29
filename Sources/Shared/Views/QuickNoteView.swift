import SwiftUI
import PhotosUI

/// The note being written in the quick note window. Kept in memory only, so closing the menu bar window or the sheet
/// by accident doesn't lose it; nothing is written to disk until it is sealed.
@MainActor @Observable
final class QuickNoteDraft {
    static let shared = QuickNoteDraft()

    var text = ""
    var photos: [QuickNote.Photo] = []
    /// Shows the quick note sheet (lock screen button, Home Screen quick action, Shortcuts).
    var isPresented = false

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty }

    func clear() { text = ""; photos = [] }
}

/// Write a note without unlocking. It is sealed so that only the unlocked diary can read it: this window never shows
/// anything from the diary, including notes written here before.
struct QuickNoteView: View {
    @Environment(DiaryStore.self) private var store
    @Bindable var draft = QuickNoteDraft.shared
    var onClose: () -> Void

    @State private var location: EntryLocation?
    @State private var saving = false
    @State private var saved = false
    @State private var showPhotoPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !store.canTakeQuickNotes {
                ContentUnavailableView("Unlock Once First", systemImage: "lock",
                                       description: Text("Quick notes are sealed with a key from your diary. Unlock Hushbook on this device once to turn them on."))
            } else if saved {
                ContentUnavailableView("Sealed", systemImage: "checkmark.seal.fill",
                                       description: Text("Your note is locked away. It appears in your diary when you unlock it."))
                    .foregroundStyle(Theme.accent)
            } else {
                DiaryTextView(text: $draft.text, autofocus: true) { add($0) }
                if !draft.photos.isEmpty { photoStrip }
                footer
            }
        }
        .task { await findLocation() }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task {
                for item in items {
                    if let picked = try? await item.loadTransferable(type: PickedImage.self) { add([picked.data]) }
                    else { error = "A photo couldn't be read." }
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems, maxSelectionCount: 20, matching: .images,
                      preferredItemEncoding: .compatible)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            add(urls.compactMap { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try? Data(contentsOf: url)
            })
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { if let data = $0.jpegData(compressionQuality: 0.95) { add([data]) } }.ignoresSafeArea()
        }
        #endif
        .alert("Couldn't Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var header: some View {
        HStack {
            Button(saved ? "Done" : "Cancel") { close() }
            Spacer()
            Label("Quick Hashnote", systemImage: "lock.fill").font(.headline).labelStyle(.titleAndIcon)
            Spacer()
            if saved {
                Button("New Note") { saved = false }
            } else {
                Button("Save") { Task { await save() } }
                    .fontWeight(.semibold)
                    .disabled(draft.isEmpty || saving || !store.canTakeQuickNotes)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var photoStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.photos, id: \.id) { photo in
                    DraftThumb(jpeg: photo.jpeg)
                        .overlay(alignment: .topTrailing) {
                            Button { draft.photos.removeAll { $0.id == photo.id } } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(3)
                        }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 76)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            #if os(iOS)
            Button { showCamera = true } label: { Image(systemName: "camera") }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button { showPhotoPicker = true } label: { Image(systemName: "photo.on.rectangle") }
            #else
            Menu {
                Button("Photos Library…") { showPhotoPicker = true }
                Button("Choose Files…") { showFileImporter = true }
            } label: { Image(systemName: "photo.on.rectangle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            #endif
            if let location {
                Label(location.shortTitle, systemImage: "location.fill").lineLimit(1)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Readable only after unlocking").font(.caption).foregroundStyle(.secondary)
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func add(_ images: [Data]) {
        Task {
            let jpegs = await Task.detached { images.compactMap { Images.normalized($0) } }.value
            if jpegs.count < images.count { error = "A photo couldn't be read." }
            draft.photos += jpegs.map { QuickNote.Photo(jpeg: $0) }
        }
    }

    private func findLocation() async {
        guard store.addLocation, location == nil, store.canTakeQuickNotes,
              let here = await LocationProvider.shared.current() else { return }
        location = await EntryLocation.describe(here)
    }

    private func save() async {
        guard !draft.isEmpty, !saving else { return }
        saving = true
        defer { saving = false }
        guard await store.addQuickNote(text: draft.text, photos: draft.photos, location: location) else {
            error = "The note couldn't be sealed. Unlock Hushbook once on this device and try again."
            return
        }
        draft.clear()
        saved = true
    }

    private func close() {
        saved = false
        onClose()
    }
}

/// A picked photo before sealing, decoded from the in-memory JPEG.
private struct DraftThumb: View {
    let jpeg: Data
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image { Image(cgImage: image).resizable().scaledToFill() } else { Color.gray.opacity(0.15) }
        }
        .frame(width: 68, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task { image = await Task.detached { [jpeg] in Images.cgImage(jpeg, maxPixel: 200) }.value }
    }
}
