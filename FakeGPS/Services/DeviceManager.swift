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
    @Published var device: DeviceInfo?
    @Published var isDetecting = false
    @Published var isSimulating = false
    @Published var simulatedLocation: SimulatedLocation?
    @Published var tunnelRunning = false
    @Published var statusMessage = "未連接裝置"
    @Published var errorMessage: String?

    private var tunnelProcess: Process?
    private var streamerProcess: Process?
    private var streamerStdin: Pipe?
    private var streamerReady = false

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
            self?.killStreamer()
            self?.stopTunnelSync()
        }
    }

    // MARK: - Find Helper / Fallback

    func findHelper() async {
        // 1. Look for bundled helper binary
        if let bundled = Bundle.main.path(forResource: "location_streamer", ofType: nil),
           FileManager.default.isExecutableFile(atPath: bundled) {
            helperPath = bundled
            statusMessage = "就緒"
            return
        }

        // 2. Fallback: search for system pymobiledevice3 + python (dev mode)
        await findSystemPymobiledevice3()
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
                result = try await ShellExecutor.run(helper, arguments: ["list"])
            } else {
                result = try await ShellExecutor.run(pymobiledevice3Path!, arguments: ["usbmux", "list"])
            }

            if result.exitCode != 0 {
                statusMessage = "偵測裝置失敗"
                errorMessage = result.error.isEmpty ? "指令執行失敗 (exit code: \(result.exitCode))" : result.error
                device = nil
                return
            }

            guard let data = result.output.data(using: .utf8) else {
                statusMessage = "無法解析裝置資料"
                device = nil
                return
            }

            let devices = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []

            if let first = devices.first {
                let udid = first["UniqueDeviceID"] as? String
                    ?? first["UDID"] as? String
                    ?? first["SerialNumber"] as? String
                    ?? "unknown"
                let name = first["DeviceName"] as? String ?? "iPhone"
                let productType = first["ProductType"] as? String ?? "unknown"
                let osVersion = first["ProductVersion"] as? String ?? "unknown"

                device = DeviceInfo(
                    id: udid,
                    name: name,
                    productType: productType,
                    osVersion: osVersion
                )
                statusMessage = "已連接: \(name) (iOS \(osVersion))"
            } else {
                device = nil
                statusMessage = "未偵測到裝置，請確認 iPhone 已透過 USB 連接"
            }
        } catch {
            statusMessage = "偵測裝置時發生錯誤"
            errorMessage = error.localizedDescription
            device = nil
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
                cleanupBefore: "pkill -f 'location_streamer.*tunneld' 2>/dev/null; pkill -f 'pymobiledevice3.*tunneld' 2>/dev/null; sleep 1"
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
            let killScript = "kill -- -\(pid) 2>/dev/null; pkill -P \(pid) 2>/dev/null; pkill -f 'location_streamer.*tunneld' 2>/dev/null; pkill -f 'pymobiledevice3.*tunneld' 2>/dev/null; true"
            try? Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", killScript])
        }
        tunnelProcess = nil
        tunnelRunning = false
    }

    // MARK: - Location Streamer

    /// Start the location streamer process if not already running.
    private func ensureStreamer() async -> Bool {
        if let process = streamerProcess, process.isRunning, streamerReady {
            return true
        }

        // Kill any old streamer
        killStreamer()

        guard let dev = device else {
            errorMessage = "請先偵測裝置"
            return false
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        if let helper = helperPath {
            // Bundled binary mode
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["streamer", "--udid", dev.id]
        } else {
            // Dev fallback: python + script
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
            errorMessage = "啟動 streamer 失敗: \(error.localizedDescription)"
            return false
        }

        streamerProcess = process
        streamerStdin = stdinPipe
        streamerReady = false

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
            streamerReady = true
            print("[FakeGPS] Streamer ready")

            // Monitor for unexpected exit
            Task.detached { [weak self] in
                process.waitUntilExit()
                let err = errCollector.value
                await MainActor.run {
                    if self?.streamerProcess === process {
                        self?.streamerProcess = nil
                        self?.streamerReady = false
                        self?.isSimulating = false
                        self?.simulatedLocation = nil
                        if !err.isEmpty {
                            self?.errorMessage = "Streamer 已停止: \(String(err.suffix(300)))"
                        }
                        self?.statusMessage = "模擬位置已結束"
                    }
                }
            }
            return true
        } else {
            let err = errCollector.value
            errorMessage = "Streamer 啟動失敗: \(String(err.suffix(300)))"
            killStreamer()
            return false
        }
    }

    /// Send a command to the streamer and wait for response.
    private func sendToStreamer(_ command: String) async -> Bool {
        guard let stdinPipe = streamerStdin,
              let process = streamerProcess, process.isRunning else {
            return false
        }

        let data = (command + "\n").data(using: .utf8)!
        do {
            stdinPipe.fileHandleForWriting.write(data)
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
        guard device != nil else {
            errorMessage = "請先偵測裝置"
            return
        }

        errorMessage = nil

        if !streamerReady {
            statusMessage = "正在連線..."
            let ok = await ensureStreamer()
            if !ok { return }
        }

        let command = String(format: "%.6f,%.6f", latitude, longitude)
        let success = await sendToStreamer(command)

        if success {
            let location = SimulatedLocation(latitude: latitude, longitude: longitude)
            simulatedLocation = location
            isSimulating = true
            statusMessage = "模擬中: \(location.displayString)"
        } else {
            errorMessage = "傳送位置失敗"
            statusMessage = "設定位置失敗"
        }
    }

    func clearLocation() async {
        if streamerReady {
            let _ = await sendToStreamer("CLEAR")
        }
        killStreamer()
        simulatedLocation = nil
        isSimulating = false
        statusMessage = "已恢復真實定位"
    }

    private func killStreamer() {
        if let process = streamerProcess, process.isRunning {
            kill(process.processIdentifier, SIGINT)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { process.terminate() }
            }
        }
        streamerProcess = nil
        streamerStdin = nil
        streamerReady = false
    }
}
