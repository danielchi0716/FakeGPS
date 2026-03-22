import SwiftUI

struct ConnectionBarView: View {
    @EnvironmentObject var deviceManager: DeviceManager

    var body: some View {
        HStack(spacing: 8) {
            // Tunnel status
            tunnelStatus

            Divider().frame(height: 16)

            // Device info
            deviceSummary

            Spacer()

            // Detecting spinner
            if deviceManager.isDetecting {
                ProgressView()
                    .controlSize(.small)
            }

            // Refresh button
            Button {
                Task { await deviceManager.detectDevice() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(deviceManager.isDetecting)
        }
        .padding(.horizontal, FGSpacing.panelPadding)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Tunnel Status

    @ViewBuilder
    private var tunnelStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tunnelColor)
                .frame(width: 7, height: 7)
            Text(tunnelLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !deviceManager.tunnelRunning {
            Button("啟動") {
                Task { await deviceManager.startTunnel() }
            }
            .font(.caption2)
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private var tunnelColor: Color {
        deviceManager.tunnelRunning ? .green : .orange
    }

    private var tunnelLabel: String {
        deviceManager.tunnelRunning ? "Tunnel" : "Tunnel 未啟動"
    }

    // MARK: - Device Summary

    @ViewBuilder
    private var deviceSummary: some View {
        if deviceManager.devicesConfirmed {
            // Confirmed state: show selected count + change button
            HStack(spacing: 4) {
                Image(systemName: "iphone.gen3")
                    .font(.caption)
                    .foregroundStyle(.green)
                if deviceManager.selectedDeviceIDs.count == 1,
                   let device = deviceManager.selectedDevices.first {
                    Text(device.name)
                        .font(.caption)
                        .lineLimit(1)
                } else {
                    Text("\(deviceManager.selectedDeviceIDs.count) 台裝置")
                        .font(.caption)
                }
            }

            Button("變更") {
                deviceManager.devicesConfirmed = false
            }
            .font(.caption2)
            .buttonStyle(.bordered)
            .controlSize(.mini)
        } else if deviceManager.devices.isEmpty {
            Label("未偵測到裝置", systemImage: "iphone.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "iphone.gen3")
                    .font(.caption)
                Text("\(deviceManager.devices.count) 台可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
