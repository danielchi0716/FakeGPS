import Foundation

enum ConnectionType: String, Equatable {
    case usb = "USB"
    case network = "Network"
}

struct DeviceInfo: Identifiable, Equatable {
    let id: String          // UDID
    let name: String        // Device name
    let productType: String // e.g. "iPhone15,2"
    let osVersion: String   // e.g. "17.4"
    let connectionType: ConnectionType

    var isiOS17OrLater: Bool {
        guard let major = osVersion.split(separator: ".").first,
              let majorInt = Int(major) else { return false }
        return majorInt >= 17
    }
}

struct SimulatedLocation: Equatable {
    let latitude: Double
    let longitude: Double

    var displayString: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }
}
