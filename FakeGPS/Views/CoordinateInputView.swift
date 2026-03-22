import SwiftUI

struct CoordinateInputView: View {
    @Binding var latitude: Double
    @Binding var longitude: Double

    @State private var latText: String = ""
    @State private var lonText: String = ""
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("緯度") {
                TextField("-90 ~ 90", text: $latText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit { applyCoordinates() }
            }

            LabeledContent("經度") {
                TextField("-180 ~ 180", text: $lonText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit { applyCoordinates() }
            }

            if let error = validationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

        }
        .onAppear { syncFromBinding() }
        .onChange(of: latitude) { _, _ in syncFromBinding() }
        .onChange(of: longitude) { _, _ in syncFromBinding() }
    }

    private func syncFromBinding() {
        let newLat = String(format: "%.6f", latitude)
        let newLon = String(format: "%.6f", longitude)
        if latText != newLat { latText = newLat }
        if lonText != newLon { lonText = newLon }
    }

    private func applyCoordinates() {
        guard let lat = Double(latText), (-90...90).contains(lat) else {
            validationError = "緯度必須在 -90 到 90 之間"
            return
        }
        guard let lon = Double(lonText), (-180...180).contains(lon) else {
            validationError = "經度必須在 -180 到 180 之間"
            return
        }

        validationError = nil
        latitude = lat
        longitude = lon
    }
}

#Preview {
    CoordinateInputView(latitude: .constant(25.033), longitude: .constant(121.5654))
        .padding()
}
