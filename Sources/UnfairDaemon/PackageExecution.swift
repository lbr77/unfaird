import Foundation
import UnfairKit

struct PackageExecutionResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum PackageExecution {
    private static let lock = NSLock()

    static func process(
        input: URL,
        output: URL,
        workingDirectory: URL?,
        verbose: Bool,
        log: @escaping (String) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        try PackageProcessor(
            logger: UnfairLogger(verbose: verbose, log: log)
        ).process(
            input: input,
            output: output,
            workingDirectory: workingDirectory
        )
    }

    static func run(
        input: URL,
        output: URL,
        workingDirectory: URL?,
        verbose: Bool
    ) -> PackageExecutionResult {
        var lines: [String] = []
        do {
            try process(
                input: input,
                output: output,
                workingDirectory: workingDirectory,
                verbose: verbose,
                log: { lines.append($0) }
            )
            return PackageExecutionResult(
                exitCode: 0,
                stdout: outputText(lines),
                stderr: ""
            )
        } catch {
            return PackageExecutionResult(
                exitCode: 1,
                stdout: outputText(lines),
                stderr: String(describing: error) + "\n"
            )
        }
    }

    private static func outputText(_ lines: [String]) -> String {
        guard lines.isEmpty == false else {
            return ""
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
