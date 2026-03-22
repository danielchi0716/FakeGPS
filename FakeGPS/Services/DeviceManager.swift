import Foundation
import AppKit

/// Thread-safe wrapper for a value, used to collect process output from detached tasks.
final class LockedValue<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    init(_ initial: T) { _value = initial }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func update(_ transform: (inout T) -> Void) { lock.lock(); transform(&_value); lock.unlock() }
}

@MainActor
class DeviceManager: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    @Published var selectedDeviceIDs: Set<String> = []
    @Published var devicesConfirmed = false
    @Published var isDetecting = false
    @Published var isSimulating = false
    @Published var simulatedLocation: SimulatedLocation?
    @Published var tunnelRunning = false
    @Published var statusMessage = "未連接裝置"
    @Published var errorMessage: String?
    @Published var disconnectedDeviceNames: [String] = []

    /// The currently selected devices.
    var selectedDevices: [DeviceInfo] {
        devices.filter { selectedDeviceIDs.contains($0.id) }
    }

    /// Whether any device requires iOS 17+ tunnel.
    var anySelectedNeedsTunnel: Bool {
        selectedDevices.contains { $0.isiOS17OrLater }
    }

    private var tunnelProcess: PrivilegedProcess?

    /// Per-device streamer state, keyed by device UDID.
    private struct StreamerState {
        var process: Process
        var stdin: Pipe
        var ready: Bool
    }
    private var streamers: [String: StreamerState] = [:]

    private var usbWatcher: USBWatcher?
    private var debounceTask: Task<Void, Never>?
    private var networkPollTask: Task<Void, Never>?

    /// Path to bundled helper binary, or nil if not found (dev mode).
    private var helperPath: String?
    /// Fallback: system pymobiledevice3 CLI path (for dev builds without bundled binary).
    private var pymobiledevice3Path: String?
    /// Fallback: system python path (for dev builds).
    private var pythonPath: String?

    init() {
        Task { await findHelper() }

        // Monitor USB device attach/detach events
        usbWatcher = USBWatcher { [weak self] in
            Task { @MainActor in
                self?.scheduleDetection()
            }
        }

        // Terminate tunnel when app quits
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.usbWatcher?.stop()
            self?.networkPollTask?.cancel()
            self?.killAllStreamers()
            self?.stopTunnelSync()
        }
    }

    /// Debounced device detection triggered by USB events.
    private func scheduleDetection() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return // cancelled
            }
            await self?.detectDevice()
        }
    }

    /// Start periodic polling for network device changes (every 10s).
    /// Only runs while network devices are connected or tunnel is running.
    private func startNetworkPollingIfNeeded() {
        let hasNetworkDevices = devices.contains { $0.connectionType == .network }
        guard hasNetworkDevices || tunnelRunning else {
            networkPollTask?.cancel()
            networkPollTask = nil
            return
        }
        // Already polling
        guard networkPollTask == nil else { return }
        networkPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                await self?.detectDevice()
            }
        }
    }

    // MARK: - Find Helper / Fallback

    func findHelper() async {
        // 1. Look for bundled helper binary (verify it can run on this CPU)
        if let bundled = Bundle.main.path(forResource: "location_streamer", ofType: nil),
           FileManager.default.isExecutableFile(atPath: bundled),
           isBinaryCompatible(atPath: bundled) {
            helperPath = bundled
            statusMessage = "就緒"
            return
        }

        // 2. Fallback: search for system pymobiledevice3 CLI + python
        await findSystemPymobiledevice3()
    }

    /// Check whether a Mach-O binary supports the current CPU architecture.
    private func isBinaryCompatible(atPath path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              data.count >= 8 else { return false }

        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }

        // Universal binary (FAT) — assume compatible
        if magic == 0xCAFEBABE || magic == 0xBEBAFECA { return true }

        // Thin Mach-O — check CPU type matches this process
        if magic == 0xFEEDFACF || magic == 0xCFFAEDFE {
            let cpuType = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
            var currentCPU = cpu_type_t()
            var size = MemoryLayout<cpu_type_t>.size
            sysctlbyname("hw.cputype", &currentCPU, &size, nil, 0)
            let binaryCPU = (magic == 0xCFFAEDFE) ? cpuType.byteSwapped : cpuType
            return binaryCPU == UInt32(bitPattern: Int32(currentCPU))
        }

        // Not a Mach-O binary (e.g. script) — assume compatible
        return true
    }

    private func findSystemPymobiledevice3() async {
        let home = NSHomeDirectory()
        var searchPaths = [
            "/usr/local/bin/pymobiledevice3",
            "/opt/homebrew/bin/pymobiledevice3",
            "\(home)/.local/bin/pymobiledevice3",
        ]
        for minor in stride(from: 13, through: 8, by: -1) {
            searchPaths.append("\(home)/Library/Python/3.\(minor)/bin/pymobiledevice3")
        }

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                pymobiledevice3Path = path
                if let range = path.range(of: "/Library/Python/3.") {
                    let afterPrefix = path[range.upperBound...]
                    if let slashIdx = afterPrefix.firstIndex(of: "/") {
                        let minor = afterPrefix[..<slashIdx]
                        let pyPath = "/usr/local/bin/python3.\(minor)"
                        if FileManager.default.isExecutableFile(atPath: pyPath) {
                            pythonPath = pyPath
                        }
                    }
                }
                findSystemPython()
                statusMessage = "已找到 pymobiledevice3"
                return
            }
        }

        // Try `which`
        do {
            let result = try await ShellExecutor.run("/usr/bin/which", arguments: ["pymobiledevice3"])
            if result.exitCode == 0 && !result.output.isEmpty {
                pymobiledevice3Path = result.output
                statusMessage = "已找到 pymobiledevice3"
                return
            }
        } catch {}

        do {
            let result = try await ShellExecutor.run("/bin/zsh", arguments: ["-l", "-c", "which pymobiledevice3"])
            if result.exitCode == 0 && !result.output.isEmpty {
                pymobiledevice3Path = result.output
                statusMessage = "已找到 pymobiledevice3"
                return
            }
        } catch {}

        // No pymobiledevice3 CLI — check if Python + module exists
        findSystemPython()
        if let python = pythonPath {
            do {
                let result = try await ShellExecutor.run(python, arguments: ["-c", "import pymobiledevice3"])
                if result.exitCode == 0 {
                    statusMessage = "已找到 Python + pymobiledevice3"
                    return
                }
            } catch {}
        }

        statusMessage = "找不到 pymobiledevice3，請先安裝"
        errorMessage = "請執行 pip3 install pymobiledevice3"
    }

    private func findSystemPython() {
        if pythonPath != nil { return }
        let candidates = [
            "/usr/local/bin/python3.13", "/usr/local/bin/python3.12", "/usr/local/bin/python3.11",
            "/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3",
        ]
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) {
                pythonPath = p
                return
            }
        }
    }

    /// Whether the helper or system fallback is available.
    private var isToolReady: Bool {
        helperPath != nil || pymobiledevice3Path != nil || pythonPath != nil
    }

    /// Resolve the path to the bundled `location_streamer.py` script.
    private func findScript() -> String? {
        var candidates: [String] = []
        if let bundled = Bundle.main.path(forResource: "location_streamer", ofType: "py") {
            candidates.append(bundled)
        }
        candidates.append(Bundle.main.bundlePath + "/Contents/Resources/location_streamer.py")
        // Dev mode: source tree relative to the built .app
        candidates.append(
            Bundle.main.bundleURL
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("FakeGPS/Resources/location_streamer.py").path
        )
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    // MARK: - Detect Device

    func detectDevice() async {
        guard isToolReady else {
            errorMessage = "找不到必要工具"
            return
        }

        isDetecting = true
        errorMessage = nil
        defer { isDetecting = false }

        do {
            let result: ShellResult
            if let helper = helperPath {
                do {
                    result = try await ShellExecutor.run(helper, arguments: ["list"])
                } catch {
                    // Bundled helper failed (e.g. wrong CPU arch) — fall back
                    print("[FakeGPS] Bundled helper failed: \(error.localizedDescription), falling back")
                    helperPath = nil
                    await findSystemPymobiledevice3()
                    result = try await runListFallback()
                }
            } else {
                result = try await runListFallback()
            }

            if result.exitCode != 0 {
                statusMessage = "偵測裝置失敗"
                errorMessage = result.error.isEmpty ? "指令執行失敗 (exit code: \(result.exitCode))" : result.error
                return
            }

            guard let data = result.output.data(using: .utf8) else {
                statusMessage = "無法解析裝置資料"
                return
            }

            let devices = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []

            let parsed: [DeviceInfo] = devices.compactMap { dict in
                let udid = dict["UniqueDeviceID"] as? String
                    ?? dict["UDID"] as? String
                    ?? dict["SerialNumber"] as? String
                    ?? "unknown"
                let name = dict["DeviceName"] as? String ?? "iPhone"
                let productType = dict["ProductType"] as? String ?? "unknown"
                let osVersion = dict["ProductVersion"] as? String ?? "unknown"
                let connType: ConnectionType = (dict["ConnectionType"] as? String) == "Network" ? .network : .usb
                return DeviceInfo(id: udid, name: name, productType: productType, osVersion: osVersion, connectionType: connType)
            }

            // Kill streamers for disconnected devices before updating published state
            let connectedIDs = Set(parsed.map(\.id))
            for id in streamers.keys where !connectedIDs.contains(id) {
                killStreamer(for: id)
            }

            // Check if any confirmed/selected device disconnected while simulating
            if devicesConfirmed {
                let lostIDs = selectedDeviceIDs.subtracting(connectedIDs)
                if !lostIDs.isEmpty {
                    let lostNames = self.devices.filter { lostIDs.contains($0.id) }.map(\.name)
                    // Stop simulation immediately
                    if isSimulating {
                        await clearLocation()
                    }
                    devicesConfirmed = false
                    disconnectedDeviceNames = lostNames
                }
            }

            self.devices = parsed

            if parsed.isEmpty {
                selectedDeviceIDs = []
                statusMessage = "未偵測到裝置，請確認 iPhone 已透過 USB 或 Wi-Fi 連接"
            } else {
                // Remove selections for disconnected devices
                selectedDeviceIDs = selectedDeviceIDs.intersection(connectedIDs)
                let count = parsed.count
                if count == 1, let dev = parsed.first {
                    statusMessage = "已連接: \(dev.name) (iOS \(dev.osVersion))"
                } else {
                    statusMessage = "已連接 \(count) 台裝置"
                }
            }
        } catch {
            statusMessage = "偵測裝置時發生錯誤"
            errorMessage = error.localizedDescription
        }

        startNetworkPollingIfNeeded()
    }

    /// Run the list command using Python script or pymobiledevice3 CLI fallback.
    private func runListFallback() async throws -> ShellResult {
        // Prefer Python script (supports USB + network discovery)
        if let python = pythonPath, let script = findScript() {
            return try await ShellExecutor.run(python, arguments: [script, "list"])
        }
        // Fall back to pymobiledevice3 CLI (USB only)
        if let pmd3 = pymobiledevice3Path {
            return try await ShellExecutor.run(pmd3, arguments: ["usbmux", "list"])
        }
        throw NSError(domain: "FakeGPS", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到偵測工具"])
    }

    // MARK: - Tunnel (iOS 17+)

    func startTunnel() async {
        guard isToolReady else {
            errorMessage = "找不到必要工具"
            return
        }

        statusMessage = "正在啟動 tunneld（需要管理員權限）..."
        errorMessage = nil

        let command: String
        let arguments: [String]

        if let helper = helperPath {
            command = helper
            arguments = ["tunneld"]
        } else if let pmd3 = pymobiledevice3Path {
            command = pmd3
            arguments = ["remote", "tunneld"]
        } else if let python = pythonPath, let script = findScript() {
            command = python
            arguments = [script, "tunneld"]
        } else {
            errorMessage = "找不到 tunneld 工具"
            return
        }

        do {
            let privileged = try await ShellExecutor.startSudoProcess(
                command: command,
                arguments: arguments,
                cleanupBefore: "pkill -f 'location_streamer.*tunneld' 2>/dev/null; pkill -f 'pymobiledevice3.*tunneld' 2>/dev/null; lsof -ti :49151 | xargs kill -9 2>/dev/null; sleep 1"
            )
            tunnelProcess = privileged
            statusMessage = "Tunneld 啟動中..."

            // Monitor stderr for tunnel creation log + process exit
            Task.detached { [weak self] in
                // Wait for output files to be created
                try? await Task.sleep(for: .milliseconds(500))

                let stderrHandle = FileHandle(forReadingAtPath: privileged.stderrPath)

                while privileged.isRunning {
                    if let handle = stderrHandle, handle.availableData.count > 0 {
                        // Re-read to get new content
                    }
                    // Periodically check stderr file for "tunnel created" / "ready"
                    if let data = FileManager.default.contents(atPath: privileged.stderrPath),
                       let text = String(data: data, encoding: .utf8)?.lowercased(),
                       text.contains("tunnel created") || text.contains("ready") {
                        await MainActor.run {
                            if !(self?.tunnelRunning ?? true) {
                                self?.tunnelRunning = true
                                self?.statusMessage = "Tunneld 已啟動"
                                self?.scheduleDetection()
                            }
                        }
                    }
                    try? await Task.sleep(for: .seconds(1))
                }

                stderrHandle?.closeFile()

                // Process exited
                let stderr = (try? String(contentsOfFile: privileged.stderrPath, encoding: .utf8)) ?? ""
                let stdout = (try? String(contentsOfFile: privileged.stdoutPath, encoding: .utf8)) ?? ""
                await MainActor.run {
                    self?.tunnelRunning = false
                    self?.tunnelProcess = nil
                    self?.networkPollTask?.cancel()
                    self?.networkPollTask = nil
                    let combined = (stderr + "\n" + stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !combined.isEmpty {
                        self?.statusMessage = "Tunneld 已停止"
                        self?.errorMessage = String(combined.suffix(500))
                    } else {
                        self?.statusMessage = "Tunneld 已停止"
                    }
                    self?.scheduleDetection()
                    privileged.cleanup()
                }
            }

            // Fallback: if no "ready" signal after 5 seconds but process is alive, assume running
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if privileged.isRunning && !(self?.tunnelRunning ?? true) {
                    self?.tunnelRunning = true
                    self?.statusMessage = "Tunneld 已啟動"
                    self?.scheduleDetection()
                }
            }
        } catch {
            statusMessage = "啟動 tunneld 失敗"
            errorMessage = error.localizedDescription
        }
    }

    func stopTunnel() async {
        stopTunnelSync()
    }

    private func stopTunnelSync() {
        if let process = tunnelProcess, process.isRunning {
            let pid = process.pid
            process.terminate()
            let killScript = "kill -- -\(pid) 2>/dev/null; pkill -P \(pid) 2>/dev/null; pkill -f 'location_streamer.*tunneld' 2>/dev/null; pkill -f 'pymobiledevice3.*tunneld' 2>/dev/null; lsof -ti :49151 | xargs kill -9 2>/dev/null; true"
            try? Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", killScript])
            process.cleanup()
        }
        tunnelProcess = nil
        tunnelRunning = false
    }

    // MARK: - Device Selection

    func toggleDevice(_ device: DeviceInfo) {
        if selectedDeviceIDs.contains(device.id) {
            selectedDeviceIDs.remove(device.id)
        } else {
            selectedDeviceIDs.insert(device.id)
        }
    }

    func selectAllDevices() {
        selectedDeviceIDs = Set(devices.map(\.id))
    }

    func deselectAllDevices() {
        selectedDeviceIDs.removeAll()
    }

    // MARK: - Location Streamer

    /// Start the location streamer process for a specific device if not already running.
    private func ensureStreamer(for deviceId: String) async -> Bool {
        if let state = streamers[deviceId], state.process.isRunning, state.ready {
            return true
        }

        guard let dev = devices.first(where: { $0.id == deviceId }) else {
            return false
        }

        // Kill old streamer for this device if any
        killStreamer(for: deviceId)

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        if let helper = helperPath {
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["streamer", "--udid", dev.id]
        } else {
            guard let python = pythonPath else {
                errorMessage = "找不到 Python"
                return false
            }
            guard let script = findScript() else {
                errorMessage = "找不到 location_streamer.py"
                return false
            }
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script, "streamer", "--udid", dev.id]
        }

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            errorMessage = "啟動 streamer 失敗 (\(dev.name)): \(error.localizedDescription)"
            return false
        }

        streamers[deviceId] = StreamerState(process: process, stdin: stdinPipe, ready: false)

        // Wait for READY signal
        let readyReceived = LockedValue(false)
        let errCollector = LockedValue("")

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if d.isEmpty { return }
            if let str = String(data: d, encoding: .utf8), str.contains("READY") {
                readyReceived.update { $0 = true }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if d.isEmpty { return }
            if let str = String(data: d, encoding: .utf8) {
                errCollector.update { $0 += str }
            }
        }

        let start = Date()
        while Date().timeIntervalSince(start) < 15 {
            if readyReceived.value || !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        if readyReceived.value {
            streamers[deviceId]?.ready = true
            print("[FakeGPS] Streamer ready for device \(deviceId)")

            // Monitor for unexpected exit
            Task.detached { [weak self] in
                process.waitUntilExit()
                let err = errCollector.value
                await MainActor.run {
                    if self?.streamers[deviceId]?.process === process {
                        self?.streamers.removeValue(forKey: deviceId)
                        // Update UI if this device was selected
                        if self?.selectedDeviceIDs.contains(deviceId) == true {
                            // Check if any selected device still has an active streamer
                            let anyActive = self?.selectedDeviceIDs.contains(where: { id in
                                self?.streamers[id]?.ready == true
                            }) ?? false
                            if !anyActive {
                                self?.isSimulating = false
                                self?.simulatedLocation = nil
                                self?.statusMessage = "模擬位置已結束"
                            }
                            if !err.isEmpty {
                                self?.errorMessage = "Streamer 已停止 (\(dev.name)): \(String(err.suffix(300)))"
                            }
                        }
                    }
                }
            }
            return true
        } else {
            let err = errCollector.value
            errorMessage = "Streamer 啟動失敗 (\(dev.name)): \(String(err.suffix(300)))"
            killStreamer(for: deviceId)
            return false
        }
    }

    /// Send a command to a specific device's streamer.
    private func sendToStreamer(for deviceId: String, command: String) async -> Bool {
        guard let state = streamers[deviceId], state.process.isRunning, state.ready else {
            return false
        }

        let data = (command + "\n").data(using: .utf8)!
        do {
            state.stdin.fileHandleForWriting.write(data)
            try await Task.sleep(for: .milliseconds(50))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Simulate Location

    func setLocation(latitude: Double, longitude: Double) async {
        guard isToolReady else {
            errorMessage = "找不到必要工具"
            return
        }
        guard !selectedDeviceIDs.isEmpty else {
            errorMessage = "請先選擇裝置"
            return
        }

        errorMessage = nil

        // Ensure all selected devices have a streamer running
        var failedDevices: [String] = []
        for deviceId in selectedDeviceIDs {
            if streamers[deviceId]?.ready != true {
                statusMessage = "正在連線..."
                let ok = await ensureStreamer(for: deviceId)
                if !ok {
                    let name = devices.first { $0.id == deviceId }?.name ?? deviceId
                    failedDevices.append(name)
                }
            }
        }

        let command = String(format: "%.6f,%.6f", latitude, longitude)
        var successCount = 0

        for deviceId in selectedDeviceIDs {
            if await sendToStreamer(for: deviceId, command: command) {
                successCount += 1
            }
        }

        if successCount > 0 {
            let location = SimulatedLocation(latitude: latitude, longitude: longitude)
            simulatedLocation = location
            isSimulating = true
            if selectedDeviceIDs.count > 1 {
                statusMessage = "模擬中 (\(successCount)/\(selectedDeviceIDs.count) 台): \(location.displayString)"
            } else {
                statusMessage = "模擬中: \(location.displayString)"
            }
        } else {
            errorMessage = "傳送位置失敗"
            statusMessage = "設定位置失敗"
        }

        if !failedDevices.isEmpty {
            errorMessage = "部分裝置連線失敗: \(failedDevices.joined(separator: ", "))"
        }
    }

    func clearLocation() async {
        for deviceId in selectedDeviceIDs {
            if streamers[deviceId]?.ready == true {
                let _ = await sendToStreamer(for: deviceId, command: "CLEAR")
            }
            killStreamer(for: deviceId)
        }
        simulatedLocation = nil
        isSimulating = false
        statusMessage = "已恢復真實定位"
    }

    private func killStreamer(for deviceId: String) {
        guard let state = streamers[deviceId] else { return }
        if state.process.isRunning {
            kill(state.process.processIdentifier, SIGINT)
            let proc = state.process
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if proc.isRunning { proc.terminate() }
            }
        }
        streamers.removeValue(forKey: deviceId)
    }

    private func killAllStreamers() {
        for id in streamers.keys {
            killStreamer(for: id)
        }
    }
}
