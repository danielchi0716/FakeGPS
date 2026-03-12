import Foundation

struct ShellResult {
    let exitCode: Int32
    let output: String
    let error: String
}

actor ShellExecutor {

    /// Run a command asynchronously and return its result after it finishes.
    static func run(_ command: String, arguments: [String] = [], environment: [String: String]? = nil) async throws -> ShellResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        // Read stdout/stderr concurrently on background threads to avoid pipe buffer deadlocks.
        // We must read BEFORE calling waitUntilExit, not after.
        let outCollector = LockedValue(Data())
        let errCollector = LockedValue(Data())

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if d.isEmpty {
                // EOF — stop reading
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                outCollector.update { $0.append(d) }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if d.isEmpty {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                errCollector.update { $0.append(d) }
            }
        }

        try process.run()

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                // Give readability handlers a moment to drain
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let result = ShellResult(
                        exitCode: process.terminationStatus,
                        output: String(data: outCollector.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                        error: String(data: errCollector.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    )
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// Prompt the user for their admin password using AppleScript dialog, then
    /// start a long-running sudo process (e.g. tunnel). Returns the Process handle.
    /// If `cleanupBefore` is provided, it runs that shell command with sudo first (same password, no extra prompt).
    static func startSudoProcess(command: String, arguments: [String] = [], cleanupBefore: String? = nil) async throws -> (Process, Pipe, Pipe) {
        let password = try await promptForPassword()
        let passwordData = (password + "\n").data(using: .utf8)!

        // Run cleanup command with the same password if needed
        if let cleanup = cleanupBefore {
            let cleanupProcess = Process()
            let cleanupStdin = Pipe()
            cleanupProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            cleanupProcess.arguments = ["-S", "/bin/sh", "-c", cleanup]
            cleanupProcess.standardInput = cleanupStdin
            cleanupProcess.standardOutput = FileHandle.nullDevice
            cleanupProcess.standardError = FileHandle.nullDevice
            try cleanupProcess.run()
            cleanupStdin.fileHandleForWriting.write(passwordData)
            cleanupStdin.fileHandleForWriting.closeFile()
            cleanupProcess.waitUntilExit()
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-S", command] + arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write password to stdin for sudo -S (sudo caches credentials briefly, but send it anyway)
        stdinPipe.fileHandleForWriting.write(passwordData)

        return (process, stdoutPipe, stderrPipe)
    }

    /// Show a macOS password prompt via AppleScript and return the entered password.
    private static func promptForPassword() async throws -> String {
        let script = """
        tell application "System Events"
            set pwd to text returned of (display dialog "FakeGPS 需要管理員權限來啟動 Tunnel\n請輸入 Mac 登入密碼：" default answer "" with hidden answer with title "輸入密碼" buttons {"取消", "確定"} default button "確定")
        end tell
        """

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let password = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus != 0 || password.isEmpty {
                    continuation.resume(throwing: NSError(
                        domain: "ShellExecutor",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "使用者取消了密碼輸入"]
                    ))
                } else {
                    continuation.resume(returning: password)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Run a command that doesn't exit on its own (e.g. `simulate-location set`).
    /// Waits until stdout/stderr contains output indicating success, then sends SIGINT to stop it.
    /// Falls back to a timeout if no output is detected.
    static func runAndKill(_ command: String, arguments: [String] = [], timeoutSeconds: TimeInterval = 10) async throws -> ShellResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let outCollector = LockedValue(Data())
        let errCollector = LockedValue(Data())
        let gotOutput = LockedValue(false)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if d.isEmpty {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                outCollector.update { $0.append(d) }
                gotOutput.update { $0 = true }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if d.isEmpty {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                errCollector.update { $0.append(d) }
                gotOutput.update { $0 = true }
            }
        }

        try process.run()

        // Poll until we get output (location applied) or timeout
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            if gotOutput.value { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Give it a tiny bit more time after first output to ensure location is applied
        if gotOutput.value {
            try? await Task.sleep(for: .milliseconds(200))
        }

        if process.isRunning {
            // Send SIGINT (like Ctrl+C) for graceful shutdown
            kill(process.processIdentifier, SIGINT)
            // Give it a moment to clean up
            try? await Task.sleep(for: .milliseconds(300))
            if process.isRunning {
                process.terminate()
            }
        }
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let stderr = String(data: errCollector.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let hasError = stderr.contains("Traceback") || stderr.contains("AttributeError") || stderr.contains("ConnectionError")
        return ShellResult(
            exitCode: hasError ? 1 : 0,
            output: String(data: outCollector.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            error: stderr
        )
    }

    /// Start a long-running process (no sudo) and return the Process handle.
    static func startLongRunning(_ command: String, arguments: [String] = []) throws -> (Process, Pipe, Pipe) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        return (process, stdoutPipe, stderrPipe)
    }
}
