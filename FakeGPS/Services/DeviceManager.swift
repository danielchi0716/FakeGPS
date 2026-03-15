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
    @Published var isDetecting = false
    @Published var isSimulating = false
    @Published var simulatedLocation: SimulatedLocation?
    @Published var tunnelRunning = false
    @Published var statusMessage = "未連接裝置"
    @Published var errorMessage: String?

    /// The currently selected devices.
    var selectedDevices: [DeviceInfo] {
        devices.filter { selectedDeviceIDs.contains($0.id) }
    }

    /// Whether any device requires iOS 17+ tunnel.
    var anySelectedNeedsTunnel: Bool {
        selectedDevices.contains { $0.isiOS17OrLater }
    }

    private var tunnelProcess: Process?

    /// Per-device streamer state, keyed by device UDID.
    private struct StreamerState {
        var process: Process
        var stdin: Pipe
        var ready: Bool
    }
    private var streamers: [String: StreamerState] = [:]

    /// Path to bundled helper binary, or nil if not found (dev mode).
    private var helperPath: String?
    /// Fallback: system pymobiledevice3 CLI path (for dev builds without bundled binary).
    private var pymobiledevice3Path: String?
    /// Fallback: system python path (for dev builds).
    private var pythonPath: String?

    init() {
        Task { await findHelper() }

        // Terminate tunnel when app quits
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.killAllStreamers()
            self?.stopTunnelSync()
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

        // 2. Fallback: search for system pymobiledevice3 + python (dev mode)
        await findSystemPymobiledevice3()
    }

    /// Check whether a Mach-O binary supports the current CPU architecture.
    private func isBinaryCompatible(atPath path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              data.count >= 8 else { return false }

        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }

        // Universal binary (FAT) — assume compatible (contains multiple architectures)
        let FAT_MAGIC: UInt32 = 0xCAFEBABE
        let FAT_CIGAM: UInt32 = 0xBEBAFECA
        if magic == FAT_MAGIC || magic == FAT_CIGAM { return true }

        // Thin Mach-O — check CPU type matches this process
        let MH_MAGIC_64: UInt32 = 0xFEEDFACF
        let MH_CIGAM_64: UInt32 = 0xCFFAEDFE
        if magic == MH_MAGIC_64 || magic == MH_CIGAM_64 {
            let cpuType = data.withUnsafeBytes { ptr -> UInt32 in
                // cpu_type is at offset 4 in mach_header_64
                ptr.load(fromByteOffset: 4, as: UInt32.self)
            }
            var currentCPU = cpu_type_t()
            var size = MemoryLayout<cpu_type_t>.size
            sysctlbyname("hw.cputype", &currentCPU, &size, nil, 0)
            let needSwap = (magic == MH_CIGAM_64)
            let binaryCPU = needSwap ? cpuType.byteSwapped : cpuType
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
                if pythonPath == nil {
                    for p in ["/usr/local/bin/python3.13", "/usr/local/bin/python3.12", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"] {
                        if FileManager.default.isExecutableFile(atPath: p) {
                            pythonPath = p
                            break
                        }
                    }
                }
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

        statusMessage = "找不到 pymobiledevice3，請先安裝"
        errorMessage = "請執行 pip3 install pymobiledevice3"
    }

    /// Whether the helper or system fallback is available.
    private var isToolReady: Bool {
        helperPath != nil || pymobiledevice3Path != nil
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
                    // Bundled helper failed (e.g. wrong CPU arch) — fall back to system tool
                    print("[FakeGPS] Bundled helper failed: \(error.localizedDescription), falling back to system tool")
                    helperPath = nil
                    await findSystemPymobiledevice3()
                    if let pmd3 = pymobiledevice3Path {
                        result = try await ShellExecutor.run(pmd3, arguments: ["usbmux", "list"])
                    } else {
                        throw error
                    }
                }
            } else {
                result = try await ShellExecutor.run(pymobiledevice3Path!, arguments: ["usbmux", "list"])
            }

            if result.exitCode != 0 {
                statusMessage = "偵測裝置失敗"
                errorMessage = result.error.isEmpty ? "指令執行失敗 (exit code: \(result.exitCode))" : result.error
                devices = []
                selectedDeviceIDs = []
                return
            }

            guard let data = result.output.data(using: .utf8) else {
                statusMessage = "無法解析裝置資料"
                devices = []
                selectedDeviceIDs = []
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
                return DeviceInfo(id: udid, name: name, productType: productType, osVersion: osVersion)
            }

            self.devices = parsed

            if parsed.isEmpty {
                selectedDeviceIDs = []
                statusMessage = "未偵測到裝置，請確認 iPhone 已透過 USB 連接"
            } else {
                let connectedIDs = Set(parsed.map(\.id))
                // Remove selections for disconnected devices
                selectedDeviceIDs = selectedDeviceIDs.intersection(connectedIDs)
                // Auto-select all if nothing was selected
                if selectedDeviceIDs.isEmpty {
                    selectedDeviceIDs = connectedIDs
                }
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
            devices = []
            selectedDeviceIDs = []
        }
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
        } else {
            command = pymobiledevice3Path!
            arguments = ["remote", "tunneld"]
        }

        do {
            let (process, stdoutPipe, stderrPipe) = try await ShellExecutor.startSudoProcess(
                command: command,
                arguments: arguments,
                cleanupBefore: "pkill -f 'location_streamer.*tunneld' 2>/dev/null; pkill -f 'pymobiledevice3.*tunneld' 2>/dev/null; lsof -ti :49151 | xargs kill -9 2>/dev/null; sleep 1"
            )
            tunnelProcess = process
            statusMessage = "Tunneld 啟動中..."

            let outputCollector = LockedValue("")
            let errorCollector = LockedValue("")

            // Monitor stdout for ready signal
            Task.detached { [weak self] in
                let handle = stdoutPipe.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    if let line = String(data: data, encoding: .utf8) {
                        outputCollector.update { $0 += line }
                    }
                }
            }

            // Monitor stderr for tunnel creation log
            Task.detached { [weak self] in
                let handle = stderrPipe.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    if let line = String(data: data, encoding: .utf8) {
                        errorCollector.update { $0 += line }
                        let lower = line.lowercased()
                        if lower.contains("tunnel created") || lower.contains("ready") {
                            await MainActor.run {
                                self?.tunnelRunning = true
                                self?.statusMessage = "Tunneld 已啟動"
                            }
                        }
                    }
                }
            }

            // Wait a few seconds then check if tunneld is responding
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if process.isRunning {
                    self?.tunnelRunning = true
                    self?.statusMessage = "Tunneld 已啟動"
                }
            }

            // Monitor process exit
            Task.detached { [weak self] in
                process.waitUntilExit()
                let exitCode = process.terminationStatus
                let stdout = outputCollector.value
                let stderr = errorCollector.value
                await MainActor.run {
                    self?.tunnelRunning = false
                    self?.tunnelProcess = nil
                    if exitCode != 0 {
                        self?.statusMessage = "Tunneld 已停止（exit code: \(exitCode)）"
                        let combined = (stderr + "\n" + stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !combined.isEmpty {
                            self?.errorMessage = String(combined.suffix(500))
                        }
                    } else {
                        self?.statusMessage = "Tunneld 已停止"
                    }
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
            let pid = process.processIdentifier
            process.terminate()
            let killScript = "kill -- -\(pid) 2>/dev/null; pkill -P \(pid) 2>/dev/null; pkill -f 'location_streamer.*tunneld' 2>/dev/null; pkill -f 'pymobiledevice3.*tunneld' 2>/dev/null; lsof -ti :49151 | xargs kill -9 2>/dev/null; true"
            try? Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", killScript])
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

            let scriptPath = Bundle.main.path(forResource: "location_streamer", ofType: "py")
                ?? (Bundle.main.bundlePath + "/Contents/Resources/location_streamer.py")

            let possiblePaths = [
                scriptPath,
                Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("FakeGPS/Resources/location_streamer.py").path,
            ]

            var actualScript: String?
            for p in possiblePaths {
                if FileManager.default.fileExists(atPath: p) {
                    actualScript = p
                    break
                }
            }

            guard let script = actualScript else {
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
