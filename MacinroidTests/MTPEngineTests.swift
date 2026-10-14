import XCTest
@testable import Macinroid

/// Runs the Swift MTP engine against a simulated device that speaks the wire protocol.
final class MTPEngineTests: XCTestCase {
    private var scratch: URL!
    private var macFolder: URL!
    private var device: FakeMTPDevice!
    private var backend: MTPBackend!

    private var storage: UInt32 { device.internalStorage }

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MTPEngineTests-\(UUID().uuidString)")
        macFolder = scratch.appendingPathComponent("Mac")
        try FileManager.default.createDirectory(at: macFolder, withIntermediateDirectories: true)
        makeDevice()
    }

    override func tearDown() async throws {
        await backend.disconnect()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeDevice(packetSize: Int = 512) {
        let device = FakeMTPDevice(root: scratch.appendingPathComponent("Phone-\(UUID().uuidString)"), packetSize: packetSize)
        self.device = device
        backend = MTPBackend(connector: { device })
    }

    // MARK: Helpers

    /// Bytes that differ from place to place, so that misplaced data shows.
    private func bytes(_ count: Int, seed: UInt8 = 1) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for index in buffer.indices { buffer[index] = UInt8(truncatingIfNeeded: index &* 31 &+ Int(seed) &+ index / 251) }
        }
        return data
    }

    @discardableResult
    private func phoneFile(_ path: String, _ contents: Data = Data([1, 2, 3])) throws -> URL {
        let url = device.internalRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        device.rescan()
        return url
    }

    @discardableResult
    private func macFile(_ path: String, _ contents: Data = Data([1, 2, 3])) throws -> String {
        let url = macFolder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        return url.path
    }

    private func onPhone(_ path: String) -> URL {
        device.internalRoot.appendingPathComponent(path)
    }

    /// Runs a transfer to its end and returns what it reported on the way.
    /// With `cancelAfter`, it is cancelled once that many bytes of one object
    /// have crossed the wire; with `unplugAfter`, the cable is pulled then.
    @discardableResult
    private func transfer(
        _ direction: TransferDirection, _ sources: [String], to destination: String, countFirst: Bool = true,
        cancelAfter: Int? = nil, unplugAfter: Int? = nil
    ) async throws -> [TransferEvent] {
        let request = TransferRequest(direction: direction, storageID: storage, sources: sources, destination: destination, countFirst: countFirst)
        device.onDataTransferred = { [backend, device] bytes in
            if let cancelAfter, bytes > cancelAfter { backend?.cancelTransfer(id: request.id) }
            if let unplugAfter, bytes > unplugAfter { device?.unplug() }
        }
        defer { device.onDataTransferred = nil }

        var events: [TransferEvent] = []
        for try await event in backend.transfer(request) {
            events.append(event)
        }
        return events
    }

    private func lastProgress(_ events: [TransferEvent]) -> TransferProgress? {
        events.reversed().lazy.compactMap { if case .progress(let progress) = $0 { progress } else { nil } }.first
    }

    private func assertFails<T>(_ code: DeviceError.Code, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T) async {
        do {
            _ = try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as DeviceError {
            XCTAssertEqual(error.code, code, error.detail, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: Connecting

    func testConnectingReportsTheDeviceAndItsStorages() async throws {
        let info = try await backend.connect()
        XCTAssertEqual(info.displayName, "Fake Phone")
        XCTAssertEqual(info.manufacturer, "Google")
        XCTAssertEqual(info.serialNumber, "FAKE0001")
        XCTAssertEqual(info.usb.vendorId, 0x18D1)

        let storages = try await backend.storages()
        XCTAssertEqual(storages.map(\.displayName), ["Internal shared storage", "SD card"])
        XCTAssertEqual(storages[0].capacity, 256_000_000_000)
        XCTAssertEqual(storages[0].freeSpace, 114_700_000_000)
        XCTAssertFalse(storages[0].isRemovable)
        XCTAssertTrue(storages[1].isRemovable)
    }

    func testASessionLeftOpenIsTakenOver() async throws {
        _ = try await backend.connect()
        // a second connection finds the session of the first still open on the device
        let again = MTPBackend(connector: { [device] in device! })
        _ = try await again.connect()
        let storages = try await again.storages()
        XCTAssertEqual(storages.count, 2)
    }

    func testADeviceThatWillNotOpenASessionIsResetOnce() async throws {
        device.failures[MTPOperation.openSession.rawValue] = MTPResponseCode(rawValue: 0x2002)
        _ = try await backend.connect()
        XCTAssertTrue(device.wasReset)
        _ = try await backend.storages()
    }

    func testRequestsWithoutAConnectionFail() async {
        await assertFails(.mtpDetectFailed) { try await backend.storages() }
        await assertFails(.mtpDetectFailed) { try await backend.list(storage: storage, path: "/", includeHidden: false) }
    }

    func testNoDeviceAndSeveralDevices() async {
        backend = MTPBackend(connector: { throw MTPError.noDevice })
        await assertFails(.mtpDetectFailed) { try await backend.connect() }

        backend = MTPBackend(connector: { throw MTPError.multipleDevices(["A", "B"]) })
        await assertFails(.multipleDevice) { try await backend.connect() }

        backend = MTPBackend(connector: { throw MTPTransportError(kind: .inUse, detail: "another program is using the device") })
        await assertFails(.deviceSetup) { try await backend.connect() }
    }

    func testAPhoneThatHasNotAllowedAccessYet() async throws {
        _ = try await backend.connect()
        device.storagesAnswer = .none
        await assertFails(.noStorage) { try await backend.storages() }

        device.storagesAnswer = .truncated
        await assertFails(.allowStorageAccess) { try await backend.storages() }
        // such a session is closed, so that the next attempt starts afresh
        await assertFails(.mtpDetectFailed) { try await backend.storages() }
    }

    func testUnpluggingEndsTheSession() async throws {
        _ = try await backend.connect()
        device.unplug()

        do {
            _ = try await backend.list(storage: storage, path: "/", includeHidden: false)
            XCTFail("listing should fail")
        } catch let error as DeviceError {
            XCTAssertTrue(error.endsSession, "\(error)")
        }
        await assertFails(.mtpDetectFailed) { try await backend.storages() }
    }

    // MARK: Browsing

    func testListing() async throws {
        try phoneFile("DCIM/Camera/IMG_1.jpg", bytes(1234))
        try phoneFile("DCIM/Camera/.thumbnail", bytes(10))
        try phoneFile("notes.txt", bytes(5))
        _ = try await backend.connect()

        let top = try await backend.list(storage: storage, path: "/", includeHidden: false)
        XCTAssertEqual(Set(top.map(\.name)), ["DCIM", "notes.txt"])
        let folder = try XCTUnwrap(top.first { $0.name == "DCIM" })
        XCTAssertTrue(folder.isFolder)
        XCTAssertEqual(folder.path, "/DCIM")
        let file = try XCTUnwrap(top.first { $0.name == "notes.txt" })
        XCTAssertEqual(file.size, 5)
        XCTAssertNotNil(file.modified)

        let camera = try await backend.list(storage: storage, path: "/DCIM/Camera", includeHidden: false)
        XCTAssertEqual(camera.map(\.name), ["IMG_1.jpg"])
        XCTAssertEqual(camera[0].path, "/DCIM/Camera/IMG_1.jpg")
        XCTAssertEqual(camera[0].size, 1234)

        let withHidden = try await backend.list(storage: storage, path: "/dcim/camera", includeHidden: true)
        XCTAssertEqual(Set(withHidden.map(\.name)), ["IMG_1.jpg", ".thumbnail"], "paths are found without regard to case")

        await assertFails(.invalidPath) { try await backend.list(storage: storage, path: "/Nowhere", includeHidden: false) }
        let sdCard = try await backend.list(storage: 0x0002_0001, path: "/", includeHidden: false)
        XCTAssertTrue(sdCard.isEmpty)
    }

    // MARK: Looking inside files

    func testListingsSayWhichFilesHaveThumbnails() async throws {
        try phoneFile("DCIM/a.jpg")
        try phoneFile("DCIM/b.txt")
        _ = try await backend.connect()

        let items = try await backend.list(storage: storage, path: "/DCIM", includeHidden: false)
        XCTAssertEqual(items.first { $0.name == "a.jpg" }?.hasThumbnail, true)
        XCTAssertEqual(items.first { $0.name == "b.txt" }?.hasThumbnail, false)
    }

    func testTheThumbnailOfAFileJustListedTakesOneRequest() async throws {
        try phoneFile("DCIM/Camera/a.jpg")
        try phoneFile("DCIM/Camera/b.txt")
        _ = try await backend.connect()
        _ = try await backend.list(storage: storage, path: "/DCIM/Camera", includeHidden: false)

        let before = device.operations.count
        let thumbnail = try await backend.thumbnail(storage: storage, path: "/DCIM/Camera/a.jpg")
        XCTAssertEqual(thumbnail, FakeMTPDevice.thumbnail(of: "a.jpg"))
        XCTAssertEqual(Array(device.operations.dropFirst(before)), [MTPOperation.getThumb.rawValue])

        // a file without one has none, and the session carries on
        let none = try await backend.thumbnail(storage: storage, path: "/DCIM/Camera/b.txt")
        XCTAssertNil(none)
        let items = try await backend.list(storage: storage, path: "/DCIM/Camera", includeHidden: false)
        XCTAssertEqual(items.count, 2)
    }

    func testReadingPartOfAFile() async throws {
        let contents = bytes(10_000)
        try phoneFile("Download/data.bin", contents)
        _ = try await backend.connect()

        let middle = try await backend.read(storage: storage, path: "/Download/data.bin", offset: 1000, length: 3000)
        XCTAssertEqual(middle, contents.subdata(in: 1000..<4000))
        let end = try await backend.read(storage: storage, path: "/Download/data.bin", offset: 9000, length: 5000)
        XCTAssertEqual(end, contents.subdata(in: 9000..<10_000))
        XCTAssertEqual(device.operations.last, MTPOperation.getPartialObject.rawValue)
    }

    func testReadingBeyondFourGigabytes() async throws {
        // a sparse file of 5 GB, which takes up next to no room
        let url = onPhone("Movies/long.mp4")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: 5 << 30)
        try writer.seek(toOffset: (4 << 30) + 100)
        try writer.write(contentsOf: Data([1, 2, 3, 4]))
        try writer.close()
        device.rescan()
        _ = try await backend.connect()

        let data = try await backend.read(storage: storage, path: "/Movies/long.mp4", offset: (4 << 30) + 100, length: 4)
        XCTAssertEqual(data, Data([1, 2, 3, 4]))
        XCTAssertEqual(device.operations.last, MTPOperation.getPartialObject64.rawValue)
    }

    func testSizesThatDoNotFitTheSizeFieldComeFromTheProperty() async throws {
        try phoneFile("movie.mkv", bytes(70_000))
        device.hidesSizes = true
        _ = try await backend.connect()

        let items = try await backend.list(storage: storage, path: "/", includeHidden: false)
        XCTAssertEqual(items.first?.size, 70_000)
    }

    func testChangesMadeOnThePhoneAreSeen() async throws {
        try phoneFile("a.txt")
        _ = try await backend.connect()
        _ = try await backend.list(storage: storage, path: "/", includeHidden: false)

        // the phone's owner takes a photo and deletes a file meanwhile
        try FileManager.default.removeItem(at: onPhone("a.txt"))
        try phoneFile("Photos/new.jpg")

        let exists = try await backend.exists(storage: storage, paths: ["/a.txt", "/Photos/new.jpg", "/Photos"])
        XCTAssertEqual(exists, [false, true, true])
        let photos = try await backend.list(storage: storage, path: "/Photos", includeHidden: false)
        XCTAssertEqual(photos.map(\.name), ["new.jpg"])
    }

    // MARK: Folders, renaming, deleting

    func testMakingFolders() async throws {
        try phoneFile("Music/song.mp3")
        _ = try await backend.connect()

        try await backend.makeDirectory(storage: storage, path: "/Music/Albums/2026")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: onPhone("Music/Albums/2026").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        // making what is there already changes nothing
        try await backend.makeDirectory(storage: storage, path: "/Music/Albums")
        // a file is in the way
        await assertFails(.invalidPath) { try await backend.makeDirectory(storage: storage, path: "/Music/song.mp3/sub") }
    }

    func testRenaming() async throws {
        try phoneFile("Docs/old name.txt", bytes(40))
        try phoneFile("Docs/Folder/inner.txt")
        _ = try await backend.connect()

        try await backend.rename(storage: storage, path: "/Docs/old name.txt", newName: "new name.txt")
        try await backend.rename(storage: storage, path: "/Docs/Folder", newName: "Renamed")

        let docs = try await backend.list(storage: storage, path: "/Docs", includeHidden: false)
        XCTAssertEqual(Set(docs.map(\.name)), ["new name.txt", "Renamed"])
        let inner = try await backend.list(storage: storage, path: "/Docs/Renamed", includeHidden: false)
        XCTAssertEqual(inner.map(\.name), ["inner.txt"])

        await assertFails(.invalidPath) { try await backend.rename(storage: storage, path: "/Docs/missing.txt", newName: "x") }
    }

    func testDeleting() async throws {
        try phoneFile("Trash/a.txt")
        try phoneFile("Trash/Sub/b.txt")
        try phoneFile("keep.txt")
        _ = try await backend.connect()

        try await backend.delete(storage: storage, paths: ["/Trash", "/not there"])

        XCTAssertFalse(FileManager.default.fileExists(atPath: onPhone("Trash").path))
        let top = try await backend.list(storage: storage, path: "/", includeHidden: false)
        XCTAssertEqual(top.map(\.name), ["keep.txt"])
    }

    // MARK: Transfers

    /// Sizes around every boundary of the framing: the room next to the
    /// header in the first packet, whole packets, and whole chunks.
    private static let trickySizes = [0, 1, 499, 500, 501, 511, 512, 513, 1012, 1024, 4096, 65_536, (256 << 10) - 12, 256 << 10, (256 << 10) + 500, (512 << 10) + 500, 700_001]

    func testUploadsArriveIntactAtEverySize() async throws {
        for packetSize in [512, 1024] {
            makeDevice(packetSize: packetSize)
            _ = try await backend.connect()

            var sources: [String] = []
            for size in Self.trickySizes {
                sources.append(try macFile("up/\(size).bin", bytes(size, seed: UInt8(truncatingIfNeeded: size))))
            }
            let events = try await transfer(.upload, sources, to: "/Incoming")

            for size in Self.trickySizes {
                XCTAssertEqual(
                    try Data(contentsOf: onPhone("Incoming/\(size).bin")), bytes(size, seed: UInt8(truncatingIfNeeded: size)),
                    "\(size) bytes with \(packetSize)-byte packets"
                )
            }
            let progress = try XCTUnwrap(lastProgress(events))
            XCTAssertTrue(progress.isCompleted)
            XCTAssertEqual(progress.filesDone, Self.trickySizes.count)
            XCTAssertEqual(progress.bytesDone, Int64(Self.trickySizes.reduce(0, +)))
            XCTAssertEqual(progress.bytesTotal, progress.bytesDone)
            await backend.disconnect()
        }
    }

    func testDownloadsArriveIntactAtEverySize() async throws {
        for (packetSize, separateHeader, hidesLength) in [(512, false, false), (1024, false, false), (512, true, false), (512, false, true)] {
            makeDevice(packetSize: packetSize)
            device.sendsSeparateHeader = separateHeader
            device.hidesDataLength = hidesLength
            for size in Self.trickySizes {
                try phoneFile("Outgoing/\(size).bin", bytes(size, seed: UInt8(truncatingIfNeeded: size)))
            }
            _ = try await backend.connect()

            let destination = macFolder.appendingPathComponent("down-\(packetSize)-\(separateHeader)-\(hidesLength)")
            let events = try await transfer(.download, ["/Outgoing"], to: destination.path)

            for size in Self.trickySizes {
                XCTAssertEqual(
                    try Data(contentsOf: destination.appendingPathComponent("Outgoing/\(size).bin")), bytes(size, seed: UInt8(truncatingIfNeeded: size)),
                    "\(size) bytes, packets of \(packetSize), separate header \(separateHeader), hidden length \(hidesLength)"
                )
            }
            let progress = try XCTUnwrap(lastProgress(events))
            XCTAssertEqual(progress.filesDone, Self.trickySizes.count)
            XCTAssertEqual(progress.bytesDone, Int64(Self.trickySizes.reduce(0, +)))
            await backend.disconnect()
        }
    }

    func testADeviceThatSplitsHeadersGetsThemSplit() async throws {
        device.sendsSeparateHeader = true
        try phoneFile("a.bin", bytes(3000))
        _ = try await backend.connect()
        try await transfer(.download, ["/a.bin"], to: macFolder.path)
        XCTAssertFalse(device.sawSeparateHeaderFromHost)

        // from then on the host does as the device does
        let source = try macFile("b.bin", bytes(3000, seed: 9))
        try await transfer(.upload, [source], to: "/")
        XCTAssertTrue(device.sawSeparateHeaderFromHost)
        XCTAssertEqual(try Data(contentsOf: onPhone("b.bin")), bytes(3000, seed: 9))
    }

    func testUploadingATree() async throws {
        try phoneFile("Dest/Album/old.jpg", bytes(10))
        try phoneFile("Dest/Album/one.jpg", bytes(10))
        let album = macFolder.appendingPathComponent("Album").path
        try macFile("Album/one.jpg", bytes(3000, seed: 1))
        try macFile("Album/nested/deeper/two.jpg", bytes(2000, seed: 2))
        try macFile("Album/.DS_Store", bytes(10))
        try macFile("Album/empty/.keep", bytes(0))
        let single = try macFile("song.mp3", bytes(5000, seed: 3))
        _ = try await backend.connect()

        let events = try await transfer(.upload, [album, single], to: "/Dest")

        // merged into the folder that was there; the file of the same name replaced
        XCTAssertEqual(try Data(contentsOf: onPhone("Dest/Album/one.jpg")), bytes(3000, seed: 1))
        XCTAssertEqual(try Data(contentsOf: onPhone("Dest/Album/old.jpg")), bytes(10))
        XCTAssertEqual(try Data(contentsOf: onPhone("Dest/Album/nested/deeper/two.jpg")), bytes(2000, seed: 2))
        XCTAssertEqual(try Data(contentsOf: onPhone("Dest/song.mp3")), bytes(5000, seed: 3))
        XCTAssertTrue(FileManager.default.fileExists(atPath: onPhone("Dest/Album/empty/.keep").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: onPhone("Dest/Album/.DS_Store").path))

        // counted first, then copied against that total
        guard case .counting(let files, let total, _) = try XCTUnwrap(events.last(where: { if case .counting = $0 { true } else { false } })) else {
            return XCTFail("no count")
        }
        XCTAssertEqual(files, 4)
        XCTAssertEqual(total, 10_000)
        let progress = try XCTUnwrap(lastProgress(events))
        XCTAssertEqual(progress.filesTotal, 4)
        XCTAssertEqual(progress.filesDone, 4)
        XCTAssertEqual(progress.bytesDone, 10_000)
    }

    func testUploadedFilesKeepTheirDates() async throws {
        let source = try macFile("dated.txt", bytes(100))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source)
        _ = try await backend.connect()

        try await transfer(.upload, [source], to: "/")
        let items = try await backend.list(storage: storage, path: "/", includeHidden: false)
        XCTAssertEqual(items.first?.modified, date)

        // and back again
        let destination = macFolder.appendingPathComponent("back")
        try await transfer(.download, ["/dated.txt"], to: destination.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("dated.txt").path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, date)
    }

    func testDownloadingATreeWithoutCountingFirst() async throws {
        try phoneFile("DCIM/Camera/a.jpg", bytes(4000, seed: 4))
        try phoneFile("DCIM/Camera/2026/b.jpg", bytes(1500, seed: 5))
        try phoneFile("DCIM/.DS_Store", bytes(3))
        try phoneFile("notes.txt", bytes(77, seed: 6))
        _ = try await backend.connect()

        let events = try await transfer(.download, ["/DCIM", "/notes.txt"], to: macFolder.path, countFirst: false)

        XCTAssertEqual(try Data(contentsOf: macFolder.appendingPathComponent("DCIM/Camera/a.jpg")), bytes(4000, seed: 4))
        XCTAssertEqual(try Data(contentsOf: macFolder.appendingPathComponent("DCIM/Camera/2026/b.jpg")), bytes(1500, seed: 5))
        XCTAssertEqual(try Data(contentsOf: macFolder.appendingPathComponent("notes.txt")), bytes(77, seed: 6))
        XCTAssertFalse(FileManager.default.fileExists(atPath: macFolder.appendingPathComponent("DCIM/.DS_Store").path))

        XCTAssertFalse(events.contains { if case .counting = $0 { true } else { false } })
        let progress = try XCTUnwrap(lastProgress(events))
        XCTAssertEqual(progress.filesTotal, 0)
        XCTAssertEqual(progress.filesDone, 3)
        XCTAssertEqual(progress.bytesDone, 5577)
    }

    func testTransfersOfThingsThatAreNotThereFail() async throws {
        _ = try await backend.connect()
        await assertFails(.invalidPath) { try await transfer(.download, ["/missing.bin"], to: macFolder.path) }
        await assertFails(.invalidPath) { try await transfer(.upload, [macFolder.appendingPathComponent("missing").path], to: "/") }
        // the session is none the worse for it
        _ = try await backend.storages()
    }

    // MARK: Stopping and failing

    func testCancellingAnUploadKeepsTheSessionAndLeavesNoHalfFile() async throws {
        let first = try macFile("1 first.bin", bytes(20_000))
        let big = try macFile("2 big.bin", bytes(3 << 20))
        let never = try macFile("3 never.bin", bytes(1000))
        _ = try await backend.connect()

        do {
            try await transfer(.upload, [first, big, never], to: "/", cancelAfter: 600_000)
            XCTFail("the transfer should have been cancelled")
        } catch let error as DeviceError {
            XCTAssertTrue(error.isCancellation)
            XCTAssertFalse(error.sessionReset, "the device was told to stop and came back in step")
        }

        XCTAssertEqual(device.cancelRequests, 1)
        let items = try await backend.list(storage: storage, path: "/", includeHidden: false)
        XCTAssertEqual(items.map(\.name), ["1 first.bin"])
    }

    func testCancellingADownloadKeepsTheSessionAndRemovesTheHalfFile() async throws {
        try phoneFile("small.bin", bytes(20_000))
        try phoneFile("z big.bin", bytes(3 << 20))
        _ = try await backend.connect()

        do {
            try await transfer(.download, ["/small.bin", "/z big.bin"], to: macFolder.path, cancelAfter: 600_000)
            XCTFail("the transfer should have been cancelled")
        } catch let error as DeviceError {
            XCTAssertTrue(error.isCancellation)
            XCTAssertFalse(error.sessionReset)
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: macFolder.path), ["small.bin"])
        _ = try await backend.storages()
    }

    func testCancellingWhileCountingNeedsNoRecovery() async throws {
        for index in 0..<120 { try macFile("many/\(index).txt", bytes(10)) }
        _ = try await backend.connect()

        let request = TransferRequest(direction: .upload, storageID: storage, sources: [macFolder.appendingPathComponent("many").path], destination: "/", countFirst: true)
        backend.cancelTransfer(id: request.id)
        do {
            for try await _ in backend.transfer(request) {}
            XCTFail("the transfer should have been cancelled")
        } catch let error as DeviceError {
            XCTAssertTrue(error.isCancellation)
            XCTAssertFalse(error.sessionReset)
        }
        XCTAssertEqual(device.cancelRequests, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: onPhone("many").path))
    }

    func testADeviceThatStaysConfusedAfterACancelIsDisconnected() async throws {
        let big = try macFile("big.bin", bytes(3 << 20))
        device.staysConfusedAfterCancel = true
        _ = try await backend.connect()

        do {
            try await transfer(.upload, [big], to: "/", cancelAfter: 600_000)
            XCTFail("the transfer should have been cancelled")
        } catch let error as DeviceError {
            XCTAssertTrue(error.isCancellation)
            XCTAssertTrue(error.sessionReset, "the app has to connect again")
        }
        await assertFails(.mtpDetectFailed) { try await backend.storages() }
    }

    func testAFullStorageIsReportedAndTheSessionGoesOn() async throws {
        let big = try macFile("big.bin", bytes(300_000))
        device.storeFullAfter = 100_000
        _ = try await backend.connect()

        await assertFails(.storageFull) { try await transfer(.upload, [big], to: "/") }

        device.storeFullAfter = nil
        let items = try await backend.list(storage: storage, path: "/", includeHidden: false)
        XCTAssertTrue(items.isEmpty)
        try await transfer(.upload, [big], to: "/")
        XCTAssertEqual(try Data(contentsOf: onPhone("big.bin")), bytes(300_000))
    }

    func testUnpluggingDuringATransferEndsTheSession() async throws {
        try phoneFile("big.bin", bytes(3 << 20))
        _ = try await backend.connect()

        do {
            try await transfer(.download, ["/big.bin"], to: macFolder.path, countFirst: false, unplugAfter: 600_000)
            XCTFail("the transfer should have failed")
        } catch let error as DeviceError {
            XCTAssertTrue(error.endsSession, "\(error)")
            XCTAssertFalse(error.isCancellation)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: macFolder.appendingPathComponent("big.bin").path), "no half file is left")
    }

    func testAnErrorFromTheDeviceDoesNotEndTheSession() async throws {
        try phoneFile("a.txt")
        _ = try await backend.connect()

        device.failures[MTPOperation.getObjectHandles.rawValue] = MTPResponseCode(rawValue: 0x2002)
        await assertFails(.listDirectory) { try await backend.list(storage: storage, path: "/", includeHidden: false) }

        let items = try await backend.list(storage: storage, path: "/", includeHidden: false)
        XCTAssertEqual(items.map(\.name), ["a.txt"])
    }

    // MARK: Efficiency

    /// The Go engine asks for the name of every object in a folder again for
    /// each file it uploads there. Once per transfer is enough.
    func testUploadingManyFilesReadsTheFolderOnce() async throws {
        for index in 0..<40 { try phoneFile("Busy/existing \(index).txt") }
        var sources: [String] = []
        for index in 0..<30 { sources.append(try macFile("new \(index).txt", bytes(100))) }
        _ = try await backend.connect()

        try await transfer(.upload, sources, to: "/Busy")

        let nameRequests = device.operations.filter { $0 == MTPOperation.getObjectPropValue.rawValue }.count
        XCTAssertLessThan(nameRequests, 100, "the 40 names of the folder, plus those on the way to it")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: onPhone("Busy").path).count, 70)
    }

    // MARK: The whole app on top of it

    @MainActor
    func testTheAppWorksOnTheSwiftEngine() async throws {
        try phoneFile("DCIM/photo.jpg", bytes(50_000, seed: 7))
        let app = AppModel(settings: AppSettings(defaults: UserDefaults(suiteName: "MTPEngineTests-\(UUID().uuidString)")!), backend: backend)
        app.pasteboard = NSPasteboard.withUniqueName()
        defer { app.pasteboard.releaseGlobally() }
        app.alertHandler = { _, _, _ in 0 }

        let connected = await app.session.connect()
        XCTAssertTrue(connected)
        XCTAssertEqual(app.session.deviceName, "Fake Phone")
        XCTAssertEqual(app.phone.items.map(\.name), ["DCIM"])
        XCTAssertEqual(app.phoneShortcuts, ["DCIM"])

        // download through the app
        await app.phone.navigate(to: "/DCIM")
        app.phone.selectAll()
        app.settings.downloadFolder = macFolder.path
        app.downloadSelection()
        await app.transfers.waitUntilIdle()
        XCTAssertEqual(try Data(contentsOf: macFolder.appendingPathComponent("photo.jpg")), bytes(50_000, seed: 7))

        // upload through the app, new folder, rename, delete
        let source = try macFile("report.pdf", bytes(9000, seed: 8))
        app.upload(filesFromOutside: [source])
        try await Task.sleep(for: .milliseconds(50))
        await app.transfers.waitUntilIdle()
        XCTAssertEqual(try Data(contentsOf: onPhone("DCIM/report.pdf")), bytes(9000, seed: 8))
        XCTAssertEqual(app.phone.selectedItems.map(\.name), ["report.pdf"])

        let created = await app.createFolder(named: "Trips", in: .phone)
        XCTAssertTrue(created)
        let item = try XCTUnwrap(app.phone.items.first { $0.name == "report.pdf" })
        let renamed = await app.rename(item, to: "Report 2026.pdf", in: .phone)
        XCTAssertTrue(renamed)
        XCTAssertEqual(Set(app.phone.items.map(\.name)), ["photo.jpg", "Report 2026.pdf", "Trips"])

        await app.session.disconnect()
    }
}
