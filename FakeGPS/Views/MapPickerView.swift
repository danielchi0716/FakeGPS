import SwiftUI
import MapKit

struct MapPickerView: View {
    @Binding var selectedLatitude: Double
    @Binding var selectedLongitude: Double

    var routePoints: [RoutePoint] = []
    var currentPosition: CLLocationCoordinate2D?
    var onDoubleClick: ((CLLocationCoordinate2D) -> Void)?

    /// Set this to a route point index to move the camera there.
    @Binding var focusRoutePointIndex: Int?

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    )

    @State private var pinLocation: CLLocationCoordinate2D?
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var currentZoom: MKCoordinateSpan = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    @State private var userLocation: CLLocationCoordinate2D?

    var body: some View {
        ZStack(alignment: .top) {
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    // Selected pin
                    if let pin = pinLocation {
                        Marker("選擇的位置", coordinate: pin)
                            .tint(.red)
                    }

                    // User's real location (blue dot)
                    if let loc = userLocation {
                        Annotation("", coordinate: loc) {
                            ZStack {
                                Circle()
                                    .fill(.blue.opacity(0.2))
                                    .frame(width: 28, height: 28)
                                Circle()
                                    .fill(.blue)
                                    .frame(width: 10, height: 10)
                                    .overlay(
                                        Circle()
                                            .stroke(.white, lineWidth: 2)
                                    )
                            }
                        }
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
                .onTapGesture(count: 2) { screenCoord in
                    if let coordinate = proxy.convert(screenCoord, from: .local) {
                        pinLocation = coordinate
                        selectedLatitude = coordinate.latitude
                        selectedLongitude = coordinate.longitude
                        onDoubleClick?(coordinate)
                    }
                }
                .onTapGesture { screenCoord in
                    if let coordinate = proxy.convert(screenCoord, from: .local) {
                        // Only update pin and coordinates, don't move camera
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
            .onMapCameraChange { context in
                currentZoom = context.region.span
            }
            // Sync pin when coordinates change from external source (e.g. coordinate input),
            // but don't move camera
            .onChange(of: selectedLatitude) { _, _ in syncPinOnly() }
            .onChange(of: selectedLongitude) { _, _ in syncPinOnly() }
            // Navigate to route point when requested
            .onChange(of: focusRoutePointIndex) { _, index in
                if let index, routePoints.indices.contains(index) {
                    let coord = routePoints[index].coordinate
                    withAnimation {
                        cameraPosition = .region(
                            MKCoordinateRegion(center: coord, span: currentZoom)
                        )
                    }
                    focusRoutePointIndex = nil
                }
            }

            // Search bar overlay
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜尋地點...", text: $searchText)
                            .textFieldStyle(.plain)
                            .onSubmit { searchLocation() }
                    }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

                    Button {
                        jumpToSelectedPin()
                    } label: {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.body)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .help("移動到選擇的位置")
                    .disabled(pinLocation == nil)

                    Button {
                        Task { await jumpToCurrentLocation() }
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.body)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .help("跳到目前位置")
                }
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

    /// Update pin position without moving camera.
    private func syncPinOnly() {
        pinLocation = CLLocationCoordinate2D(latitude: selectedLatitude, longitude: selectedLongitude)
    }

    private func searchLocation() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        let search = MKLocalSearch(request: request)
        search.start { response, _ in
            searchResults = response?.mapItems ?? []
        }
    }

    private func jumpToSelectedPin() {
        guard let pin = pinLocation else { return }
        withAnimation {
            cameraPosition = .region(
                MKCoordinateRegion(center: pin, span: currentZoom)
            )
        }
    }

    /// Jump camera to Mac's current location and show blue dot, without changing pin.
    private func jumpToCurrentLocation() async {
        let helper = LocationHelper()
        if let coord = await helper.getCurrentLocation() {
            userLocation = coord
            withAnimation {
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    )
                )
            }
        }
    }

    private func selectSearchResult(_ item: MKMapItem) {
        let coord = item.placemark.coordinate
        pinLocation = coord
        selectedLatitude = coord.latitude
        selectedLongitude = coord.longitude
        searchResults = []
        searchText = item.name ?? ""

        withAnimation {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )
            )
        }
    }
}

#Preview {
    MapPickerView(
        selectedLatitude: .constant(25.033),
        selectedLongitude: .constant(121.5654),
        focusRoutePointIndex: .constant(nil)
    )
}
