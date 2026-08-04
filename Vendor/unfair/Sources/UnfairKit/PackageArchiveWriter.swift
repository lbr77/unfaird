import Darwin
import Foundation
import ZIPFoundation

struct ArchiveReplacement {
    var path: String
    var url: URL
}

struct PackageArchiveWriter {
    private static let fileBufferSize = 64 * 1024
    private static let zipVersionMadeBy = UInt16(0x0314)
    private static let zipVersionNeeded = UInt16(20)
    private static let zipUTF8Flag = UInt16(1 << 11)
    private static let zipStoreMethod = UInt16(0)

    var logger: UnfairLogger

    func writeArchive(input: URL, sourceRoot: URL? = nil, replacements: [ArchiveReplacement], to destination: URL) throws {
        try FileSystem.createDirectory(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let inputArchive = try Archive(url: input, accessMode: .read, pathEncoding: nil)
        let replacementByPath = Dictionary(uniqueKeysWithValues: replacements.map { ($0.path, $0) })
        var replacedPaths = Set<String>()
        var state = ZipWriteState()

        let outputFD = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard outputFD >= 0 else {
            throw UnfairError.io("open output archive failed: \(String(cString: strerror(errno)))")
        }
        defer { close(outputFD) }

        let centralDirectoryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).central.\(UUID().uuidString)")
        let centralDirectoryFD = open(centralDirectoryURL.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard centralDirectoryFD >= 0 else {
            throw UnfairError.io("open central directory temp failed: \(String(cString: strerror(errno)))")
        }
        defer {
            close(centralDirectoryFD)
            try? FileManager.default.removeItem(at: centralDirectoryURL)
        }

        for entry in inputArchive {
            try autoreleasepool(invoking: {
                if entry.type == .symlink {
                    logger.verbose("skipped symlink in output: \(entry.path)")
                    return
                }
                if ArchivePrivacyFilter.shouldRemoveEntry(path: entry.path, isDirectory: entry.type == .directory) {
                    logger.verbose("removed privacy-sensitive archive entry: \(entry.path)")
                    return
                }
                if let replacement = replacementByPath[entry.path] {
                    try addEntry(
                        entry,
                        path: replacement.path,
                        source: replacement.url,
                        outputFD: outputFD,
                        centralDirectoryFD: centralDirectoryFD,
                        state: &state
                    )
                    replacedPaths.insert(entry.path)
                    return
                }

                try copyEntry(
                    entry,
                    from: inputArchive,
                    sourceRoot: sourceRoot,
                    outputFD: outputFD,
                    centralDirectoryFD: centralDirectoryFD,
                    state: &state
                )
            })
        }

        let missing = Set(replacementByPath.keys).subtracting(replacedPaths)
        guard missing.isEmpty else {
            throw UnfairError.io("archive entry missing: \(missing.sorted().joined(separator: ", "))")
        }

        guard lseek(centralDirectoryFD, 0, SEEK_SET) >= 0 else {
            throw UnfairError.io("seek central directory temp failed: \(String(cString: strerror(errno)))")
        }
        try copyBytes(fromFD: centralDirectoryFD, toFD: outputFD)

        let end = try endOfCentralDirectory(
            entryCount: state.entryCount,
            centralDirectorySize: state.centralDirectorySize,
            centralDirectoryOffset: state.localFileSize
        )
        try writeData(end, to: outputFD)
    }

    private func copyEntry(
        _ entry: Entry,
        from inputArchive: Archive,
        sourceRoot: URL?,
        outputFD: Int32,
        centralDirectoryFD: Int32,
        state: inout ZipWriteState
    ) throws {
        if entry.type != .file {
            try addEntry(
                entry,
                path: entry.path,
                source: nil,
                outputFD: outputFD,
                centralDirectoryFD: centralDirectoryFD,
                state: &state
            )
            return
        }

        if let sourceRoot {
            let source = try sourceURL(for: entry.path, in: sourceRoot)
            try addEntry(
                entry,
                path: entry.path,
                source: source,
                outputFD: outputFD,
                centralDirectoryFD: centralDirectoryFD,
                state: &state
            )
            return
        }

        try withTemporaryExtractedFile(entry, from: inputArchive) { source in
            try addEntry(
                entry,
                path: entry.path,
                source: source,
                outputFD: outputFD,
                centralDirectoryFD: centralDirectoryFD,
                state: &state
            )
        }
    }

    private func addEntry(
        _ entry: Entry,
        path: String,
        source: URL?,
        outputFD: Int32,
        centralDirectoryFD: Int32,
        state: inout ZipWriteState
    ) throws {
        let normalizedPath = normalizedPath(path, type: entry.type)
        let pathBytes = Array(normalizedPath.utf8)
        _ = try zip16(pathBytes.count, label: "entry path length")

        let attributes = entry.fileAttributes
        let modificationDate = attributes[.modificationDate] as? Date ?? Date()
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? defaultPermissions(for: entry)
        let dateTime = dosDateTime(modificationDate)
        let fileInfo = try storedFileInfo(for: entry, source: source)
        let localHeaderOffset = state.localFileSize

        let localHeader = try localFileHeader(pathBytes: pathBytes, fileInfo: fileInfo, dateTime: dateTime)
        try writeData(localHeader, to: outputFD)
        state.localFileSize += UInt64(localHeader.count)

        if entry.type == .file, let source {
            try copyFile(source, toFD: outputFD)
            state.localFileSize += fileInfo.size
        }

        let centralDirectoryHeader = try centralDirectoryHeader(
            pathBytes: pathBytes,
            fileInfo: fileInfo,
            dateTime: dateTime,
            permissions: permissions,
            type: entry.type,
            localHeaderOffset: localHeaderOffset
        )
        try writeData(centralDirectoryHeader, to: centralDirectoryFD)
        state.centralDirectorySize += UInt64(centralDirectoryHeader.count)
        state.entryCount += 1
    }

    private func storedFileInfo(for entry: Entry, source: URL?) throws -> StoredFileInfo {
        guard entry.type == .file else {
            return StoredFileInfo(size: 0, crc32: 0)
        }
        guard let source else {
            throw UnfairError.io("archive file source missing: \(entry.path)")
        }
        let fileSize = try FileSystem.fileSize(source)
        guard fileSize >= 0 else {
            throw UnfairError.io("invalid file size: \(source.path)")
        }
        let crc32 = try checksum(source)
        return StoredFileInfo(size: UInt64(fileSize), crc32: crc32)
    }

    private func withTemporaryExtractedFile(_ entry: Entry, from archive: Archive, body: (URL) throws -> Void) throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let temporaryFile = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try archive.extract(entry, to: temporaryFile)
        try body(temporaryFile)
    }

