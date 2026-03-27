import SwiftUI

struct RouteView: View {
    @EnvironmentObject var deviceManager: DeviceManager
    @ObservedObject var routeSimulator: RouteSimulator
    @ObservedObject var savedRouteStore: SavedRouteStore
    @Binding var focusRoutePointIndex: Int?

    var onAddCurrentLocation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(routeSimulator.routePoints.count) 個路線點")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if routeSimulator.routePoints.count >= 2 {
                    Text(routeSimulator.totalDistanceFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Speed range control
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("速度範圍")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(routeSimulator.speedMinKmh))–\(Int(routeSimulator.speedMaxKmh)) km/h")
                        .font(.subheadline)
                        .monospacedDigit()
                }

                HStack(spacing: 4) {
                    Text("最低")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    Slider(value: $routeSimulator.speedMinKmh, in: 1...200, step: 1)
                        .disabled(routeSimulator.isRunning)
                        .onChange(of: routeSimulator.speedMinKmh) { _, newValue in
                            if newValue > routeSimulator.speedMaxKmh {
                                routeSimulator.speedMaxKmh = newValue
                            }
                        }
                }
                HStack(spacing: 4) {
                    Text("最高")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    Slider(value: $routeSimulator.speedMaxKmh, in: 1...200, step: 1)
                        .disabled(routeSimulator.isRunning)
                        .onChange(of: routeSimulator.speedMaxKmh) { _, newValue in
                            if newValue < routeSimulator.speedMinKmh {
                                routeSimulator.speedMinKmh = newValue
                            }
                        }
                }

                HStack(spacing: 12) {
                    ForEach([5, 30, 60, 120], id: \.self) { speed in
                        Button("\(speed)") {
                            routeSimulator.speedMinKmh = max(1, Double(speed) - 5)
                            routeSimulator.speedMaxKmh = Double(speed) + 5
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(routeSimulator.isRunning)
                    }
                }
            }

            // Route mode picker
            HStack {
                Text("模式")
                    .font(.subheadline)
                Spacer()
                Picker("", selection: $routeSimulator.routeMode) {
                    ForEach(RouteMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                .disabled(routeSimulator.isRunning)
            }

            Toggle("路徑漂移", isOn: $routeSimulator.driftEnabled)
                .font(.subheadline)
                .disabled(routeSimulator.isRunning)

            // Point list
            if routeSimulator.routePoints.isEmpty {
                Text("在地圖上雙擊可直接加入路線點，或點選位置後按「加入路線」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(routeSimulator.routePoints.enumerated()), id: \.element.id) { index, point in
                            HStack {
                                if routeSimulator.isRunning && routeSimulator.currentPointIndex == index {
                                    Image(systemName: "location.fill")
                                        .foregroundStyle(.blue)
                                        .font(.caption)
                                        .frame(width: 20)
                                } else {
                                    Text("\(index + 1)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20)
                                }
                                Text(point.displayString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !routeSimulator.isRunning {
                                    Button {
                                        routeSimulator.removePoint(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                focusRoutePointIndex = index
                            }

                            if index < routeSimulator.routePoints.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .cornerRadius(6)
            }

            // Action buttons
            HStack {
                Button {
                    onAddCurrentLocation()
                } label: {
                    Label("加入路線", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(routeSimulator.isRunning)

                if !routeSimulator.routePoints.isEmpty && !routeSimulator.isRunning {
                    Button {
                        routeSimulator.clearAllPoints()
                    } label: {
                        Label("清除全部", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // Start/Stop
            if routeSimulator.routePoints.count >= 2 {
                if routeSimulator.isRunning {
                    Button {
                        routeSimulator.stop()
                    } label: {
                        Label("停止模擬", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        routeSimulator.start { lat, lon in
                            await deviceManager.setLocation(latitude: lat, longitude: lon)
                        }
                    } label: {
                        Label("開始移動", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(deviceManager.selectedDeviceIDs.isEmpty)
                }
            }
        }
    }
}
