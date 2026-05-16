import Foundation
import Vapor

enum RuntimeEnvironment {
    static func resolveTemporaryDirectory() throws -> URL {
        if let tmpDir = ProcessInfo.processInfo.environment["TMPDIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           tmpDir.isEmpty == false {
            return URL(fileURLWithPath: tmpDir, isDirectory: true).standardizedFileURL
        }

        #if os(iOS)
        let temporaryDirectory = URL(fileURLWithPath: "/var/folders/bg/unfaird/T", isDirectory: true)
        let packageRoot = temporaryDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("X", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        return temporaryDirectory.standardizedFileURL
        #else

        let foldersRoot = URL(fileURLWithPath: "/var/folders/bg", isDirectory: true)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: foldersRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for candidate in candidates {
            let temporaryDirectory = candidate.appendingPathComponent("T", isDirectory: true)
            let packageRoot = candidate.appendingPathComponent("X", isDirectory: true)
            if isDirectory(temporaryDirectory), isDirectory(packageRoot) {
                return temporaryDirectory.standardizedFileURL
            }
        }

        throw Abort(.internalServerError, reason: "TMPDIR environment variable missing and /var/folders/bg has no T/X temp root")
        #endif
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
