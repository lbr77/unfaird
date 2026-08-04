import MachO
@testable import UnfairKit
import XCTest

final class MachOInspectorTests: XCTestCase {
    func testFindCodeSignatureInfoReadsLinkeditDataCommand() throws {
        var data = Data()
        var header = mach_header_64(
            magic: UInt32(MH_MAGIC_64),
            cputype: cpu_type_t(CPU_TYPE_ARM64),
            cpusubtype: cpu_subtype_t(CPU_SUBTYPE_ARM64_ALL),
            filetype: UInt32(MH_EXECUTE),
            ncmds: 1,
            sizeofcmds: UInt32(MemoryLayout<linkedit_data_command>.size),
            flags: 0,
            reserved: 0
        )
        var command = linkedit_data_command(
            cmd: UInt32(LC_CODE_SIGNATURE),
            cmdsize: UInt32(MemoryLayout<linkedit_data_command>.size),
            dataoff: 0x100,
            datasize: 0x40
        )

        data.appendBytes(of: &header)
        data.appendBytes(of: &command)
        data.append(Data(repeating: 0, count: 0x140 - data.count))

        let signature = try data.withUnsafeBytes { rawBuffer in
            try XCTUnwrap(rawBuffer.baseAddress).withMemoryRebound(to: UInt8.self, capacity: rawBuffer.count) { base in
                try MachOInspector.findCodeSignatureInfo(base: UnsafeRawPointer(base), size: rawBuffer.count)
            }
        }

        XCTAssertEqual(signature?.dataoff, 0x100)
        XCTAssertEqual(signature?.datasize, 0x40)
    }
}

private extension Data {
    mutating func appendBytes<T>(of value: inout T) {
        Swift.withUnsafeBytes(of: &value) { bytes in
            append(contentsOf: bytes)
        }
    }
}
