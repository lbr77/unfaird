@testable import UnfairKit
import XCTest

final class ArchivePrivacyFilterTests: XCTestCase {
    func testRemovesFairPlayUserInfoFromAppBundleRoot() {
        XCTAssertTrue(ArchivePrivacyFilter.shouldRemoveEntry(path: "Payload/CENFC.app/SC_Info"))
        XCTAssertTrue(ArchivePrivacyFilter.shouldRemoveEntry(path: "Payload/CENFC.app/SC_Info/"))
        XCTAssertTrue(ArchivePrivacyFilter.shouldRemoveEntry(path: "Payload/CENFC.app/SC_Info/CENFC.sinf"))
        XCTAssertTrue(ArchivePrivacyFilter.shouldRemoveEntry(path: "Payload/CENFC.app/SC_Info/CENFC.supf"))
    }

    func testRemovesFairPlayUserInfoFromNestedExtensions() {
        XCTAssertTrue(ArchivePrivacyFilter.shouldRemoveEntry(path: "Payload/CENFC.app/PlugIns/Widget.appex/SC_Info/"))
        XCTAssertTrue(ArchivePrivacyFilter.shouldRemoveEntry(path: "Payload/CENFC.app/PlugIns/Widget.appex/SC_Info/Widget.sinf"))
        XCTAssertTrue(ArchivePrivacyFilter.shouldRemoveEntry(path: "Payload/CENFC.app/Frameworks/Auth.framework/SC_Info/Auth.sinf"))
        XCTAssertTrue(ArchivePrivacyFilter.shouldRemoveEntry(path: "Payload/CENFC.app/Frameworks/Auth.framework/SC_Info/", isDirectory: true))
    }

    func testKeepsOtherPayloadEntries() {
        XCTAssertFalse(ArchivePrivacyFilter.shouldRemoveEntry(path: "Payload/CENFC.app/CENFC"))
        XCTAssertFalse(ArchivePrivacyFilter.shouldRemoveEntry(path: "Payload/CENFC.app/Info.plist"))
        XCTAssertFalse(ArchivePrivacyFilter.shouldRemoveEntry(path: "Payload/CENFC.app/Frameworks/SC_Info.framework/SC_Info"))
        XCTAssertFalse(ArchivePrivacyFilter.shouldRemoveEntry(path: "SC_Info/CENFC.sinf"))
    }
}
