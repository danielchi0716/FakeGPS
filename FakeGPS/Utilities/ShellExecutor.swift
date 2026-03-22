import Foundation

struct ShellResult {
    let exitCode: Int32
    let output: String
    let error: String
}

/// Handle for a privileged background process started via macOS authorization.
/// Monitors the process via PID and reads output from temp files.
class PrivilegedProcess {
    let pid: pid_t
    let stdoutPath: String
    let stderrPath: String

    init(pid: pid_t, stdoutPath: String, stderrPath: String) {
        self.pid = pid
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
    }

    var isRunning: Bool {
        // kill(pid, 0) returns 0 if we have permission, or -1 with errno.
        // EPERM means process exists but is owned by another user (root) — still running.
        // ESRCH means process does not exist — not running.
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    func terminate() {
        kill(pid, SIGTERM)
    }

    func forceKill() {
        kill(pid, SIGKILL)
    }

    /// Block until the process exits (polls since we can't waitpid on non-child root processes).
    func waitUntilExit() {
        while isRunning {
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: stdoutPath)
        try? FileManager.default.removeItem(atPath: stderrPath)
    }

    deinit {
        cleanup()
    }
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

    /// Start a long-running privileged process using macOS native authorization dialog.
    /// Uses `do shell script ... with administrator privileges` (AppleScript) to show the
    /// system authentication prompt, then runs the command as root in the background.
    /// Returns a PrivilegedProcess handle for monitoring and cleanup.
    static func startSudoProcess(command: String, arguments: [String] = [], cleanupBefore: String? = nil) async throws -> PrivilegedProcess {
        let stdoutPath = NSTemporaryDirectory() + "fakegps_sudo_stdout_\(ProcessInfo.processInfo.processIdentifier)"
        let stderrPath = NSTemporaryDirectory() + "fakegps_sudo_stderr_\(ProcessInfo.processInfo.processIdentifier)"

        // Pre-create output files as current user so they remain user-owned and deletable
        FileManager.default.createFile(atPath: stdoutPath, contents: nil)
        FileManager.default.createFile(atPath: stderrPath, contents: nil)

        // Write a shell script to a temp file to avoid AppleScript escaping issues
        let shellScriptPath = NSTemporaryDirectory() + "fakegps_sudo_cmd_\(ProcessInfo.processInfo.processIdentifier).sh"
        var shellLines = ["#!/bin/sh"]
        if let cleanup = cleanupBefore {
            shellLines.append(cleanup)
        }
        let escapedArgs = arguments.map { "'\($0)'" }.joined(separator: " ")
        shellLines.append("'\(command)' \(escapedArgs) >> '\(stdoutPath)' 2>> '\(stderrPath)' &")
        shellLines.append("echo $!")
        try shellLines.joined(separator: "\n").write(toFile: shellScriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shellScriptPath)

        // AppleScript: run the shell script file with administrator privileges
        let appleScript = "do shell script \"'\(shellScriptPath)'\" with administrator privileges"

        // Run osascript — this shows the native macOS authorization dialog
        let osascript = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osascript.arguments = ["-e", appleScript]
        osascript.standardOutput = outPipe
        osascript.standardError = errPipe

        let pidString: String = try await withCheckedThrowingContinuation { continuation in
            osascript.terminationHandler = { _ in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if osascript.terminationStatus != 0 || output.isEmpty {
                    // Clean up temp files on failure
                    try? FileManager.default.removeItem(atPath: stdoutPath)
                    try? FileManager.default.removeItem(atPath: stderrPath)
                    continuation.resume(throwing: NSError(
                        domain: "ShellExecutor",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "使用者取消了授權"]
                    ))
                } else {
                    continuation.resume(returning: output)
                }
            }

            do {
                try osascript.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        // Clean up temp shell script
        try? FileManager.default.removeItem(atPath: shellScriptPath)

        guard let pid = pid_t(pidString) else {
            throw NSError(domain: "ShellExecutor", code: -1, userInfo: [NSLocalizedDescriptionKey: "無法取得背景程序 PID"])
        }

        return PrivilegedProcess(pid: pid, stdoutPath: stdoutPath, stderrPath: stderrPath)
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
