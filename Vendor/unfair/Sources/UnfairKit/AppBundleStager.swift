import Darwin
import Foundation

#if os(iOS)
struct StagedAppBundle {
    var containerURL: URL
    var appURL: URL
}

struct StagedBinary {
    var bundle: StagedAppBundle
    var binaryURL: URL
    var rootSinf: URL
}

enum AppBundleStager {
    private static let applicationBundleRoot = URL(
        fileURLWithPath: "/var/containers/Bundle/Application",
        isDirectory: true
    )

    static func isInsideApplicationBundleRoot(_ url: URL) -> Bool {
        let paths = [
            url.standardizedFileURL.path,
            url.standardizedFileURL.resolvingSymlinksInPath().path,
        ]
        let root = applicationBundleRoot.standardizedFileURL.path
        return paths.contains { path in
            path == root || path.hasPrefix(root + "/")
        }
    }

    static func stageBinary(_ binaryURL: URL, rootSinf: URL, logger: UnfairLogger) throws -> StagedBinary {
        let appName = binaryURL.lastPathComponent + ".app"
        let bundle = try createBundle(appName: appName, logger: logger)
        let stagedBinary = bundle.appURL.appendingPathComponent(binaryURL.lastPathComponent)
        try copyFile(binaryURL, to: stagedBinary)
        try FileSystem.chmod(stagedBinary, mode: 0o755)

        let stagedSinf = try copyCredentials(
            from: rootSinf.deletingLastPathComponent(),
            explicitRootSinf: rootSinf,
            binaryName: binaryURL.lastPathComponent,
            to: bundle.appURL
        )
        try applyInstalledAppOwnership(to: bundle.containerURL)

        return StagedBinary(bundle: bundle, binaryURL: stagedBinary, rootSinf: stagedSinf)
    }

    static func stageAppBundle(sourceApp: URL, encryptedRecords: [MachORecord], logger: UnfairLogger) throws -> StagedAppBundle {
        let bundle = try createBundle(appName: sourceApp.lastPathComponent, logger: logger)
        let sourceSCInfo = sourceApp.appendingPathComponent("SC_Info", isDirectory: true)
        _ = try copyCredentials(from: sourceSCInfo, explicitRootSinf: nil, binaryName: nil, to: bundle.appURL)

        for record in encryptedRecords {
            let relativePath = try relativePath(of: record.url, in: sourceApp)
            let destination = bundle.appURL.appendingPathComponent(relativePath)
            try copyFile(record.url, to: destination)
            let sourceSCInfo = record.url.deletingLastPathComponent().appendingPathComponent("SC_Info", isDirectory: true)
            _ = try copyCredentials(
                from: sourceSCInfo,
                explicitRootSinf: nil,
                binaryName: record.name,
                to: destination.deletingLastPathComponent()
            )
            try FileSystem.chmod(destination, mode: 0o755)
        }
        try applyInstalledAppOwnership(to: bundle.containerURL)
        logger.verbose("staged encrypted binaries: \(encryptedRecords.count)")

        return bundle
    }

    static func cleanup(_ bundle: StagedAppBundle) {
        FileSystem.removeTree(bundle.containerURL)
    }

    private static func createBundle(appName: String, logger: UnfairLogger) throws -> StagedAppBundle {
        let container = applicationBundleRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = container.appendingPathComponent(appName, isDirectory: true)
        try createStagingDirectory(container)
        do {
            try createStagingDirectory(app)
        } catch {
            FileSystem.removeTree(container)
            throw error
        }
        logger.log("staged app: \(app.path)")
        return StagedAppBundle(containerURL: container, appURL: app)
    }

    private static func createStagingDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o755) == 0 else {
            throw UnfairError.io(
                "mkdir staging directory failed: \(url.path): " +
                "errno=\(errno) \(String(cString: strerror(errno)))"
            )
        }
    }

    private static func applyInstalledAppOwnership(to url: URL) throws {
        guard let user = getpwnam("_installd"), let group = getgrnam("_installd") else {
            throw UnfairError.io("_installd user/group missing")
        }
        try chownRecursively(url, uid: user.pointee.pw_uid, gid: group.pointee.gr_gid)
    }

    private static func chownRecursively(_ url: URL, uid: uid_t, gid: gid_t) throws {
        try chownItem(url, uid: uid, gid: gid)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return
        }
        for case let child as URL in enumerator {
            try chownItem(child, uid: uid, gid: gid)
        }
    }

    private static func chownItem(_ url: URL, uid: uid_t, gid: gid_t) throws {
        guard chown(url.path, uid, gid) == 0 else {
            throw UnfairError.io("chown failed: \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    @discardableResult
    private static func copyCredentials(from sourceSCInfo: URL, explicitRootSinf: URL?, binaryName: String?, to appURL: URL) throws -> URL {
        let destinationSCInfo = appURL.appendingPathComponent("SC_Info", isDirectory: true)
        try FileSystem.createDirectory(destinationSCInfo)

        if let children = try? FileManager.default.contentsOfDirectory(
            at: sourceSCInfo,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) {
            for child in children {
                let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    continue
                }
                guard shouldCopyCredential(child.lastPathComponent, binaryName: binaryName) else {
                    continue
                }
                try copyFile(child, to: destinationSCInfo.appendingPathComponent(child.lastPathComponent))
            }
        }

        if let explicitRootSinf {
            let stagedRootSinf = destinationSCInfo.appendingPathComponent((binaryName ?? explicitRootSinf.deletingPathExtension().lastPathComponent) + ".sinf")
            if FileManager.default.fileExists(atPath: stagedRootSinf.path) == false {
                try copyFile(explicitRootSinf, to: stagedRootSinf)
            }
            return stagedRootSinf
        }

        if let binaryName {
            return destinationSCInfo.appendingPathComponent(binaryName + ".sinf")
        }
        return destinationSCInfo
    }

    private static func shouldCopyCredential(_ name: String, binaryName: String?) -> Bool {
        guard let binaryName else {
            return true
        }
        return name == "Manifest.plist" || name.hasPrefix(binaryName + ".")
    }

    private static func copyFile(_ source: URL, to destination: URL) throws {
        try FileSystem.createDirectory(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func relativePath(of child: URL, in root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let childPath = child.standardizedFileURL.path
        guard childPath.hasPrefix(rootPath) else {
            throw UnfairError.io("path is outside app bundle: \(child.path)")
        }
        return String(childPath.dropFirst(rootPath.count))
    }
}
#endif
