import Foundation
import CoreLocation

@MainActor
class RouteSimulator: ObservableObject {
    @Published var routePoints: [RoutePoint] = []
    @Published var isRunning = false
    @Published var speedMinKmh: Double = 15.0
    @Published var speedMaxKmh: Double = 20.0
    @Published var driftEnabled: Bool = true
    @Published var currentPointIndex = 0
    @Published var currentPosition: CLLocationCoordinate2D?
    @Published var progress: Double = 0 // 0~1 progress between current segment

    private var simulationTask: Task<Void, Never>?
    // Each setLocation call takes ~1s (process launch + kill wait), so effective interval ≈ 1s per step
    private let updateInterval: TimeInterval = 1.0

    var totalDistance: Double {
        guard routePoints.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<routePoints.count {
            let next = (i + 1) % routePoints.count
            total += routePoints[i].distance(to: routePoints[next])
        }
        return total
    }

    var totalDistanceFormatted: String {
        let d = totalDistance
        if d >= 1000 {
            return String(format: "%.2f km", d / 1000)
        }
        return String(format: "%.0f m", d)
    }

    func addPoint(latitude: Double, longitude: Double) {
        routePoints.append(RoutePoint(latitude: latitude, longitude: longitude))
    }

    func removePoint(at index: Int) {
        guard routePoints.indices.contains(index) else { return }
        routePoints.remove(at: index)
    }

    func movePoint(from source: IndexSet, to destination: Int) {
        routePoints.move(fromOffsets: source, toOffset: destination)
    }

    func loadPoints(_ points: [RoutePoint]) {
        stop()
        routePoints = points
    }

    func clearAllPoints() {
        stop()
        routePoints.removeAll()
    }

    func start(setLocation: @escaping (Double, Double) async -> Void) {
        guard routePoints.count >= 2 else { return }
        isRunning = true
        currentPointIndex = 0
        progress = 0

        simulationTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled && self.isRunning {
                let fromIdx = self.currentPointIndex
                let toIdx = (fromIdx + 1) % self.routePoints.count
                let from = self.routePoints[fromIdx]
                let to = self.routePoints[toIdx]

                let distanceMeters = from.distance(to: to)
                // Use midpoint speed to estimate total steps for the segment
                let avgSpeedMs = ((self.speedMinKmh + self.speedMaxKmh) / 2.0) * 1000.0 / 3600.0
                let segmentDuration = distanceMeters / avgSpeedMs
                let steps = max(1, Int(segmentDuration / self.updateInterval))

                var accumulated = 0.0 // accumulated distance traveled in meters

                let useDrift = self.driftEnabled
                var maxDriftLat = 0.0
                var maxDriftLon = 0.0
                var perpLat = 0.0
                var perpLon = 0.0

                if useDrift {
                    let maxDriftMeters = 3.0
                    maxDriftLat = maxDriftMeters / 111_320.0
                    let midLat = (from.latitude + to.latitude) / 2.0
                    maxDriftLon = maxDriftMeters / (111_320.0 * cos(midLat * .pi / 180.0))

                    let dLat = to.latitude - from.latitude
                    let dLon = to.longitude - from.longitude
                    let segLen = sqrt(dLat * dLat + dLon * dLon)
                    perpLat = segLen > 0 ? -dLon / segLen : 0
                    perpLon = segLen > 0 ? dLat / segLen : 0
                }

                var currentDrift = 0.0

                for step in 0...steps {
                    if Task.isCancelled || !self.isRunning { return }

                    let t = min(accumulated / distanceMeters, 1.0)
                    let baseLat = from.latitude + (to.latitude - from.latitude) * t
                    let baseLon = from.longitude + (to.longitude - from.longitude) * t

                    let lat: Double
                    let lon: Double
                    if useDrift {
                        let driftScale = 1.0 - abs(2.0 * t - 1.0)
                        lat = baseLat + perpLat * maxDriftLat * currentDrift * driftScale
                        lon = baseLon + perpLon * maxDriftLon * currentDrift * driftScale
                    } else {
                        lat = baseLat
                        lon = baseLon
                    }

                    self.currentPosition = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    self.progress = t

                    await setLocation(lat, lon)

                    if step < steps {
                        // Randomize speed for this step within the range
                        let randomSpeed = Double.random(in: self.speedMinKmh...self.speedMaxKmh)
                        let stepDistanceMeters = (randomSpeed * 1000.0 / 3600.0) * self.updateInterval
                        accumulated += stepDistanceMeters

                        if useDrift {
                            currentDrift += Double.random(in: -0.3...0.3)
                            currentDrift = max(-1.0, min(1.0, currentDrift))
                        }

                        try? await Task.sleep(for: .seconds(self.updateInterval))
                    }
                }

                self.currentPointIndex = toIdx
            }
        }
    }

    func stop() {
        isRunning = false
        simulationTask?.cancel()
        simulationTask = nil
        progress = 0
    }
}
