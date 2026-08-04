import Foundation
import UnfairDaemonSupport
import UnfairKit

struct PackageExecutionResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private struct EncryptedMappingLifecycleError: Error, CustomStringConvertible {
    let description: String
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

        unfaird_set_mapping_promotion_enabled(true)
        defer { unfaird_set_mapping_promotion_enabled(false) }

        try PackageProcessor(
            logger: UnfairLogger(verbose: verbose, log: log),
            decryptionPreparer: prepareEncryptedRegion,
            encryptedRegionMapper: { address, size, protection, flags, fd, offset in
                guard let mapping = unfaird_map_encrypted_region(
                    address,
                    size,
                    protection,
                    flags,
                    fd,
                    offset
                ),
                      mapping != MAP_FAILED
                else {
                    return nil
                }
                return BinaryDecryptor.EncryptedRegionMapping(
                    address: mapping,
                    restoreReadProtection: {
                        guard unfaird_restore_encrypted_region(mapping, size) == 0 else {
                            throw EncryptedMappingLifecycleError(
                                description: String(cString: unfaird_last_mapping_error())
                            )
                        }
                    }
                )
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

    private static func prepareEncryptedRegion() throws -> BinaryDecryptor.DecryptionPreparation {
        var message = [CChar](repeating: 0, count: 512)
        let status = message.withUnsafeMutableBufferPointer { buffer in
            unfaird_prepare_encrypted_region(buffer.baseAddress, buffer.count)
        }
        guard status == 0 else {
            throw EncryptedMappingLifecycleError(description: String(cString: message))
        }

        return BinaryDecryptor.DecryptionPreparation {
            guard unfaird_finish_encrypted_region_preparation() == 0 else {
                throw EncryptedMappingLifecycleError(
                    description: String(cString: unfaird_last_mapping_error())
                )
            }
        }
    }

    private static func outputText(_ lines: [String]) -> String {
        guard lines.isEmpty == false else {
            return ""
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
