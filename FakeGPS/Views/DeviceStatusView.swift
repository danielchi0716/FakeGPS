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

            if deviceManager.isDetecting {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("偵測中...")
                        .foregroundStyle(.secondary)
                }
            } else if let device = deviceManager.device {
                // Device info
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "iphone.gen3")
                                .foregroundStyle(.blue)
                            Text(device.name)
                                .fontWeight(.medium)
                            Spacer()
                            Text("iOS \(device.osVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text(device.productType)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(device.id.prefix(16)) + "...")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .monospaced()
                        }
                    }
                }

                // Tunnel control for iOS 17+
                if device.isiOS17OrLater {
                    GroupBox {
                        HStack {
                            Circle()
                                .fill(deviceManager.tunnelRunning ? .green : .orange)
                                .frame(width: 8, height: 8)
                            Text(deviceManager.tunnelRunning ? "Tunnel 已連線" : "Tunnel 未連線")
                                .font(.caption)
                            Spacer()
                            if deviceManager.tunnelRunning {
                                Button("停止") {
                                    Task { await deviceManager.stopTunnel() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            } else {
                                Button("啟動") {
                                    Task { await deviceManager.startTunnel() }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                            }
                        }
                    }
                }
            } else {
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
            }
        }
    }
}

#Preview {
    DeviceStatusView()
        .environmentObject(DeviceManager())
        .padding()
        .frame(width: 300)
}
