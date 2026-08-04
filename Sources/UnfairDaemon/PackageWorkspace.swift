import Foundation

enum PackageWorkspace {
    static func workingDirectory(for jobID: UUID) throws -> URL {
        try packageTemporaryRoot()
            .appendingPathComponent(jobID.uuidString.lowercased(), isDirectory: true)
            .standardizedFileURL
    }

    private static func packageTemporaryRoot() throws -> URL {
        try RuntimeEnvironment.resolveTemporaryDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("X", isDirectory: true)
            .appendingPathComponent("unfair", isDirectory: true)
            .standardizedFileURL
    }
}
