import CoreLocation

class LocationHelper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    func getCurrentLocation() async -> CLLocationCoordinate2D? {
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            manager.startUpdatingLocation()

            // Timeout after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.continuation != nil else { return }
                self.manager.stopUpdatingLocation()
                self.continuation?.resume(returning: nil)
                self.continuation = nil
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first, continuation != nil else { return }
        manager.stopUpdatingLocation()
        continuation?.resume(returning: location.coordinate)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard continuation != nil else { return }
        manager.stopUpdatingLocation()
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
