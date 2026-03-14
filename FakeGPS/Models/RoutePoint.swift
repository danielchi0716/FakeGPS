import Foundation
import CoreLocation

struct RoutePoint: Identifiable, Equatable, Codable {
    let id = UUID()
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayString: String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }

    /// Distance to another point in meters (Haversine formula)
    func distance(to other: RoutePoint) -> Double {
        let loc1 = CLLocation(latitude: latitude, longitude: longitude)
        let loc2 = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return loc1.distance(from: loc2)
    }
}
