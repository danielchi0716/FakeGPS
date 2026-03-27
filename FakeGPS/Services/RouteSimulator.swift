import Foundation
import CoreLocation

enum RouteMode: String, CaseIterable, Identifiable {
    case oneWay = "點到點"
    case pingPong = "來回"
    case loop = "循環"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .oneWay: return "arrow.right"
        case .pingPong: return "arrow.left.arrow.right"
        case .loop: return "repeat"
        }
    }
}

@MainActor
class RouteSimulator: ObservableObject {
    @Published var routePoints: [RoutePoint] = []
    @Published var isRunning = false
    @Published var speedMinKmh: Double = 15.0
    @Published var speedMaxKmh: Double = 20.0
    @Published var driftEnabled: Bool = true
    @Published var routeMode: RouteMode = .loop
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

            let mode = self.routeMode
            // Build the sequence of point indices based on mode
            var segmentIndices = self.buildSegmentIndices(mode: mode)
            var segPos = 0

            while !Task.isCancelled && self.isRunning {
                if segPos >= segmentIndices.count {
                    // Reached the end of the sequence
                    switch mode {
                    case .oneWay:
                        // Done — stay at last point
                        self.stop()
                        return
                    case .pingPong:
                        // Rebuild reversed sequence for next pass
                        segmentIndices = self.buildSegmentIndices(mode: mode)
                        segPos = 0
                    case .loop:
                        segPos = 0
                    }
                }

                let fromIdx = segmentIndices[segPos]
                let toIdx = segmentIndices[(segPos + 1) % segmentIndices.count]
                // For oneWay/pingPong, toIdx is the next element in the sequence
                let nextIdx = segPos + 1 < segmentIndices.count ? segmentIndices[segPos + 1] : segmentIndices[segPos]

                let from = self.routePoints[fromIdx]
                let to = self.routePoints[nextIdx]

                self.currentPointIndex = fromIdx

                await self.walkSegment(from: from, to: to, setLocation: setLocation)

                if Task.isCancelled || !self.isRunning { return }

                segPos += 1
                if segPos < segmentIndices.count {
                    self.currentPointIndex = segmentIndices[segPos]
                }
            }
        }
    }

    /// Build the sequence of point indices for one pass of the route.
    private func buildSegmentIndices(mode: RouteMode) -> [Int] {
        let count = routePoints.count
        guard count >= 2 else { return [] }
        switch mode {
        case .oneWay:
            // 0, 1, 2, ..., N-1
            return Array(0..<count)
        case .pingPong:
            // 0, 1, 2, ..., N-1, N-2, ..., 1, 0
            return Array(0..<count) + Array((1..<count - 1).reversed()) + [0]
        case .loop:
            // 0, 1, 2, ..., N-1, 0 (wraps back to start)
            return Array(0..<count) + [0]
        }
    }

    /// Walk from one point to another with interpolation, drift, and speed randomization.
    private func walkSegment(
        from: RoutePoint, to: RoutePoint,
        setLocation: @escaping (Double, Double) async -> Void
    ) async {
        let distanceMeters = from.distance(to: to)
        guard distanceMeters > 0 else { return }

        let avgSpeedMs = ((speedMinKmh + speedMaxKmh) / 2.0) * 1000.0 / 3600.0
        let segmentDuration = distanceMeters / avgSpeedMs
        let steps = max(1, Int(segmentDuration / updateInterval))

        var accumulated = 0.0
        let useDrift = driftEnabled
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
            if Task.isCancelled || !isRunning { return }

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

            currentPosition = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            progress = t

            await setLocation(lat, lon)

            if step < steps {
                let randomSpeed = Double.random(in: speedMinKmh...speedMaxKmh)
                let stepDistanceMeters = (randomSpeed * 1000.0 / 3600.0) * updateInterval
                accumulated += stepDistanceMeters

                if useDrift {
                    currentDrift += Double.random(in: -0.3...0.3)
                    currentDrift = max(-1.0, min(1.0, currentDrift))
                }

                try? await Task.sleep(for: .seconds(updateInterval))
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
