import SwiftUI

struct SavedRoutesView: View {
    @ObservedObject var store: SavedRouteStore
    var currentPoints: [RoutePoint]
    var onLoad: ([RoutePoint]) -> Void

    @State private var newName = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("收藏路線")
                    .font(.headline)
                Spacer()
                Button {
                    isSaving.toggle()
                } label: {
                    Image(systemName: isSaving ? "xmark" : "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(currentPoints.count < 2)
            }

            if isSaving {
                HStack(spacing: 6) {
                    TextField("輸入路線名稱", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveRoute() }
                    Button("儲存") {
                        saveRoute()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Text("將儲存目前路線（\(currentPoints.count) 個點）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if store.routes.isEmpty {
                Text("尚無收藏路線")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(store.routes) { route in
                    HStack {
                        Button {
                            onLoad(route.points)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(route.name)
                                    .font(.callout)
                                    .lineLimit(1)
                                Text(route.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button {
                            store.delete(route)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)

                    if route != store.routes.last {
                        Divider()
                    }
                }
            }
        }
    }

    private func saveRoute() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.add(name: trimmed, points: currentPoints)
        newName = ""
        isSaving = false
    }
}
