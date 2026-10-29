import SwiftUI
import MapKit

/// The small map in an entry: a pin and the place name. Tapping opens a larger, movable map.
struct LocationCard: View {
    let location: EntryLocation
    var height: CGFloat = 150
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Map(initialPosition: .region(MKCoordinateRegion(center: location.coordinate,
                                                            latitudinalMeters: 900, longitudinalMeters: 900)),
                interactionModes: []) {
                Marker(location.shortTitle, coordinate: location.coordinate).tint(Theme.accent)
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { expanded = true }
            Label(location.title, systemImage: "mappin.and.ellipse")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .sheet(isPresented: $expanded) { LocationDetail(location: location) }
    }
}

/// A compact row for the iPhone editor, where the text needs the room: thumbnail map and place name.
struct LocationRow: View {
    let location: EntryLocation
    @State private var expanded = false

    var body: some View {
        Button { expanded = true } label: {
            HStack(spacing: 10) {
                Map(initialPosition: .region(MKCoordinateRegion(center: location.coordinate,
                                                                latitudinalMeters: 1200, longitudinalMeters: 1200)),
                    interactionModes: []) {
                    Marker("", coordinate: location.coordinate).tint(Theme.accent)
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .allowsHitTesting(false)
                Text(location.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $expanded) { LocationDetail(location: location) }
    }
}

private struct LocationDetail: View {
    let location: EntryLocation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Map(initialPosition: .region(MKCoordinateRegion(center: location.coordinate,
                                                            latitudinalMeters: 2000, longitudinalMeters: 2000))) {
                Marker(location.shortTitle, coordinate: location.coordinate).tint(Theme.accent)
            }
            .navigationTitle(location.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Open in Maps") {
                        let item = MKMapItem(location: CLLocation(latitude: location.latitude, longitude: location.longitude),
                                             address: nil)
                        item.name = location.shortTitle
                        item.openInMaps()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        #endif
    }
}

/// Day One's Map view: every entry with a location as a pin (its photo, if it has one).
struct EntriesMap: View {
    @Environment(DiaryStore.self) private var store
    let entries: [Entry]
    let onOpen: (Entry) -> Void

    var body: some View {
        let located = entries.filter { $0.location != nil }
        if located.isEmpty {
            ContentUnavailableView("No Places Yet", systemImage: "map",
                                   description: Text("New entries remember where you wrote them."))
        } else {
            Map(initialPosition: .automatic) {
                ForEach(located) { entry in
                    Annotation(entry.title.isEmpty ? entry.date.formatted(date: .abbreviated, time: .omitted) : entry.title,
                               coordinate: entry.location!.coordinate) {
                        // Annotation content is hosted outside this view tree: pass the store on explicitly.
                        Pin(entry: entry).environment(store).onTapGesture { onOpen(entry) }
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
        }
    }

    private struct Pin: View {
        let entry: Entry

        var body: some View {
            Group {
                if let photo = entry.photoIDs.first {
                    PhotoThumb(id: photo, side: 40, cornerRadius: 20)
                } else {
                    Text(entry.date.formatted(.dateTime.day()))
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Theme.accent, in: Circle())
                }
            }
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2, y: 1)
        }
    }
}
