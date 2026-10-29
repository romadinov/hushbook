import Foundation
import CoreLocation
import MapKit

/// Where an entry was written. Stored inside the sealed entry, so iCloud never sees it.
struct EntryLocation: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var name: String?        // street address or place, e.g. "66 Ormond Ave" / "Mordialloc Beach"
    var locality: String?    // e.g. "Mitcham, VIC"
    var country: String?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    /// "Mordialloc Beach, Mordialloc VIC", as Day One shows it.
    var title: String {
        let parts = [name, locality].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }

    var shortTitle: String { name ?? locality ?? title }

    /// Adds a place name from Apple's geocoder; keeps bare coordinates if that fails (e.g. offline).
    static func describe(_ location: CLLocation) async -> EntryLocation {
        var result = EntryLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        if let request = MKReverseGeocodingRequest(location: location),
           let item = try? await request.mapItems.first {
            result.name = item.name
            result.locality = item.addressRepresentations?.cityWithContext
            result.country = item.addressRepresentations?.regionName
        }
        return result
    }
}

/// One-shot "where am I", with the When In Use permission prompt the first time.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    private var authorized: Bool {
        #if os(iOS)
        [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus)
        #else
        manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized
        #endif
    }

    /// The current location, or nil if it's not allowed or not found within 15 s.
    func current() async -> CLLocation? {
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: break
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if authorized { manager.requestLocation() }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.finish(nil)
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(returning: location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard !waiters.isEmpty else { return }
            if authorized { manager.requestLocation() }
            else if manager.authorizationStatus != .notDetermined { finish(nil) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { finish(locations.last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }
}
