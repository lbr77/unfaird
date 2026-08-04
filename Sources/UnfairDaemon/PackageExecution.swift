import Foundation
import UnfairDaemonSupport
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

        try prepareKernelDecryption()
        unfaird_set_mapping_promotion_enabled(true)
        defer { unfaird_set_mapping_promotion_enabled(false) }

        try PackageProcessor(
            logger: UnfairLogger(verbose: verbose, log: log),
            encryptedRegionMapper: { address, size, protection, flags, fd, offset in
                unfaird_map_encrypted_region(address, size, protection, flags, fd, offset)
            }
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
            let mappingError = String(cString: unfaird_last_mapping_error())
            let details = mappingError.isEmpty ? String(describing: error) : "\(error)\nkernel mapping: \(mappingError)"
            return PackageExecutionResult(
                exitCode: 1,
                stdout: outputText(lines),
                stderr: details + "\n"
            )
        }
    }

    private static func prepareKernelDecryption() throws {
        var message = [CChar](repeating: 0, count: 512)
        let result = message.withUnsafeMutableBufferPointer { buffer in
            unfaird_prepare_kernel_decryption(buffer.baseAddress, buffer.count)
        }
        guard result == 0 else {
            throw PackageExecutionError.kernelPreparation(String(cString: message))
        }
    }

    private static func outputText(_ lines: [String]) -> String {
        guard lines.isEmpty == false else {
            return ""
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private enum PackageExecutionError: Error, CustomStringConvertible {
    case kernelPreparation(String)

    var description: String {
        switch self {
        case .kernelPreparation(let message):
            return "kernel decryption preparation failed: \(message)"
        }
    }
}
