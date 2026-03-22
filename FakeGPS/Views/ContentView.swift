import SwiftUI
import MapKit

struct ContentView: View {
    @EnvironmentObject var deviceManager: DeviceManager
    @StateObject private var routeSimulator = RouteSimulator()
    @StateObject private var savedLocationStore = SavedLocationStore()
    @StateObject private var savedRouteStore = SavedRouteStore()

    @State private var selectedLatitude: Double = 25.033
    @State private var selectedLongitude: Double = 121.5654
    @State private var selectedTab = 0 // 0: single point, 1: route

    var body: some View {
        VStack(spacing: 0) {
            // Main content
            HSplitView {
                leftPanel
                    .frame(minWidth: 270, idealWidth: 310, maxWidth: 370)

                MapPickerView(
                    selectedLatitude: $selectedLatitude,
                    selectedLongitude: $selectedLongitude,
                    routePoints: routeSimulator.routePoints,
                    currentPosition: routeSimulator.currentPosition
                )
            }

            Divider()

            statusBar
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.bar)
        }
        .frame(minWidth: 800, minHeight: 600)
        .task {
            // 取得目前位置作為預設座標
            let helper = LocationHelper()
            if let coord = await helper.getCurrentLocation() {
                selectedLatitude = coord.latitude
                selectedLongitude = coord.longitude
            }
            // 啟動 tunnel（會提示管理員密碼），啟動後自動偵測裝置
            await deviceManager.startTunnel()
            await deviceManager.detectDevice()
        }
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // ---- Device Section ----
                DeviceStatusView()

                Divider()

                // ---- Location Section ----
                locationSection
            }
            .padding()
        }
    }

    // MARK: - Location Section

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("定位控制", systemImage: "location")
                .font(.headline)

            // Mode picker
            Picker("模式", selection: $selectedTab) {
                Text("定點").tag(0)
                Text("路線").tag(1)
            }
            .pickerStyle(.segmented)

            if !isTunnelReady {
                GroupBox {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("請先啟動 Tunnel 再操作定位功能")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if selectedTab == 0 {
                singlePointPanel
                    .disabled(!isTunnelReady)
                    .opacity(isTunnelReady ? 1 : 0.5)
            } else {
                RouteView(routeSimulator: routeSimulator, savedRouteStore: savedRouteStore) {
                    routeSimulator.addPoint(
                        latitude: selectedLatitude,
                        longitude: selectedLongitude
                    )
                }
                .disabled(!isTunnelReady)
                .opacity(isTunnelReady ? 1 : 0.5)
            }

            Divider()

            SavedLocationsView(
                store: savedLocationStore,
                latitude: $selectedLatitude,
                longitude: $selectedLongitude
            ) {
                // 選取收藏地點時自動設定位置
                if isTunnelReady {
                    Task {
                        await deviceManager.setLocation(
                            latitude: selectedLatitude,
                            longitude: selectedLongitude
                        )
                    }
                }
            }

            // Error display
            if let error = deviceManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Single Point

    private var singlePointPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            CoordinateInputView(
                latitude: $selectedLatitude,
                longitude: $selectedLongitude
            )

            Button {
                Task {
                    await deviceManager.setLocation(
                        latitude: selectedLatitude,
                        longitude: selectedLongitude
                    )
                }
            } label: {
                Label("設定位置", systemImage: "location.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(deviceManager.selectedDeviceIDs.isEmpty)

            Button {
                Task { await deviceManager.clearLocation() }
            } label: {
                Label("重置定位", systemImage: "location.slash")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .disabled(!deviceManager.isSimulating)

            if deviceManager.isSimulating {
                Divider()

                JoystickControlView(
                    latitude: $selectedLatitude,
                    longitude: $selectedLongitude
                ) {
                    Task {
                        await deviceManager.setLocation(
                            latitude: selectedLatitude,
                            longitude: selectedLongitude
                        )
                    }
                }
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(deviceManager.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if routeSimulator.isRunning {
                Text("路線移動中 · \(Int(routeSimulator.speedMinKmh))–\(Int(routeSimulator.speedMaxKmh)) km/h")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            if let loc = deviceManager.simulatedLocation {
                Text(loc.displayString)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }

            Divider()
                .frame(height: 12)

            Link(destination: URL(string: "https://ko-fi.com/danielchi0716")!) {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                    Text("Buy me a coffee")
                }
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.pink, in: Capsule())
            }
        }
    }

    /// Tunnel 是否就緒（需要 tunnel 才能模擬定位）
    private var isTunnelReady: Bool {
        guard !deviceManager.selectedDeviceIDs.isEmpty else { return false }
        return deviceManager.tunnelRunning
    }

    private var statusColor: Color {
        if routeSimulator.isRunning { return .blue }
        if deviceManager.isSimulating { return .green }
        if !deviceManager.selectedDeviceIDs.isEmpty { return .orange }
        return .red
    }
}

#Preview {
    ContentView()
        .environmentObject(DeviceManager())
}
