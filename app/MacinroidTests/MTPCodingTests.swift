import XCTest
@testable import Macinroid

/// Checks the Swift encodings against what go-mtpfs, the library behind
/// OpenMTP's engine, writes for the same values. The bytes below come from
/// its `Encode` function.
final class MTPCodingTests: XCTestCase {
    private static let reference: [String: String] = [
        "objectInfo": "010001000030000040e2010000000000000000000000000000000000000000000000000000002a0000000000000000000000000015c9007400e90020003200300032003600200013202000700068006f0074006f002e006a007000670000000010320030003200360030003300300039005400310034003000350035003900000000",
        "folderInfo": "0100010001300000000000000000000000000000000000000000000000000000000000000000ffffffff00000000000000000000054400430049004d0000000010320030003200360030003300300039005400310034003000350035003900000000",
        "hugeFileInfo": "0100020000300000ffffffff000000000000000000000000000000000000000000000000000007000000000000000000000000000a6d006f007600690065002e006d006b007600000010320030003200360030003300300039005400310034003000350035003900000010320030003200360030003300300039005400310034003000350035003900000000",
        "storageInfo": "0300020000000000c99a3b000000001ba7b41a000000ffffff3f1849006e007400650072006e0061006c0020007300680061007200650064002000730074006f007200610067006500000000",
        "deviceInfo": "6400060000006400266d006900630072006f0073006f00660074002e0063006f006d003a00200031002e0030003b00200061006e00640072006f00690064002e0063006f006d003a00200031002e0030003b0000000000030000000110021003980100000002400100000001d40000000002000000003001300747006f006f0067006c00650000000c50006900780065006c00200039002000500072006f00000003310036000000074100420043003100320033000000",
        "storageIDs": "020000000100010001000200",
        "fileName": "0a6e006f007400650073002e007400780074000000",
        "emptyString": "00",
        "objectSize": "0000004001000000",
    ]

    /// The moment used in the reference data: 9 March 2026, 14:05:59, local time.
    private static let when = Date(timeIntervalSince1970: 1773065159)

