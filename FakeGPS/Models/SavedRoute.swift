import Foundation

struct SavedRoute: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var points: [RoutePoint]

    var summary: String {
        "\(points.count) 個點"
    }
}

@MainActor
class SavedRouteStore: ObservableObject {
    @Published var routes: [SavedRoute] = []

    private static let key = "SavedRoutes"

    init() {
        load()
    }

    func add(name: String, points: [RoutePoint]) {
        let route = SavedRoute(name: name, points: points)
        routes.append(route)
        save()
    }

    func delete(_ route: SavedRoute) {
        routes.removeAll { $0.id == route.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(routes) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([SavedRoute].self, from: data) else { return }
        routes = decoded
    }
}
