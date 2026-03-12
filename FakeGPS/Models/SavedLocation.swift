import Foundation

struct SavedLocation: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
}

@MainActor
class SavedLocationStore: ObservableObject {
    @Published var locations: [SavedLocation] = []

    private static let key = "SavedLocations"

    init() {
        load()
    }

    func add(name: String, latitude: Double, longitude: Double) {
        let location = SavedLocation(name: name, latitude: latitude, longitude: longitude)
        locations.append(location)
        save()
    }

    func delete(_ location: SavedLocation) {
        locations.removeAll { $0.id == location.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(locations) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([SavedLocation].self, from: data) else { return }
        locations = decoded
    }
}
