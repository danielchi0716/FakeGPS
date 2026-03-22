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
            let helper = LocationHelper()
            if let coord = await helper.getCurrentLocation() {
                selectedLatitude = coord.latitude
                selectedLongitude = coord.longitude
            }
            await deviceManager.startTunnel()
            await deviceManager.detectDevice()
        }
        .alert("裝置已斷線", isPresented: showDisconnectAlert) {
            Button("確定") {
                routeSimulator.stop()
                deviceManager.disconnectedDeviceNames = []
            }
        } message: {
            Text("\(deviceManager.disconnectedDeviceNames.joined(separator: "、")) 已斷線，模擬已停止。")
        }
        .onChange(of: deviceManager.disconnectedDeviceNames) { _, names in
            if !names.isEmpty {
                routeSimulator.stop()
            }
        }
    }

    private var showDisconnectAlert: Binding<Bool> {
        Binding(
            get: { !deviceManager.disconnectedDeviceNames.isEmpty },
            set: { if !$0 { deviceManager.disconnectedDeviceNames = [] } }
        )
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(spacing: 0) {
            ConnectionBarView()

            Divider()

            if !deviceManager.devicesConfirmed {
                // Step: Device selection
                deviceSelectionPanel
            } else {
                // Step: Simulation controls
                ScrollView {
                    VStack(alignment: .leading, spacing: FGSpacing.section) {
                        // Mode picker
                        Picker("模式", selection: $selectedTab) {
                            Text("定點").tag(0)
                            Text("路線").tag(1)
                        }
                        .pickerStyle(.segmented)

                        if selectedTab == 0 {
                            singlePointSection
                        } else {
                            routeSection
                        }

                        if let error = deviceManager.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(8)
                                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(FGSpacing.panelPadding)
                }

                Divider()

                savedItemsPanel
            }
        }
    }

    // MARK: - Device Selection

    private var deviceSelectionPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: FGSpacing.item) {
                    Label("選擇裝置", systemImage: "iphone.gen3")
                        .font(.headline)

                    if deviceManager.devices.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "iphone.slash")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("未偵測到裝置")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("請確認 iPhone 已透過 USB 或 Wi-Fi 連接")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        if deviceManager.devices.count > 1 {
                            HStack(spacing: 8) {
                                Button("全選") { deviceManager.selectAllDevices() }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .disabled(deviceManager.selectedDeviceIDs.count == deviceManager.devices.count)
                                Button("取消全選") { deviceManager.deselectAllDevices() }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .disabled(deviceManager.selectedDeviceIDs.isEmpty)
                            }
                        }

                        ForEach(deviceManager.devices) { device in
                            let isSelected = deviceManager.selectedDeviceIDs.contains(device.id)
                            HStack(spacing: 8) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? .blue : .secondary)
                                    .font(.body)
                                connectionIcon(for: device)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.callout)
                                        .fontWeight(isSelected ? .semibold : .medium)
                                    Text("\(device.productType) · iOS \(device.osVersion)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .cardStyle(isSelected: isSelected)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                deviceManager.toggleDevice(device)
                            }
                        }
                    }
                }
                .padding(FGSpacing.panelPadding)
            }

            Divider()

            // Confirm button
            Button {
                deviceManager.devicesConfirmed = true
            } label: {
                Label("確認選擇", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(deviceManager.selectedDeviceIDs.isEmpty)
            .padding(FGSpacing.panelPadding)
        }
    }

    // MARK: - Single Point

    private var singlePointSection: some View {
        VStack(alignment: .leading, spacing: FGSpacing.item) {
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

            if deviceManager.isSimulating {
                Button {
                    Task { await deviceManager.clearLocation() }
                } label: {
                    Label("重置定位", systemImage: "location.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if deviceManager.isSimulating {
                DisclosureGroup("移動控制") {
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
    }

    // MARK: - Route

    private var routeSection: some View {
        RouteView(routeSimulator: routeSimulator, savedRouteStore: savedRouteStore) {
            routeSimulator.addPoint(
                latitude: selectedLatitude,
                longitude: selectedLongitude
            )
        }
    }

    // MARK: - Saved Items (fixed bottom panel)

    private var savedItemsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.item) {
                if selectedTab == 0 {
                    SavedLocationsView(
                        store: savedLocationStore,
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
                } else {
                    SavedRoutesView(
                        store: savedRouteStore,
                        currentPoints: routeSimulator.routePoints
                    ) { points in
                        routeSimulator.loadPoints(points)
                    }
                }
            }
            .padding(FGSpacing.panelPadding)
        }
        .frame(maxHeight: 200)
        .background(.bar.opacity(0.5))
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

    // MARK: - Helpers

    @ViewBuilder
    private func connectionIcon(for device: DeviceInfo) -> some View {
        if device.connectionType == .network {
            Image(systemName: "wifi")
                .foregroundStyle(.green)
                .font(.caption)
        } else {
            Image(systemName: "cable.connector")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
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
