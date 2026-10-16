import XCTest
@testable import Macinroid

/// Drives the app's model against a simulated phone, the way the window does.
@MainActor
final class AppModelTests: XCTestCase {
    private var scratch: URL!
    private var macFolder: URL!
    private var backend: SimulatedBackend!
    private var app: AppModel!

    /// The questions the app asked, and the answer to give to the next ones.
    private var questions: [String] = []
    private var answer = 0

    private let storage: UInt32 = 0x0001_0001

    /// Stands in for the system clipboard, which the tests must leave alone.
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MacinroidTests-\(UUID().uuidString)")
        macFolder = scratch.appendingPathComponent("Mac")
        try FileManager.default.createDirectory(at: macFolder, withIntermediateDirectories: true)

        makeApp(bytesPerSecond: nil)
        let connected = await app.session.connect()
        XCTAssertTrue(connected)
        await app.mac.navigate(to: macFolder.path)
    }

    override func tearDown() async throws {
        await app.transfers.waitUntilIdle()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeApp(bytesPerSecond: Int64?) {
        backend = SimulatedBackend(configuration: .init(
            root: scratch.appendingPathComponent("Phone"),
            bytesPerSecond: bytesPerSecond,
            seedSampleContent: false
        ))

        let defaults = UserDefaults(suiteName: "MacinroidTests-\(UUID().uuidString)")!
        app = AppModel(settings: AppSettings(defaults: defaults), backend: backend)
        pasteboard?.releaseGlobally()
        pasteboard = NSPasteboard.withUniqueName()
        app.pasteboard = pasteboard
        app.alertHandler = { [weak self] title, _, _ in
            self?.questions.append(title)
            return self?.answer ?? 0
        }
    }

    // MARK: Helpers

    @discardableResult
    private func makeMacFile(_ name: String, size: Int = 1024) throws -> String {
        let url = macFolder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: size).write(to: url)
        return url.path
    }

    private var phoneRoot: URL { scratch.appendingPathComponent("Phone/Internal") }

    private func phoneFileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: phoneRoot.appendingPathComponent(path).path)
    }

    private func makePhoneFile(_ path: String, size: Int = 1024) throws {
        let url = phoneRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 9, count: size).write(to: url)
    }

    /// Waits for something the app does in the background.
    private func wait(for description: String, timeout: TimeInterval = 5, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Connecting

    func testConnectingShowsTheDeviceAndItsFirstStorage() async {
        XCTAssertEqual(app.session.device?.displayName, "Pixel 9 Pro")
        XCTAssertEqual(app.session.storages.count, 2)
        XCTAssertEqual(app.session.selectedStorageID, storage)
        XCTAssertEqual(app.phone.path, "/")
        XCTAssertNil(app.phone.error)
        XCTAssertTrue(app.isAvailable(.phone))
    }

    func testUnpluggingAndReconnectingReturnsToTheSameFolder() async throws {
        try makePhoneFile("DCIM/Camera/a.jpg")
        await app.phone.navigate(to: "/DCIM/Camera")
        XCTAssertEqual(app.phone.items.map(\.name), ["a.jpg"])

        backend.setAttached(false)
        await app.session.deviceWasDetached(serialNumber: "SIMULATED0001")
        XCTAssertEqual(app.session.state, .disconnected)
        XCTAssertFalse(app.isAvailable(.phone))

        backend.setAttached(true)
        let connected = await app.session.connect()
        XCTAssertTrue(connected)
        XCTAssertTrue(app.session.isSameDeviceAsBefore)
        XCTAssertEqual(app.phone.path, "/DCIM/Camera")
        XCTAssertEqual(app.phone.items.map(\.name), ["a.jpg"])
    }

    func testAFailedRequestEndsTheSession() async throws {
        backend.setAttached(false)
        await app.phone.reload()

        XCTAssertNotNil(app.phone.error)
        XCTAssertFalse(app.session.isConnected)
    }

    func testDetachingAnotherDeviceChangesNothing() async {
        await app.session.deviceWasDetached(serialNumber: "SOME-OTHER-DEVICE")
        XCTAssertTrue(app.session.isConnected)
    }

    func testSwitchingStorageStartsAtItsRoot() async throws {
        try makePhoneFile("Music/a.mp3")
        await app.phone.navigate(to: "/Music")

        app.selectStorage(0x0002_0001)
        await wait(for: "the SD card listing") { !app.phone.isLoading && app.phone.hasContent }

        XCTAssertEqual(app.phone.path, "/")
        XCTAssertEqual(app.session.selectedStorage?.displayName, "SD card")
        XCTAssertTrue(app.phone.items.isEmpty)
    }

    // MARK: Browsing

    func testNavigationHistory() async throws {
        try makePhoneFile("Music/Podcasts/a.mp3")
        await app.phone.reload()

        await app.phone.navigate(to: "/Music")
        await app.phone.navigate(to: "/Music/Podcasts")
        XCTAssertTrue(app.phone.canGoBack)

        await app.phone.goBack()
        XCTAssertEqual(app.phone.path, "/Music")
        XCTAssertTrue(app.phone.canGoForward)

        await app.phone.goForward()
        XCTAssertEqual(app.phone.path, "/Music/Podcasts")

        await app.phone.goUp()
        XCTAssertEqual(app.phone.path, "/Music")
        // the folder that was left is selected, as in Finder
        XCTAssertEqual(app.phone.selectedItems.map(\.name), ["Podcasts"])
    }

    func testHiddenFilesFollowTheSetting() async throws {
        try makePhoneFile(".nomedia")
        try makePhoneFile("visible.txt")

        await app.phone.reload()
        XCTAssertEqual(app.phone.items.map(\.name), ["visible.txt"])

        app.setShowsHiddenFiles(true, in: .phone)
        await wait(for: "hidden files") { app.phone.items.count == 2 }
        XCTAssertEqual(Set(app.phone.items.map(\.name)), [".nomedia", "visible.txt"])
    }

    func testFilteringNarrowsTheListingAndTheSelection() async throws {
        try makeMacFile("report.pdf")
        try makeMacFile("photo.jpg")
        try makeMacFile("Report draft.txt")
        await app.mac.reload()

        app.mac.selectAll()
        app.mac.filter = "report"

        XCTAssertEqual(app.mac.items.map(\.name), ["Report draft.txt", "report.pdf"])
        XCTAssertEqual(app.mac.selection.count, 2)

        app.mac.filter = ""
        XCTAssertEqual(app.mac.items.count, 3)
    }

    func testOpeningAFolderThatIsGoneShowsAnErrorInThePane() async {
        await app.mac.navigate(to: macFolder.appendingPathComponent("missing").path)

        XCTAssertNotNil(app.mac.error)
        XCTAssertTrue(app.mac.items.isEmpty)
        XCTAssertTrue(app.mac.canGoBack)
    }

    // MARK: Folders, renaming, deleting

    func testCreatingAFolderSelectsIt() async {
        let created = await app.createFolder(named: "Holiday", in: .phone)

        XCTAssertTrue(created)
        XCTAssertTrue(phoneFileExists("Holiday"))
        XCTAssertEqual(app.phone.selectedItems.map(\.name), ["Holiday"])
        XCTAssertEqual(app.problem(withName: "holiday", in: .phone), .taken("holiday"))
    }

    func testRenamingOnBothSides() async throws {
        try makePhoneFile("old.txt")
        try makeMacFile("draft.txt")
        await app.phone.reload()
        await app.mac.reload()

        let phoneItem = try XCTUnwrap(app.phone.items.first { $0.name == "old.txt" })
        let renamedOnPhone = await app.rename(phoneItem, to: "new.txt", in: .phone)
        XCTAssertTrue(renamedOnPhone)
        XCTAssertTrue(phoneFileExists("new.txt"))
        XCTAssertFalse(phoneFileExists("old.txt"))

        let macItem = try XCTUnwrap(app.mac.items.first { $0.name == "draft.txt" })
        let renamedOnMac = await app.rename(macItem, to: "Draft.txt", in: .mac)
        XCTAssertTrue(renamedOnMac)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: macFolder.path), ["Draft.txt"])
        XCTAssertEqual(app.mac.selectedItems.map(\.name), ["Draft.txt"])
    }

    func testDeletingFromThePhoneAsksFirst() async throws {
        try makePhoneFile("keep.txt")
        try makePhoneFile("Trash me/inner.txt")
        await app.phone.reload()
        app.phone.select(names: ["Trash me"])

        // "Cancel"
        answer = 1
        app.deleteSelection(in: .phone)
        await wait(for: "the question") { questions.count == 1 }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(phoneFileExists("Trash me"))

        // "Delete"
        answer = 0
        app.deleteSelection(in: .phone)
        await wait(for: "the deletion") { !phoneFileExists("Trash me") }
        await wait(for: "the refreshed listing") { app.phone.items.map(\.name) == ["keep.txt"] }
        XCTAssertTrue(questions[1].contains("Trash me"))
    }

    // MARK: Transfers

    func testUploadingAFolderAndAFile() async throws {
        let folder = try makeMacFile("Album/one.jpg", size: 300_000)
        try makeMacFile("Album/nested/two.jpg", size: 200_000)
        try makeMacFile("Album/.DS_Store")
        let file = try makeMacFile("song.mp3", size: 500_000)
        let album = (folder as NSString).deletingLastPathComponent

        XCTAssertTrue(app.drop(.macFiles([album, file]), on: .phone))
        await app.transfers.waitUntilIdle()

        XCTAssertTrue(phoneFileExists("Album/one.jpg"))
        XCTAssertTrue(phoneFileExists("Album/nested/two.jpg"))
        XCTAssertTrue(phoneFileExists("song.mp3"))
        XCTAssertFalse(phoneFileExists("Album/.DS_Store"))

        let job = try XCTUnwrap(app.transfers.recent.first)
        XCTAssertEqual(job.phase, .finished)
        XCTAssertEqual(job.progress.filesDone, 3)
        XCTAssertEqual(job.progress.bytesDone, 1_000_000)
        XCTAssertEqual(job.progress.bytesTotal, 1_000_000)

        // the phone's pane shows the new items, selected
        XCTAssertEqual(Set(app.phone.selectedItems.map(\.name)), ["Album", "song.mp3"])
        XCTAssertTrue(questions.isEmpty)
    }

    func testUploadingIntoAFolderOfThePhone() async throws {
        try makePhoneFile("Music/existing.mp3")
        let file = try makeMacFile("new.mp3")

        XCTAssertTrue(app.drop(.macFiles([file]), on: .phone, into: "/Music"))
        await app.transfers.waitUntilIdle()

        XCTAssertTrue(phoneFileExists("Music/new.mp3"))
    }

    func testDownloadingKeepsTheFoldersStructure() async throws {
        try makePhoneFile("DCIM/Camera/a.jpg", size: 100_000)
        try makePhoneFile("DCIM/Camera/2026/b.jpg", size: 50_000)

        XCTAssertTrue(app.drop(.phoneItems(["/DCIM/Camera"], storageID: storage), on: .mac))
        await app.transfers.waitUntilIdle()

        XCTAssertTrue(FileManager.default.fileExists(atPath: macFolder.appendingPathComponent("Camera/a.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: macFolder.appendingPathComponent("Camera/2026/b.jpg").path))
        XCTAssertEqual(app.mac.selectedItems.map(\.name), ["Camera"])
    }

    func testCopyAndPasteAcrossPanes() async throws {
        app.settings.showMacPane = true
        try makeMacFile("a.txt")
        try makeMacFile("b.txt")
        await app.mac.reload()

        XCTAssertFalse(app.canCopy(in: .mac))
        app.mac.select(names: ["a.txt"])
        app.copy(in: .mac)
        app.mac.select(names: ["b.txt"])
        app.addToClipboard(in: .mac)
        XCTAssertEqual(app.clipboard?.paths.count, 2)

        // pasting where the items came from makes no sense
        XCTAssertTrue(app.canPaste(in: .phone))
        app.paste(in: .phone)
        await app.transfers.waitUntilIdle()

        XCTAssertTrue(phoneFileExists("a.txt"))
        XCTAssertTrue(phoneFileExists("b.txt"))
        XCTAssertNil(app.clipboard)
    }

    func testCopyToTheOtherPane() async throws {
        try makePhoneFile("clip.mp4", size: 64_000)
        await app.phone.reload()
        app.phone.select(names: ["clip.mp4"])

        XCTAssertTrue(app.canCopyToOtherPane(from: .phone))
        app.copySelectionToOtherPane(from: .phone)
        await app.transfers.waitUntilIdle()

        XCTAssertTrue(FileManager.default.fileExists(atPath: macFolder.appendingPathComponent("clip.mp4").path))
    }

    func testDropsAreOnlyAcceptedFromTheOtherSide() {
        XCTAssertFalse(app.canDrop(.macFiles(["/tmp/a"]), on: .mac))
        XCTAssertFalse(app.canDrop(.phoneItems(["/a"], storageID: storage), on: .phone))
        XCTAssertTrue(app.canDrop(.macFiles(["/tmp/a"]), on: .phone))
        XCTAssertTrue(app.canDrop(.phoneItems(["/a"], storageID: storage), on: .mac))
    }

    func testNamesAndroidCannotStoreAreRefused() async throws {
        let file = try makeMacFile("what:ever.txt")

        app.drop(.macFiles([file]), on: .phone)
        await wait(for: "the explanation") { questions.count == 1 }

        XCTAssertFalse(app.transfers.hasWork)
        XCTAssertFalse(phoneFileExists("what:ever.txt"))
    }

    // MARK: The phone by itself: working with Finder

    private var clipboardFiles: [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    func testThePhoneHasTheWindowToItselfByDefault() {
        XCTAssertFalse(app.settings.showMacPane)
        XCTAssertEqual(app.activePane, .phone)

        // there is no other pane to switch or copy to
        app.switchPane()
        app.activate(.mac)
        XCTAssertEqual(app.activePane, .phone)
    }

    func testCopyingPutsRealFilesOnTheClipboardForFinder() async throws {
        try makePhoneFile("DCIM/photo.jpg", size: 70_000)
        try makePhoneFile("DCIM/Album/inner.jpg", size: 10_000)
        await app.phone.navigate(to: "/DCIM")
        app.phone.selectAll()

        app.copy(in: .phone)
        XCTAssertEqual(app.finderClipboard, .preparing)
        XCTAssertTrue(app.transfers.hasWork)
        await app.transfers.waitUntilIdle()

        XCTAssertEqual(app.finderClipboard, .ready)
        XCTAssertEqual(app.transfers.recent.first?.title, "Copied to the clipboard")

        let files = clipboardFiles
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["photo.jpg", "Album"])
        let photo = try XCTUnwrap(files.first { $0.lastPathComponent == "photo.jpg" })
        XCTAssertEqual(try Data(contentsOf: photo).count, 70_000)
        let album = try XCTUnwrap(files.first { $0.lastPathComponent == "Album" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: album.appendingPathComponent("inner.jpg").path))
    }

    func testCopyingAgainReplacesWhatWasOnTheClipboard() async throws {
        try makePhoneFile("one.txt")
        try makePhoneFile("two.txt")
        await app.phone.reload()

        app.phone.select(names: ["one.txt"])
        app.copy(in: .phone)
        await app.transfers.waitUntilIdle()
        let first = try XCTUnwrap(clipboardFiles.first)

        app.phone.select(names: ["two.txt"])
        app.copy(in: .phone)
        await app.transfers.waitUntilIdle()

        XCTAssertEqual(clipboardFiles.map(\.lastPathComponent), ["two.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "the earlier copy is cleaned up")
    }

    func testAddingToTheClipboardGathersItemsFromSeveralFolders() async throws {
        try makePhoneFile("A/same name.txt", size: 100)
        try makePhoneFile("B/same name.txt", size: 200)

        await app.phone.navigate(to: "/A")
        app.phone.selectAll()
        app.copy(in: .phone)
        // the phone is busy, and its pane out of reach, until the copies are made
        XCTAssertFalse(app.canCopy(in: .phone))
        await app.transfers.waitUntilIdle()
        await app.phone.navigate(to: "/B")
        app.phone.selectAll()
        app.addToClipboard(in: .phone)
        await app.transfers.waitUntilIdle()

        XCTAssertEqual(app.finderClipboard, .ready)
        XCTAssertEqual(app.clipboard?.paths, ["/A/same name.txt", "/B/same name.txt"])
        // both copies survive, although they share a name
        XCTAssertEqual(try clipboardFiles.map { try Data(contentsOf: $0).count }.sorted(), [100, 200])
    }

    func testCancellingTheCopyLeavesTheClipboardAlone() async throws {
        makeApp(bytesPerSecond: 2 << 20)
        let connected = await app.session.connect()
        XCTAssertTrue(connected)
        try makePhoneFile("big.bin", size: 6 << 20)
        await app.phone.reload()
        app.phone.selectAll()

        app.copy(in: .phone)
        await wait(for: "the copy to get going") { (app.transfers.active?.progress.bytesDone ?? 0) > 300_000 }
        app.transfers.cancelAll()
        await app.transfers.waitUntilIdle()

        XCTAssertEqual(app.finderClipboard, .empty)
        XCTAssertNil(app.clipboard)
        XCTAssertTrue(clipboardFiles.isEmpty)
    }

    func testPastingElsewhereOnThePhoneCopiesTheItemsThere() async throws {
        try makePhoneFile("Camera/photo.jpg", size: 5000)
        try makePhoneFile("Backup/keep.txt")

        await app.phone.navigate(to: "/Camera")
        app.phone.selectAll()
        app.copy(in: .phone)
        await app.transfers.waitUntilIdle()

        await app.phone.navigate(to: "/Backup")
        XCTAssertTrue(app.canPaste(in: .phone))
        app.paste(in: .phone)
        await app.transfers.waitUntilIdle()

        XCTAssertTrue(phoneFileExists("Backup/photo.jpg"))
        XCTAssertTrue(phoneFileExists("Camera/photo.jpg"))
    }

    func testWithTheMacPaneCopyingStaysInsideTheApp() async throws {
        app.settings.showMacPane = true
        try makePhoneFile("a.txt")
        await app.phone.reload()
        app.phone.selectAll()

        app.copy(in: .phone)

        XCTAssertEqual(app.finderClipboard, .empty)
        XCTAssertFalse(app.transfers.hasWork)
        XCTAssertTrue(app.canPaste(in: .mac))
    }

    func testDownloadSavesTheSelectionToTheChosenFolder() async throws {
        try makePhoneFile("Movies/clip.mp4", size: 64_000)
        await app.phone.navigate(to: "/Movies")
        XCTAssertFalse(app.canDownloadSelection())

        app.phone.selectAll()
        app.settings.downloadFolder = macFolder.path
        XCTAssertTrue(app.canDownloadSelection())
        app.downloadSelection()
        await app.transfers.waitUntilIdle()

        XCTAssertTrue(FileManager.default.fileExists(atPath: macFolder.appendingPathComponent("clip.mp4").path))
        XCTAssertEqual(app.transfers.recent.first?.title, "Copied to “Mac”")
        XCTAssertEqual(app.notice?.text, "“clip.mp4” saved to “Mac”")
        XCTAssertEqual(app.notice?.revealPath, macFolder.appendingPathComponent("clip.mp4").path)
    }

    /// Dragging to Finder hands over promises of files. On the drop, AppKit
    /// asks for each one's name and then for it to be written to a URL of
    /// Finder's choosing. (AppKit only does that during a real drag, so the
    /// test makes the same calls itself.)
    func testItemsDraggedToFinderAreDeliveredWherePromised() async throws {
        try makePhoneFile("DCIM/photo.jpg", size: 70_000)
        try makePhoneFile("DCIM/Album/inner.jpg", size: 10_000)
        await app.phone.navigate(to: "/DCIM")

        let fulfiller = FilePromiseFulfiller(app: app)
        let promises = app.phone.items.map { fulfiller.promise(for: $0, storageID: storage) }

        // what goes on the pasteboard is enough for a drop inside the app
        let drag = NSPasteboard.withUniqueName()
        defer { drag.releaseGlobally() }
        XCTAssertTrue(drag.writeObjects(promises))
        XCTAssertEqual(DragPayload(pasteboard: drag), .phoneItems(["/DCIM/Album", "/DCIM/photo.jpg"], storageID: storage))

        // the drop in Finder
        let destination = macFolder.appendingPathComponent("Dropped")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        XCTAssertEqual(promises.map { fulfiller.filePromiseProvider($0, fileNameForType: "public.data") }, ["Album", "photo.jpg"])

        let delivered = expectation(description: "both items delivered")
        delivered.expectedFulfillmentCount = 2
        // Finder picks another name when one is taken
        for (promise, name) in zip(promises, ["Album", "photo 2.jpg"]) {
            fulfiller.filePromiseProvider(promise, writePromiseTo: destination.appendingPathComponent(name)) { error in
                XCTAssertNil(error)
                delivered.fulfill()
            }
        }
        await fulfillment(of: [delivered], timeout: 10)

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("photo 2.jpg")).count, 70_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Album/inner.jpg").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted(), ["Album", "photo 2.jpg"])
        // one transfer for the whole drop, not one per item
        XCTAssertEqual(app.transfers.recent.count, 1)
    }

    func testAFailedDragOutIsReportedToFinder() async throws {
        try makePhoneFile("a.txt")
        await app.phone.reload()
        let fulfiller = FilePromiseFulfiller(app: app)
        let promise = fulfiller.promise(for: app.phone.items[0], storageID: storage)

        await app.session.disconnect()
        let reported = expectation(description: "failure reported")
        fulfiller.filePromiseProvider(promise, writePromiseTo: macFolder.appendingPathComponent("a.txt")) { error in
            XCTAssertNotNil(error)
            reported.fulfill()
        }
        await fulfillment(of: [reported], timeout: 10)
    }

    // MARK: Existing items

    func testReplacingAnExistingItemIsConfirmed() async throws {
        try makePhoneFile("notes.txt", size: 10)
        let file = try makeMacFile("notes.txt", size: 2000)

        answer = 0 // "Replace"
        app.drop(.macFiles([file]), on: .phone)
        await app.transfers.waitUntilIdle()

        XCTAssertEqual(questions.count, 1)
        XCTAssertTrue(questions[0].contains("notes.txt"))
        let size = try FileManager.default.attributesOfItem(atPath: phoneRoot.appendingPathComponent("notes.txt").path)[.size] as? Int
        XCTAssertEqual(size, 2000)
    }

    func testSkippingExistingItemsCopiesTheRest() async throws {
        try makePhoneFile("old.txt", size: 10)
        let old = try makeMacFile("old.txt", size: 2000)
        let new = try makeMacFile("new.txt", size: 2000)

        answer = 1 // "Skip"
        app.drop(.macFiles([old, new]), on: .phone)
        await app.transfers.waitUntilIdle()

        let size = try FileManager.default.attributesOfItem(atPath: phoneRoot.appendingPathComponent("old.txt").path)[.size] as? Int
        XCTAssertEqual(size, 10)
        XCTAssertTrue(phoneFileExists("new.txt"))
    }

    func testDecliningToReplaceCopiesNothing() async throws {
        try makePhoneFile("only.txt", size: 10)
        let file = try makeMacFile("only.txt", size: 2000)

        answer = 1 // "Cancel": with a single item there is nothing to skip to
        app.drop(.macFiles([file]), on: .phone)
        await app.transfers.waitUntilIdle()

        let size = try FileManager.default.attributesOfItem(atPath: phoneRoot.appendingPathComponent("only.txt").path)[.size] as? Int
        XCTAssertEqual(size, 10)
        XCTAssertEqual(app.transfers.recent.first?.phase, .cancelled)
    }

    // MARK: Cancelling and failures

    func testCancellingStopsTheTransferAndLeavesNoHalfFile() async throws {
        makeApp(bytesPerSecond: 2 << 20)
        let connected = await app.session.connect()
        XCTAssertTrue(connected)

        let small = try makeMacFile("1 small.bin", size: 100_000)
        let big = try makeMacFile("2 big.bin", size: 6 << 20)

        app.drop(.macFiles([small, big]), on: .phone)
        await wait(for: "the copy to get going") { (app.transfers.active?.progress.bytesDone ?? 0) > 400_000 }

        let job = try XCTUnwrap(app.transfers.active)
        XCTAssertEqual(job.phase, .copying)
        XCTAssertEqual(job.progress.filesTotal, 2)
        XCTAssertFalse(app.isAvailable(.phone), "the phone is busy during a transfer")

        app.transfers.cancel(job.id)
        await app.transfers.waitUntilIdle()

        XCTAssertEqual(app.transfers.recent.first?.phase, .cancelled)
        XCTAssertTrue(phoneFileExists("1 small.bin"), "what was copied before stays")
        XCTAssertFalse(phoneFileExists("2 big.bin"), "the interrupted file is removed")
        XCTAssertTrue(questions.isEmpty, "cancelling is not an error")
        XCTAssertTrue(app.isAvailable(.phone))
    }

    func testTransfersRunOneAfterTheOther() async throws {
        makeApp(bytesPerSecond: 4 << 20)
        let connected = await app.session.connect()
        XCTAssertTrue(connected)

        let first = try makeMacFile("first.bin", size: 1 << 20)
        let second = try makeMacFile("second.bin", size: 1 << 20)

        app.drop(.macFiles([first]), on: .phone)
        app.upload(filesFromOutside: [second])
        await wait(for: "both to be queued") { app.transfers.active != nil && app.transfers.waiting.count == 1 }

        await app.transfers.waitUntilIdle()
        XCTAssertTrue(phoneFileExists("first.bin"))
        XCTAssertTrue(phoneFileExists("second.bin"))
        XCTAssertEqual(app.transfers.recent.map(\.phase), [.finished, .finished])
    }

    func testCancellingAWaitingTransferNeverStartsIt() async throws {
        makeApp(bytesPerSecond: 2 << 20)
        let connected = await app.session.connect()
        XCTAssertTrue(connected)

        let first = try makeMacFile("first.bin", size: 1 << 20)
        let second = try makeMacFile("second.bin", size: 1 << 20)

        app.drop(.macFiles([first]), on: .phone)
        app.upload(filesFromOutside: [second])
        await wait(for: "the second to wait") { app.transfers.active != nil && app.transfers.waiting.count == 1 }

        app.transfers.cancel(app.transfers.waiting[0].id)
        await app.transfers.waitUntilIdle()

        XCTAssertTrue(phoneFileExists("first.bin"))
        XCTAssertFalse(phoneFileExists("second.bin"))
    }

    func testLosingThePhoneMidTransferIsReported() async throws {
        makeApp(bytesPerSecond: 2 << 20)
        let connected = await app.session.connect()
        XCTAssertTrue(connected)

        let big = try makeMacFile("big.bin", size: 6 << 20)
        app.drop(.macFiles([big]), on: .phone)
        await wait(for: "the copy to get going") { (app.transfers.active?.progress.bytesDone ?? 0) > 300_000 }

        backend.setAttached(false)
        await app.transfers.waitUntilIdle()
        await wait(for: "the error to be shown") { !questions.isEmpty }

        guard case .failed = app.transfers.recent.first?.phase else {
            return XCTFail("the transfer should have failed")
        }
        XCTAssertFalse(app.session.isConnected)
        XCTAssertFalse(phoneFileExists("big.bin"))
    }

    func testCopyingWithoutAPhoneExplainsWhy() async throws {
        await app.session.disconnect()
        let file = try makeMacFile("a.txt")

        XCTAssertFalse(app.canDrop(.macFiles([file]), on: .phone))
        XCTAssertFalse(app.drop(.macFiles([file]), on: .phone))
        XCTAssertFalse(app.transfers.hasWork)
    }
}

/// The Swift engine on real USB, as far as it can be exercised without a phone.
final class MTPBackendUSBTests: XCTestCase {
    func testLookingForDevicesOnTheBus() {
        // whatever is plugged in, listing it must not fail
        let candidates = USBInterfaceCandidate.all()
        for candidate in candidates {
            XCTAssertEqual(candidate.endpointCount, 3)
            XCTAssertFalse(candidate.description.isEmpty)
        }
        candidates.forEach { $0.release() }
    }

    func testConnectingWithoutAPhoneReportsThatNoneWasFound() async {
        let backend = MTPBackend()

        do {
            // a phone may happen to be plugged in while the tests run
            _ = try await backend.connect()
            await backend.disconnect()
        } catch let error as DeviceError {
            XCTAssertTrue(error.endsSession, "\(error)")
        } catch {
            XCTFail("unexpected error \(error)")
        }

        let report = await backend.debugReport()
        XCTAssertTrue(report.contains("USB interfaces with three endpoints"), report)
    }
}
