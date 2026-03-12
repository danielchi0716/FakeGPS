import SwiftUI

struct SavedLocationsView: View {
    @ObservedObject var store: SavedLocationStore
    @Binding var latitude: Double
    @Binding var longitude: Double
    var onSelect: () -> Void

    @State private var newName = ""
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("收藏地點")
                    .font(.headline)
                Spacer()
                Button {
                    isAdding.toggle()
                } label: {
                    Image(systemName: isAdding ? "xmark" : "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isAdding {
                HStack(spacing: 6) {
                    TextField("輸入名稱", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveLocation() }
                    Button("儲存") {
                        saveLocation()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Text("將儲存目前座標：\(String(format: "%.4f, %.4f", latitude, longitude))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if store.locations.isEmpty {
                Text("尚無收藏地點")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(store.locations) { location in
                    HStack {
                        Button {
                            latitude = location.latitude
                            longitude = location.longitude
                            onSelect()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.name)
                                    .font(.callout)
                                    .lineLimit(1)
                                Text(String(format: "%.4f, %.4f", location.latitude, location.longitude))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospaced()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button {
                            store.delete(location)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)

                    if location != store.locations.last {
                        Divider()
                    }
                }
            }
        }
    }

    private func saveLocation() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.add(name: trimmed, latitude: latitude, longitude: longitude)
        newName = ""
        isAdding = false
    }
}

#Preview {
    SavedLocationsView(
        store: SavedLocationStore(),
        latitude: .constant(25.033),
        longitude: .constant(121.5654),
        onSelect: {}
    )
    .padding()
    .frame(width: 300)
}
