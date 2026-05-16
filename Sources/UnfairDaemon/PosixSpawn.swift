import Darwin
import Foundation
import Vapor

struct PosixSpawnResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data

    var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? stdout.base64EncodedString()
    }

    var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? stderr.base64EncodedString()
    }
}

enum PosixSpawn {
    #if os(iOS)
    private static let spawnWorkingDirectoryLock = NSLock()
    #endif

    static func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL,
        sandboxProfileURL: URL? = nil,
        timeoutSeconds: Int? = nil
    ) throws -> PosixSpawnResult {
        let stdoutURL = workingDirectory.appendingPathComponent("stdout.log")
        let stderrURL = workingDirectory.appendingPathComponent("stderr.log")
        let launch = launchCommand(
            executablePath: executablePath,
            arguments: arguments,
            sandboxProfileURL: sandboxProfileURL
        )

        var actions: posix_spawn_file_actions_t?
        try throwIfFailed(posix_spawn_file_actions_init(&actions), operation: "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }

        #if !os(iOS)
        try throwIfFailed(posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path), operation: "posix_spawn_file_actions_addchdir_np")
        #endif
        try throwIfFailed(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, stdoutURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644), operation: "stdout redirect")
        try throwIfFailed(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, stderrURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644), operation: "stderr redirect")

        var attributes: posix_spawnattr_t?
        try throwIfFailed(posix_spawnattr_init(&attributes), operation: "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }
        try throwIfFailed(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)), operation: "posix_spawnattr_setflags")
        try throwIfFailed(posix_spawnattr_setpgroup(&attributes, 0), operation: "posix_spawnattr_setpgroup")

        let rawArguments = ([launch.executablePath] + launch.arguments).map { strdup($0) }
        defer {
            for pointer in rawArguments {
                free(pointer)
            }
        }
        var argv = rawArguments + [nil]

        var pid: pid_t = 0

        #if os(iOS)
        try spawnFromWorkingDirectory(
            workingDirectory,
            pid: &pid,
            executablePath: launch.executablePath,
            actions: &actions,
            attributes: &attributes,
            argv: &argv
        )
        #else
        let spawnStatus = posix_spawn(&pid, launch.executablePath, &actions, &attributes, &argv, nil)
        try throwIfFailed(spawnStatus, operation: "posix_spawn \(launch.executablePath)")
        #endif

        let waitStatus = try wait(for: pid, timeoutSeconds: timeoutSeconds)

        let stdout = try Data(contentsOf: stdoutURL)
        let stderr = try Data(contentsOf: stderrURL)
        return PosixSpawnResult(exitCode: exitCode(from: waitStatus), stdout: stdout, stderr: stderr)
    }

    #if os(iOS)
    private static func spawnFromWorkingDirectory(
        _ workingDirectory: URL,
        pid: inout pid_t,
        executablePath: String,
        actions: inout posix_spawn_file_actions_t?,
        attributes: inout posix_spawnattr_t?,
        argv: inout [UnsafeMutablePointer<CChar>?]
    ) throws {
        spawnWorkingDirectoryLock.lock()
        defer { spawnWorkingDirectoryLock.unlock() }

        let originalDirectory = FileManager.default.currentDirectoryPath
        try throwIfFailed(chdir(workingDirectory.path), operation: "chdir")
        let spawnStatus = posix_spawn(&pid, executablePath, &actions, &attributes, &argv, nil)
        let restoreStatus = chdir(originalDirectory)
        try throwIfFailed(restoreStatus, operation: "restore working directory")
        try throwIfFailed(spawnStatus, operation: "posix_spawn \(executablePath)")
    }
    #endif

    private static func launchCommand(
        executablePath: String,
        arguments: [String],
        sandboxProfileURL: URL?
    ) -> (executablePath: String, arguments: [String]) {
        guard let sandboxProfileURL = sandboxProfileURL else {
            return (executablePath, arguments)
        }
        return (
            PackageRunnerSandbox.sandboxExecPath,
            ["-f", sandboxProfileURL.path, executablePath] + arguments
        )
    }

    private static func throwIfFailed(_ status: Int32, operation: String) throws {
        guard status == 0 else {
            throw Abort(.internalServerError, reason: "\(operation) failed: \(String(cString: strerror(status)))")
        }
    }

    private static func wait(for pid: pid_t, timeoutSeconds: Int?) throws -> Int32 {
        var waitStatus: Int32 = 0
        guard let timeoutSeconds = timeoutSeconds else {
            while waitpid(pid, &waitStatus, 0) == -1 {
                if errno == EINTR {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return waitStatus
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while true {
            let result = waitpid(pid, &waitStatus, WNOHANG)
            if result == pid {
                return waitStatus
            }
            if result == -1 {
                if errno == EINTR {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if Date() >= deadline {
                kill(-pid, SIGKILL)
                _ = waitpid(pid, &waitStatus, 0)
                throw Abort(.requestTimeout, reason: "decrypt timed out after \(timeoutSeconds) seconds")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let status = waitStatus & 0x7f
        if status == 0 {
            return (waitStatus >> 8) & 0xff
        }
        if status != 0x7f {
            return 128 + status
        }
        return waitStatus
    }
}
