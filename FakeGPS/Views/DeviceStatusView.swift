import SwiftUI

struct DeviceStatusView: View {
    @EnvironmentObject var deviceManager: DeviceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header with detect button
            HStack {
                Label("裝置", systemImage: "iphone")
                    .font(.headline)
                Spacer()
                if deviceManager.devices.count > 1 {
                    Text("\(deviceManager.selectedDeviceIDs.count)/\(deviceManager.devices.count) 台已選")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if deviceManager.isDetecting {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await deviceManager.detectDevice() }
                } label: {
                    Label("偵測", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(deviceManager.isDetecting)
            }

            if deviceManager.devices.isEmpty && !deviceManager.isDetecting {
                GroupBox {
                    HStack {
                        Image(systemName: "iphone.slash")
                            .foregroundStyle(.red)
                        Text("未偵測到裝置")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else {
                // Select all / deselect all (only for 2+ devices)
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

                // Device list
                ForEach(deviceManager.devices) { device in
                    let isSelected = deviceManager.selectedDeviceIDs.contains(device.id)

                    GroupBox {
                        HStack(spacing: 8) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? .blue : .secondary)
                                .font(.body)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "iphone.gen3")
                                        .foregroundStyle(isSelected ? .blue : .secondary)
                                        .font(.caption)
                                    Text(device.name)
                                        .fontWeight(isSelected ? .semibold : .medium)
                                        .font(.callout)
                                    Spacer()
                                    connectionIcon(for: device)
                                    Text("iOS \(device.osVersion)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text(device.productType)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        deviceManager.toggleDevice(device)
                    }
                }
            }

            // Tunnel status
            HStack(spacing: 6) {
                Circle()
                    .fill(deviceManager.tunnelRunning ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(deviceManager.tunnelRunning ? "Tunnel 運行中" : "Tunnel 未啟動")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !deviceManager.tunnelRunning {
                    Button("重新啟動") {
                        Task { await deviceManager.startTunnel() }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
    }

    @ViewBuilder
    private func connectionIcon(for device: DeviceInfo) -> some View {
        if device.connectionType == .network {
            Image(systemName: "wifi")
                .foregroundStyle(.green)
                .font(.caption)
                .help("無線連線")
        } else {
            Image(systemName: "cable.connector")
                .foregroundStyle(.secondary)
                .font(.caption)
                .help("USB 連線")
        }
    }
}

#Preview {
    DeviceStatusView()
        .environmentObject(DeviceManager())
        .padding()
        .frame(width: 300)
}
