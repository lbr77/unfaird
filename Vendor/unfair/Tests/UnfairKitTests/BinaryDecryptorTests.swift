import Darwin
import Foundation
@testable import UnfairKit
import XCTest

final class BinaryDecryptorTests: XCTestCase {
    private enum EncryptedRegionEvent: Equatable {
        case map(protection: Int32, flags: Int32, fd: Int32, offset: off_t)
        case remap(cryptid: UInt32, cpuType: UInt32, cpuSubtype: UInt32)
        case unmap
    }

    func testEncryptedRegionChunksSplitLargePageAlignedRegion() throws {
        let chunks = try BinaryDecryptor.encryptedRegionChunks(
            fileOffset: 0x24000,
            destinationOffset: 0x24000,
            size: 0x28000,
            maxChunkSize: 0x10000,
            pageSize: 0x4000
        )

        XCTAssertEqual(chunks, [
            BinaryDecryptor.EncryptedRegionChunk(fileOffset: 0x24000, destinationOffset: 0x24000, size: 0x10000),
            BinaryDecryptor.EncryptedRegionChunk(fileOffset: 0x34000, destinationOffset: 0x34000, size: 0x10000),
            BinaryDecryptor.EncryptedRegionChunk(fileOffset: 0x44000, destinationOffset: 0x44000, size: 0x8000),
        ])
    }

    func testEncryptedRegionChunksRejectUnalignedRegion() {
        XCTAssertThrowsError(
            try BinaryDecryptor.encryptedRegionChunks(
                fileOffset: 0x24001,
                destinationOffset: 0x24000,
                size: 0x10000,
                maxChunkSize: 0x10000,
                pageSize: 0x4000
            )
        )
    }

    func testInstallTemporarySinfKeepsExistingBinarySinf() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rootSinf = root.appendingPathComponent("Root.sinf")
        try Data("root".utf8).write(to: rootSinf)

        let framework = root.appendingPathComponent("FirebaseCore.framework", isDirectory: true)
        let scInfo = framework.appendingPathComponent("SC_Info", isDirectory: true)
        try FileManager.default.createDirectory(at: scInfo, withIntermediateDirectories: true)

        let binary = framework.appendingPathComponent("FirebaseCore")
        try Data().write(to: binary)

        let existingSinf = scInfo.appendingPathComponent("FirebaseCore.sinf")
        try Data("framework".utf8).write(to: existingSinf)

        let previousDirectory = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(previousDirectory) }
        FileManager.default.changeCurrentDirectoryPath(framework.path)

        let decryptor = BinaryDecryptor()
        let temporarySinf = try decryptor.installTemporarySinf(
            for: URL(fileURLWithPath: binary.lastPathComponent),
            rootSinf: rootSinf
        )

        XCTAssertNil(temporarySinf)
        XCTAssertEqual(try Data(contentsOf: existingSinf), Data("framework".utf8))
    }

    func testDecryptChunkUsesReadOnlyModelEncryptionLifecycle() throws {
        let size = 16
        let destinationOffset = 4
        let source = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        source.initializeMemory(as: UInt8.self, repeating: 0x11, count: size)
        let destination = UnsafeMutableRawPointer.allocate(
            byteCount: destinationOffset + size,
            alignment: 16
        )
        destination.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: destinationOffset + size
        )
        defer { destination.deallocate() }

        var events: [EncryptedRegionEvent] = []
        let systemCalls = EncryptedRegionSystemCalls(
            map: { address, mappedSize, protection, flags, fd, offset in
                XCTAssertNil(address)
                XCTAssertEqual(mappedSize, size)
                events.append(.map(protection: protection, flags: flags, fd: fd, offset: offset))
                return source
            },
            remap: { address, mappedSize, cryptid, cpuType, cpuSubtype in
                XCTAssertEqual(address, source)
                XCTAssertEqual(mappedSize, size)
                XCTAssertEqual(
                    Data(bytes: destination.advanced(by: destinationOffset), count: size),
                    Data(repeating: 0, count: size)
                )
                source.initializeMemory(as: UInt8.self, repeating: 0xa5, count: size)
                events.append(.remap(cryptid: cryptid, cpuType: cpuType, cpuSubtype: cpuSubtype))
                return 0
            },
            unmap: { address, mappedSize in
                XCTAssertEqual(address, source)
                XCTAssertEqual(mappedSize, size)
                XCTAssertEqual(
                    Data(bytes: destination.advanced(by: destinationOffset), count: size),
                    Data(repeating: 0xa5, count: size)
                )
                events.append(.unmap)
                source.deallocate()
                return 0
            }
        )
        let decryptor = BinaryDecryptor(
            logger: UnfairLogger(log: { _ in }),
            decryptionPreparer: {},
            encryptedRegionSystemCalls: systemCalls
        )

        try decryptor.decryptChunk(
            fd: 42,
            chunk: BinaryDecryptor.EncryptedRegionChunk(
                fileOffset: 0x4000,
                destinationOffset: destinationOffset,
                size: size
            ),
            destinationSliceBase: destination
        )

        XCTAssertEqual(events, [
            .map(protection: PROT_READ, flags: MAP_PRIVATE, fd: 42, offset: 0x4000),
            .remap(
                cryptid: 2,
                cpuType: UInt32(bitPattern: CPU_TYPE_ARM64),
                cpuSubtype: UInt32(CPU_SUBTYPE_ARM64_ALL)
            ),
            .unmap,
        ])
    }

    func testDecryptChunkUnmapsWithoutCopyingAfterRemapFailure() {
        let size = 16
        let source = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        source.initializeMemory(as: UInt8.self, repeating: 0x11, count: size)
        let destination = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        destination.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        defer { destination.deallocate() }

        var events: [EncryptedRegionEvent] = []
        let systemCalls = EncryptedRegionSystemCalls(
            map: { _, _, protection, flags, fd, offset in
                events.append(.map(protection: protection, flags: flags, fd: fd, offset: offset))
                return source
            },
            remap: { _, _, cryptid, cpuType, cpuSubtype in
                events.append(.remap(cryptid: cryptid, cpuType: cpuType, cpuSubtype: cpuSubtype))
                errno = EACCES
                return -1
            },
            unmap: { _, _ in
                XCTAssertEqual(Data(bytes: destination, count: size), Data(repeating: 0, count: size))
                events.append(.unmap)
                source.deallocate()
                return 0
            }
        )
        let decryptor = BinaryDecryptor(
            logger: UnfairLogger(log: { _ in }),
            decryptionPreparer: {},
            encryptedRegionSystemCalls: systemCalls
        )

        XCTAssertThrowsError(
            try decryptor.decryptChunk(
                fd: 42,
                chunk: BinaryDecryptor.EncryptedRegionChunk(
                    fileOffset: 0x4000,
                    destinationOffset: 0,
                    size: size
                ),
                destinationSliceBase: destination
            )
        ) { error in
            guard case UnfairError.decryptFailed(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(message, "mremap_encrypted failed: Permission denied")
        }

        XCTAssertEqual(events, [
            .map(protection: PROT_READ, flags: MAP_PRIVATE, fd: 42, offset: 0x4000),
            .remap(
                cryptid: 2,
                cpuType: UInt32(bitPattern: CPU_TYPE_ARM64),
                cpuSubtype: UInt32(CPU_SUBTYPE_ARM64_ALL)
            ),
            .unmap,
        ])
    }
}
