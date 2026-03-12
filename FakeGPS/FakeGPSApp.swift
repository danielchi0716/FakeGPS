import SwiftUI

@main
struct FakeGPSApp: App {
    @StateObject private var deviceManager = DeviceManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deviceManager)
        }
        .defaultSize(width: 1000, height: 700)
    }
}