    private func sourceURL(for path: String, in root: URL) throws -> URL {
        let standardizedRoot = root.standardizedFileURL
        let source = standardizedRoot.appendingPathComponent(path).standardizedFileURL
        guard source.path == standardizedRoot.path || source.path.hasPrefix(standardizedRoot.path + "/") else {
            throw UnfairError.io("archive entry escapes source directory: \(path)")
        }
        return source
    }

    private func normalizedPath(_ path: String, type: Entry.EntryType) -> String {
        if type == .directory, path.hasSuffix("/") == false {
            return path + "/"
        }
        return path
    }

    private func defaultPermissions(for entry: Entry) -> UInt16 {
        entry.type == .directory ? defaultDirectoryPermissions : defaultFilePermissions
    }

    private func localFileHeader(pathBytes: [UInt8], fileInfo: StoredFileInfo, dateTime: ZipDateTime) throws -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(0x04034b50))
        data.appendLittleEndian(Self.zipVersionNeeded)
        data.appendLittleEndian(Self.zipUTF8Flag)
        data.appendLittleEndian(Self.zipStoreMethod)
        data.appendLittleEndian(dateTime.time)
        data.appendLittleEndian(dateTime.date)
        data.appendLittleEndian(fileInfo.crc32)
        data.appendLittleEndian(try zip32(fileInfo.size, label: "compressed size"))
        data.appendLittleEndian(try zip32(fileInfo.size, label: "uncompressed size"))
        data.appendLittleEndian(try zip16(pathBytes.count, label: "entry path length"))
        data.appendLittleEndian(UInt16(0))
        data.append(contentsOf: pathBytes)
        return data
    }

    private func centralDirectoryHeader(
        pathBytes: [UInt8],
        fileInfo: StoredFileInfo,
        dateTime: ZipDateTime,
        permissions: UInt16,
        type: Entry.EntryType,
        localHeaderOffset: UInt64
    ) throws -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(0x02014b50))
        data.appendLittleEndian(Self.zipVersionMadeBy)
        data.appendLittleEndian(Self.zipVersionNeeded)
        data.appendLittleEndian(Self.zipUTF8Flag)
        data.appendLittleEndian(Self.zipStoreMethod)
        data.appendLittleEndian(dateTime.time)
        data.appendLittleEndian(dateTime.date)
        data.appendLittleEndian(fileInfo.crc32)
        data.appendLittleEndian(try zip32(fileInfo.size, label: "compressed size"))
        data.appendLittleEndian(try zip32(fileInfo.size, label: "uncompressed size"))
        data.appendLittleEndian(try zip16(pathBytes.count, label: "entry path length"))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(externalFileAttributes(type: type, permissions: permissions))
        data.appendLittleEndian(try zip32(localHeaderOffset, label: "local header offset"))
        data.append(contentsOf: pathBytes)
        return data
    }

    private func endOfCentralDirectory(
        entryCount: UInt64,
        centralDirectorySize: UInt64,
        centralDirectoryOffset: UInt64
    ) throws -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(0x06054b50))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(try zip16(entryCount, label: "entry count"))
        data.appendLittleEndian(try zip16(entryCount, label: "entry count"))
        data.appendLittleEndian(try zip32(centralDirectorySize, label: "central directory size"))
        data.appendLittleEndian(try zip32(centralDirectoryOffset, label: "central directory offset"))
        data.appendLittleEndian(UInt16(0))
        return data
    }

    private func externalFileAttributes(type: Entry.EntryType, permissions: UInt16) -> UInt32 {
        let fileType = type == .directory ? UInt32(0o040000) : UInt32(0o100000)
        return (fileType | UInt32(permissions)) << 16
    }

    private func dosDateTime(_ date: Date) -> ZipDateTime {
        let components = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let year = min(max(components.year ?? 1980, 1980), 2107)
        let month = min(max(components.month ?? 1, 1), 12)
        let day = min(max(components.day ?? 1, 1), 31)
        let hour = min(max(components.hour ?? 0, 0), 23)
        let minute = min(max(components.minute ?? 0, 0), 59)
        let second = min(max(components.second ?? 0, 0), 59)

        let dosDate = UInt16((year - 1980) << 9 | month << 5 | day)
        let dosTime = UInt16(hour << 11 | minute << 5 | second / 2)
        return ZipDateTime(date: dosDate, time: dosTime)
    }

    private func checksum(_ source: URL) throws -> UInt32 {
        var crc32 = CRC32()
        _ = try readFile(source) { chunk in
            crc32.update(chunk)
        }
        return crc32.checksum
    }

    private func copyFile(_ source: URL, toFD destinationFD: Int32) throws {
        _ = try readFile(source) { chunk in
            try writeAll(chunk, to: destinationFD)
        }
    }

    @discardableResult
    private func readFile(_ source: URL, consume: (UnsafeRawBufferPointer) throws -> Void) throws -> UInt64 {
        let fd = open(source.path, O_RDONLY)
        guard fd >= 0 else {
            throw UnfairError.io("open archive source failed: \(source.path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        var total = UInt64(0)
        var buffer = [UInt8](repeating: 0, count: Self.fileBufferSize)
        try buffer.withUnsafeMutableBytes { rawBuffer in
            while true {
                let readCount = Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
                if readCount == 0 {
                    break
                }
                if readCount < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw UnfairError.io("read archive source failed: \(source.path): \(String(cString: strerror(errno)))")
                }
                total += UInt64(readCount)
                try consume(UnsafeRawBufferPointer(start: rawBuffer.baseAddress, count: readCount))
            }
        }
        return total
    }

    private func copyBytes(fromFD sourceFD: Int32, toFD destinationFD: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: Self.fileBufferSize)
        try buffer.withUnsafeMutableBytes { rawBuffer in
            while true {
                let readCount = Darwin.read(sourceFD, rawBuffer.baseAddress, rawBuffer.count)
                if readCount == 0 {
                    break
                }
                if readCount < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw UnfairError.io("read central directory temp failed: \(String(cString: strerror(errno)))")
                }
                try writeAll(UnsafeRawBufferPointer(start: rawBuffer.baseAddress, count: readCount), to: destinationFD)
            }
        }
    }

    private func writeData(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            try writeAll(rawBuffer, to: fd)
        }
    }

    private func writeAll(_ rawBuffer: UnsafeRawBufferPointer, to fd: Int32) throws {
        guard rawBuffer.count > 0 else {
            return
        }

        var pointer = rawBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
        var remaining = rawBuffer.count
        while remaining > 0 {
            let written = Darwin.write(fd, pointer, remaining)
            if written < 0 {
                if errno == EINTR {
                    continue
                }
                throw UnfairError.io("write archive failed: \(String(cString: strerror(errno)))")
            }
            guard written > 0 else {
                throw UnfairError.io("write archive failed: wrote zero bytes")
            }
            pointer = pointer.advanced(by: written)
            remaining -= written
        }
    }

    private func zip16(_ value: Int, label: String) throws -> UInt16 {
        try zip16(UInt64(value), label: label)
    }

    private func zip16(_ value: UInt64, label: String) throws -> UInt16 {
        guard value <= UInt64(UInt16.max) else {
            throw UnfairError.io("zip64 output unsupported for \(label): \(value)")
        }
        return UInt16(value)
    }

    private func zip32(_ value: UInt64, label: String) throws -> UInt32 {
        guard value <= UInt64(UInt32.max) else {
            throw UnfairError.io("zip64 output unsupported for \(label): \(value)")
        }
        return UInt32(value)
    }
}

private struct ZipWriteState {
    var localFileSize = UInt64(0)
    var centralDirectorySize = UInt64(0)
    var entryCount = UInt64(0)
}

private struct StoredFileInfo {
    var size: UInt64
    var crc32: UInt32
}

private struct ZipDateTime {
    var date: UInt16
    var time: UInt16
}

private struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { byte in
        var value = UInt32(byte)
        for _ in 0..<8 {
            if value & 1 == 1 {
                value = 0xedb88320 ^ (value >> 1)
            } else {
                value >>= 1
            }
        }
        return value
    }

    private var value = UInt32(0xffffffff)

    mutating func update(_ rawBuffer: UnsafeRawBufferPointer) {
        guard rawBuffer.count > 0, let baseAddress = rawBuffer.baseAddress else {
            return
        }

        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        for index in 0..<rawBuffer.count {
            let tableIndex = Int((value ^ UInt32(bytes[index])) & 0xff)
            value = Self.table[tableIndex] ^ (value >> 8)
        }
    }

    var checksum: UInt32 {
        value ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
