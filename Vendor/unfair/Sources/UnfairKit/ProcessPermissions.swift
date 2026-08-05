import Foundation
import UnfairSupport

public enum UnfairProcessPermissions {
    public static func prepareForAppBundleDecryption(logger: UnfairLogger = UnfairLogger()) throws {
        var message = [CChar](repeating: 0, count: 512)
        let result = message.withUnsafeMutableBufferPointer { buffer in
            unfair_prepare_app_bundle_decryption(buffer.baseAddress, buffer.count)
        }
        guard result == 0 else {
            throw UnfairError.io("decryption permission setup failed: \(String(cString: message))")
        }
        logger.verbose("decryption permission setup complete")
    }
}
