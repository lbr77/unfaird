import Foundation
@testable import UnfairKit
import XCTest
import ZIPFoundation

final class PackageArchiveWriterTests: XCTestCase {
    func testRewritesArchiveWithDecryptedBinaryAndWithoutFairPlayUserInfo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let input = root.appendingPathComponent("input.ipa")
        let output = root.appendingPathComponent("output.ipa")
        let decryptedBinary = root.appendingPathComponent("CENFC.decrypted")
        try Data("decrypted".utf8).write(to: decryptedBinary)

        let inputArchive = try Archive(url: input, accessMode: .create, pathEncoding: nil)
        try inputArchive.addDataEntry(with: "Payload/CENFC.app/", type: .directory, data: Data())
        try inputArchive.addDataEntry(with: "Payload/CENFC.app/CENFC", data: Data("encrypted".utf8))
        try inputArchive.addDataEntry(with: "Payload/CENFC.app/Info.plist", data: Data("info".utf8))
        try inputArchive.addDataEntry(with: "Payload/CENFC.app/SC_Info/", type: .directory, data: Data())
        try inputArchive.addDataEntry(with: "Payload/CENFC.app/SC_Info/CENFC.sinf", data: Data("user".utf8))

        let writer = PackageArchiveWriter(logger: UnfairLogger())
        try writer.writeArchive(
            input: input,
            replacements: [
                ArchiveReplacement(path: "Payload/CENFC.app/CENFC", url: decryptedBinary),
            ],
            to: output
        )

        try assertValidZip(output)
        let outputArchive = try Archive(url: output, accessMode: .read, pathEncoding: nil)
        let paths = Set(outputArchive.map(\.path))
        XCTAssertTrue(paths.contains("Payload/CENFC.app/CENFC"))
        XCTAssertTrue(paths.contains("Payload/CENFC.app/Info.plist"))
        XCTAssertFalse(paths.contains("Payload/CENFC.app/SC_Info/"))
        XCTAssertFalse(paths.contains("Payload/CENFC.app/SC_Info/CENFC.sinf"))
        XCTAssertEqual(try outputArchive.data(for: "Payload/CENFC.app/CENFC"), Data("decrypted".utf8))
    }

    func testCopiesLargeEntryFromSourceRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let assetDirectory = sourceRoot
            .appendingPathComponent("Payload", isDirectory: true)
            .appendingPathComponent("CENFC.app", isDirectory: true)
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)

        let asset = assetDirectory.appendingPathComponent("LargeAsset.bin")
        _ = FileManager.default.createFile(atPath: asset.path, contents: nil)
        let handle = try FileHandle(forWritingTo: asset)
        defer { try? handle.close() }
        let chunk = Data(repeating: 0xab, count: 1024 * 1024)
        for _ in 0..<12 {
            handle.write(chunk)
        }

        let input = root.appendingPathComponent("input.ipa")
        let output = root.appendingPathComponent("output.ipa")
        let inputArchive = try Archive(url: input, accessMode: .create, pathEncoding: nil)
        try inputArchive.addDataEntry(with: "Payload/CENFC.app/", type: .directory, data: Data())
        try inputArchive.addDataEntry(with: "Payload/CENFC.app/LargeAsset.bin", data: Data("archive".utf8))

        let writer = PackageArchiveWriter(logger: UnfairLogger())
        try writer.writeArchive(
            input: input,
            sourceRoot: sourceRoot,
            replacements: [],
            to: output
        )

        let outputArchive = try Archive(url: output, accessMode: .read, pathEncoding: nil)
        let entry = try XCTUnwrap(outputArchive["Payload/CENFC.app/LargeAsset.bin"])
        var extractedBytes = 0
        _ = try outputArchive.extract(entry) { data in
            extractedBytes += data.count
            XCTAssertTrue(data.allSatisfy { $0 == 0xab })
        }
        XCTAssertEqual(extractedBytes, 12 * 1024 * 1024)
    }
}

private extension Archive {
    func addDataEntry(with path: String, type: Entry.EntryType = .file, data: Data) throws {
        try addEntry(
            with: path,
            type: type,
            uncompressedSize: Int64(data.count),
            provider: { position, size in
                let start = Int(position)
                let end = Swift.min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        )
    }

    func data(for path: String) throws -> Data {
        let entry = try XCTUnwrap(self[path])
        var data = Data()
        _ = try extract(entry) { chunk in
            data.append(chunk)
        }
        return data
    }
}

private func assertValidZip(_ url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-t", url.path]

    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()

    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
    XCTAssertEqual(process.terminationStatus, 0, text)
}
