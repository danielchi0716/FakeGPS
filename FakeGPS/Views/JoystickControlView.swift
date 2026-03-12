import SwiftUI
import CoreLocation

struct JoystickControlView: View {
    @Binding var latitude: Double
    @Binding var longitude: Double
    var onMove: () -> Void

    @State private var speed: Double = 10 // km/h
    @State private var isMoving = false
    @State private var moveDirection: MoveDirection?
    @State private var moveTask: Task<Void, Never>?

    private let speedPresets: [Double] = [5, 10, 30, 60]
    private let updateInterval: TimeInterval = 0.5 // seconds

    enum MoveDirection {
        case up, down, left, right, upLeft, upRight, downLeft, downRight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("移動控制")
                .font(.headline)

            // Speed control
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("速度")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(speed)) km/h")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(value: $speed, in: 1...200, step: 1)

                HStack(spacing: 6) {
                    ForEach(speedPresets, id: \.self) { preset in
                        Button("\(Int(preset))") {
                            speed = preset
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            // Direction pad
            directionPad
                .frame(maxWidth: .infinity)

            if isMoving {
                Text("按 Enter 或 Esc 停止移動")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("按方向鍵開始移動")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .focusable()
        .onKeyPress(.upArrow) { startMoving(.up); return .handled }
        .onKeyPress(.downArrow) { startMoving(.down); return .handled }
        .onKeyPress(.leftArrow) { startMoving(.left); return .handled }
        .onKeyPress(.rightArrow) { startMoving(.right); return .handled }
        .onKeyPress(.return) { stopMoving(); return .handled }
        .onKeyPress(.escape) { stopMoving(); return .handled }
    }

    // MARK: - Direction Pad

    private var directionPad: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                directionButton("↖", direction: .upLeft)
                directionButton("↑", direction: .up)
                directionButton("↗", direction: .upRight)
            }
            HStack(spacing: 4) {
                directionButton("←", direction: .left)
                stopButton
                directionButton("→", direction: .right)
            }
            HStack(spacing: 4) {
                directionButton("↙", direction: .downLeft)
                directionButton("↓", direction: .down)
                directionButton("↘", direction: .downRight)
            }
        }
    }

    private func directionButton(_ label: String, direction: MoveDirection) -> some View {
        Button {
            if moveDirection == direction {
                stopMoving()
            } else {
                startMoving(direction)
            }
        } label: {
            Text(label)
                .font(.title2)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .tint(moveDirection == direction ? .blue : nil)
    }

    private var stopButton: some View {
        Button {
            stopMoving()
        } label: {
            Image(systemName: "stop.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .tint(isMoving ? .red : nil)
        .disabled(!isMoving)
    }

    // MARK: - Movement Logic

    private func startMoving(_ direction: MoveDirection) {
        stopMoving()
        moveDirection = direction
        isMoving = true

        moveTask = Task {
            while !Task.isCancelled {
                let (dLat, dLon) = offset(for: direction)
                latitude += dLat
                longitude += dLon

                // Clamp values
                latitude = max(-90, min(90, latitude))
                longitude = max(-180, min(180, longitude))

                onMove()

                try? await Task.sleep(for: .milliseconds(Int(updateInterval * 1000)))
            }
        }
    }

    private func stopMoving() {
        moveTask?.cancel()
        moveTask = nil
        moveDirection = nil
        isMoving = false
    }

    /// Calculate latitude/longitude offset per tick based on speed and direction.
    private func offset(for direction: MoveDirection) -> (Double, Double) {
        // distance per tick in meters
        let metersPerTick = (speed * 1000.0 / 3600.0) * updateInterval

        // 1 degree latitude ≈ 111,320 meters
        let dLat = metersPerTick / 111_320.0
        // 1 degree longitude ≈ 111,320 * cos(latitude) meters
        let cosLat = cos(latitude * .pi / 180.0)
        let dLon = cosLat > 0.0001 ? metersPerTick / (111_320.0 * cosLat) : 0

        switch direction {
        case .up:        return ( dLat,  0)
        case .down:      return (-dLat,  0)
        case .right:     return ( 0,     dLon)
        case .left:      return ( 0,    -dLon)
        case .upRight:   return ( dLat * 0.7071,  dLon * 0.7071)
        case .upLeft:    return ( dLat * 0.7071, -dLon * 0.7071)
        case .downRight: return (-dLat * 0.7071,  dLon * 0.7071)
        case .downLeft:  return (-dLat * 0.7071, -dLon * 0.7071)
        }
    }
}

#Preview {
    JoystickControlView(
        latitude: .constant(25.033),
        longitude: .constant(121.5654),
        onMove: {}
    )
    .padding()
    .frame(width: 300)
}