    private func reference(_ name: String) throws -> Data {
        let hex = try XCTUnwrap(Self.reference[name])
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(try XCTUnwrap(UInt8(hex[index..<next], radix: 16)))
            index = next
        }
        return data
    }

    func testObjectInfoOfAFile() throws {
        let data = try reference("objectInfo")
        let info = try MTPObjectInfo(decoding: data)

        XCTAssertEqual(info.storageID, 0x0001_0001)
        XCTAssertEqual(info.objectFormat, MTPObjectFormat.undefined)
        XCTAssertEqual(info.compressedSize, 123_456)
        XCTAssertEqual(info.parentObject, 0x2A)
        XCTAssertEqual(info.filename, "Été 2026 – photo.jpg")
        XCTAssertEqual(info.modificationDate, Self.when)
        XCTAssertNil(info.captureDate)
        XCTAssertFalse(info.isFolder)

        // and the other way round, byte for byte
        XCTAssertEqual(try info.encoded(), data)
    }

    func testObjectInfoOfAFolder() throws {
        let data = try reference("folderInfo")
        let info = try MTPObjectInfo(decoding: data)

        XCTAssertTrue(info.isFolder)
        XCTAssertEqual(info.parentObject, MTPHandle.root)
        XCTAssertEqual(info.filename, "DCIM")
        XCTAssertEqual(try info.encoded(), data)
    }

    func testObjectInfoOfAFileTooLargeForTheSizeField() throws {
        let data = try reference("hugeFileInfo")
        let info = try MTPObjectInfo(decoding: data)

        XCTAssertEqual(info.compressedSize, MTPObjectInfo.sizeUnknown)
        XCTAssertEqual(info.captureDate, Self.when)
        XCTAssertEqual(try info.encoded(), data)
    }

    func testStorageInfo() throws {
        let info = try MTPStorageInfo(decoding: reference("storageInfo"))

        XCTAssertEqual(info.storageType, 3)
        XCTAssertEqual(info.filesystemType, 2)
        XCTAssertEqual(info.maxCapacity, 255_999_934_464)
        XCTAssertEqual(info.freeSpaceInBytes, 114_700_000_000)
        XCTAssertEqual(info.storageDescription, "Internal shared storage")
        XCTAssertEqual(info.volumeLabel, "")
        XCTAssertFalse(info.isRemovable)
    }

    func testDeviceInfo() throws {
        let info = try MTPDeviceInfo(decoding: reference("deviceInfo"))

        XCTAssertEqual(info.standardVersion, 100)
        XCTAssertEqual(info.vendorExtensionID, 6)
        XCTAssertEqual(info.mtpExtension, "microsoft.com: 1.0; android.com: 1.0;")
        XCTAssertEqual(info.operationsSupported, [0x1001, 0x1002, 0x9803])
        XCTAssertEqual(info.eventsSupported, [0x4002])
        XCTAssertEqual(info.captureFormats, [])
        XCTAssertEqual(info.playbackFormats, [0x3000, 0x3001])
        XCTAssertEqual(info.manufacturer, "Google")
        XCTAssertEqual(info.model, "Pixel 9 Pro")
        XCTAssertEqual(info.deviceVersion, "16")
        XCTAssertEqual(info.serialNumber, "ABC123")
    }

    func testArraysStringsAndNumbers() throws {
        var ids = MTPReader(try reference("storageIDs"))
        XCTAssertEqual(try ids.array32(), [0x0001_0001, 0x0002_0001])

        var name = MTPReader(try reference("fileName"))
        XCTAssertEqual(try name.string(), "notes.txt")
        var writer = MTPWriter()
        try writer.string("notes.txt")
        XCTAssertEqual(writer.data, try reference("fileName"))

        var empty = MTPWriter()
        try empty.string("")
        XCTAssertEqual(empty.data, try reference("emptyString"))

        var size = MTPReader(try reference("objectSize"))
        XCTAssertEqual(try size.u64(), 5_368_709_120)
    }

    func testStringsBeyondTheBasicPlaneSurviveARoundTrip() throws {
        // go-mtpfs cuts such characters down to 16 bits; UTF-16 pairs are what the standard asks for
        var writer = MTPWriter()
        try writer.string("Party 🎉.mp4")
        var reader = MTPReader(writer.data)
        XCTAssertEqual(try reader.string(), "Party 🎉.mp4")
    }

    func testStringsThatAreTooLongAreRefused() {
        var writer = MTPWriter()
        XCTAssertThrowsError(try writer.string(String(repeating: "a", count: 255))) {
            XCTAssertEqual($0 as? MTPCodingError, .stringTooLong)
        }
        XCTAssertNoThrow(try writer.string(String(repeating: "a", count: 254)))
    }

    func testTruncatedDataIsAnErrorNotACrash() {
        var reader = MTPReader(Data([0x05, 0x41, 0x00]))
        XCTAssertThrowsError(try reader.string())

        var numbers = MTPReader(Data([0x01, 0x02]))
        XCTAssertThrowsError(try numbers.u32())

        var array = MTPReader(Data([0xFF, 0xFF, 0xFF, 0x7F, 0x00]))
        XCTAssertThrowsError(try array.array32())

        XCTAssertThrowsError(try MTPObjectInfo(decoding: Data([1, 2, 3])))
    }

    func testDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let local = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 12, day: 31, hour: 23, minute: 59, second: 58)))

        XCTAssertEqual(MTPDate.parse("20241231T235958"), local)
        XCTAssertEqual(MTPDate.format(local), "20241231T235958")
        // Samsung adds dots, some cameras tenths of a second
        XCTAssertEqual(MTPDate.parse("20241231T235958..."), local)
        XCTAssertEqual(MTPDate.parse("20241231T235958.0"), local)

        calendar.timeZone = .gmt
        let utc = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 12, day: 31, hour: 23, minute: 59, second: 58)))
        XCTAssertEqual(MTPDate.parse("20241231T235958Z"), utc)
        XCTAssertEqual(MTPDate.parse("20250101T015958+0200"), utc)
        XCTAssertEqual(MTPDate.parse("20241231T185958-0500"), utc)

        XCTAssertNil(MTPDate.parse(""))
        XCTAssertNil(MTPDate.parse("yesterday"))
    }
}
