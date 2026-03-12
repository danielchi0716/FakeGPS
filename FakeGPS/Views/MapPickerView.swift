import SwiftUI
import MapKit

struct MapPickerView: View {
    @Binding var selectedLatitude: Double
    @Binding var selectedLongitude: Double

    var routePoints: [RoutePoint] = []
    var currentPosition: CLLocationCoordinate2D?

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    )

    @State private var pinLocation: CLLocationCoordinate2D?
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []

    var body: some View {
        ZStack(alignment: .top) {
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    // Selected pin
                    if let pin = pinLocation {
                        Marker("選擇的位置", coordinate: pin)
                            .tint(.red)
                    }

                    // Route points
                    ForEach(Array(routePoints.enumerated()), id: \.element.id) { index, point in
                        Annotation("", coordinate: point.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(.blue)
                                    .frame(width: 24, height: 24)
                                Text("\(index + 1)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                            }
                        }
                    }

                    // Route line
                    if routePoints.count >= 2 {
                        let coords = routePoints.map(\.coordinate) + [routePoints[0].coordinate]
                        MapPolyline(coordinates: coords)
                            .stroke(.blue.opacity(0.6), lineWidth: 3)
                    }

                    // Current simulation position
                    if let pos = currentPosition {
                        Annotation("", coordinate: pos) {
                            Circle()
                                .fill(.green)
                                .frame(width: 14, height: 14)
                                .overlay(
                                    Circle()
                                        .stroke(.white, lineWidth: 2)
                                )
                                .shadow(radius: 3)
                        }
                    }
                }
                .onTapGesture { screenCoord in
                    if let coordinate = proxy.convert(screenCoord, from: .local) {
                        pinLocation = coordinate
                        selectedLatitude = coordinate.latitude
                        selectedLongitude = coordinate.longitude
                    }
                }
                .mapControls {
                    MapCompass()
                    MapScaleView()
                    MapZoomStepper()
                }
            }

            // Search bar overlay
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜尋地點...", text: $searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { searchLocation() }
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .padding(.top, 8)

                if !searchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(searchResults.prefix(5), id: \.self) { item in
                            Button {
                                selectSearchResult(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "未知地點")
                                        .font(.body)
                                    if let subtitle = item.placemark.title {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
                }
            }
        }
    }

    private func searchLocation() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        let search = MKLocalSearch(request: request)
        search.start { response, _ in
            searchResults = response?.mapItems ?? []
        }
    }

    private func selectSearchResult(_ item: MKMapItem) {
        let coord = item.placemark.coordinate
        pinLocation = coord
        selectedLatitude = coord.latitude
        selectedLongitude = coord.longitude
        searchResults = []
        searchText = item.name ?? ""

        cameraPosition = .region(
            MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        )
    }
}

#Preview {
    MapPickerView(
        selectedLatitude: .constant(25.033),
        selectedLongitude: .constant(121.5654)
    )
}
