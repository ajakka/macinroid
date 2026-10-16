import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Macinroid

/// Icon previews and Quick Look for files on the phone, against a simulated phone.
@MainActor
final class PreviewTests: XCTestCase {
    private var scratch: URL!
    private var backend: SimulatedBackend!
    private var app: AppModel!

    private let storage: UInt32 = 0x0001_0001
    private var phoneRoot: URL { scratch.appendingPathComponent("Phone/Internal") }

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewTests-\(UUID().uuidString)")
        try await makeApp(bytesPerSecond: nil)
    }

    override func tearDown() async throws {
        await app.phoneFiles.stopAll()
        await app.transfers.waitUntilIdle()
        app.phoneFiles.removeAll()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeApp(bytesPerSecond: Int64?) async throws {
        backend = SimulatedBackend(configuration: .init(
            root: scratch.appendingPathComponent("Phone"), bytesPerSecond: bytesPerSecond, seedSampleContent: false
        ))
        let defaults = UserDefaults(suiteName: "PreviewTests-\(UUID().uuidString)")!
        app = AppModel(settings: AppSettings(defaults: defaults), backend: backend)
        app.alertHandler = { _, _, _ in 0 }
        let connected = await app.session.connect()
        XCTAssertTrue(connected)
    }

    // MARK: Helpers

    /// Puts a picture on the phone. `padding` makes the file longer than
    /// the part of it read for its embedded picture.
    private func makePhoto(
        _ path: String, type: UTType = .jpeg, orientation: CGImagePropertyOrientation = .up,
        embedsThumbnail: Bool = true, padding: Int = 0
    ) throws {
        let url = phoneRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let context = try XCTUnwrap(CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
            kCGImageDestinationEmbedThumbnail: embedsThumbnail,
            kCGImagePropertyOrientation: orientation.rawValue,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        if padding > 0 {
            // bytes after the end of a JPEG are ignored by those who read it
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(count: padding))
            try handle.close()
        }
    }

    /// Records a video onto the phone the way phones do, with the index at the
    /// end. Its frames are noise, so that the frames take up most of the file.
    private func makeVideo(_ path: String, portrait: Bool = false) async throws {
        let url = phoneRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (width, height) = (320, 180)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        if portrait {
            // phones held upright record sideways and say how to turn the picture
            input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var generator = SystemRandomNumberGenerator()
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            for index in 0..<(CVPixelBufferGetBytesPerRow(pixels) * height) { base[index] = UInt8.random(in: 0...255, using: &generator) }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    private func makeFile(_ path: String, size: Int) throws {
        let url = phoneRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: url)
    }

    private func item(_ name: String) throws -> FileItem {
        try XCTUnwrap(app.phone.items.first { $0.name == name }, "\(name) is not listed")
    }

    /// Asks for the icon preview of a file in the phone pane and waits for it.
    private func iconPreview(of name: String) async throws -> NSImage? {
        var image: NSImage?
        let ticket = app.requestIconPreview(for: try item(name), in: .phone, size: 64, scale: 2) { image = $0 }
        if ticket != nil {
            await wait(for: "the icon preview of \(name)") { image != nil }
        }
        return image
    }

    private func wait(for description: String, timeout: TimeInterval = 10, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Icon previews

    func testAPhotoShowsThePictureInItsFirstBytesTurnedUpright() async throws {
        try makePhoto("DCIM/Camera/portrait.jpg", orientation: .right, padding: 200_000)
        await app.phone.navigate(to: "/DCIM/Camera")

        let found = try await iconPreview(of: "portrait.jpg")
        let image = try XCTUnwrap(found)
        XCTAssertGreaterThan(image.size.height, image.size.width, "a photo taken upright is shown upright")
        // nothing beyond the first bytes was fetched
        XCTAssertNil(app.phoneFiles.localCopy(of: try item("portrait.jpg"), storage: storage))
    }

    func testThePhonesOwnPictureOfASidewaysPhotoIsTurnedToo() async throws {
        try makePhoto("DCIM/Camera/plain.jpg", orientation: .right, embedsThumbnail: false, padding: 200_000)
        await app.phone.navigate(to: "/DCIM/Camera")
        XCTAssertTrue(try item("plain.jpg").hasThumbnail)

        let found = try await iconPreview(of: "plain.jpg")
        let image = try XCTUnwrap(found)
        XCTAssertGreaterThan(image.size.height, image.size.width)
        XCTAssertNil(app.phoneFiles.localCopy(of: try item("plain.jpg"), storage: storage))
    }

    func testOtherImagesUseThePhonesPicture() async throws {
        try makePhoto("Pictures/Screenshots/shot.png", type: .png)
        await app.phone.navigate(to: "/Pictures/Screenshots")

        let image = try await iconPreview(of: "shot.png")
        XCTAssertNotNil(image)
        XCTAssertNil(app.phoneFiles.localCopy(of: try item("shot.png"), storage: storage))
    }

    func testASmallImageWithoutAnyPictureIsFetchedWhole() async throws {
        try makePhoto("Download/scan.tiff", type: .tiff)
        await app.phone.navigate(to: "/Download")
        XCTAssertFalse(try item("scan.tiff").hasThumbnail)

        let image = try await iconPreview(of: "scan.tiff")
        XCTAssertNotNil(image)
        // the copy serves Quick Look later
        XCTAssertNotNil(app.phoneFiles.localCopy(of: try item("scan.tiff"), storage: storage))
    }

    func testFilesWithoutPicturesAskForNothing() async throws {
        try makeFile("Download/notes.txt", size: 100)
        try makeFile("Music/song.mp3", size: 100)
        await app.phone.navigate(to: "/Download")

        var called = false
        XCTAssertNil(app.requestIconPreview(for: try item("notes.txt"), in: .phone, size: 64, scale: 2) { _ in called = true })
        await app.phone.navigate(to: "/Music")
        XCTAssertNil(app.requestIconPreview(for: try item("song.mp3"), in: .phone, size: 64, scale: 2) { _ in called = true })
        XCTAssertFalse(called)
    }

    func testAVideoShowsItsFirstFrameTurnedUpright() async throws {
        try await makeVideo("DCIM/Camera/wide.mp4")
        try await makeVideo("DCIM/Camera/upright.mp4", portrait: true)
        await app.phone.navigate(to: "/DCIM/Camera")
        XCTAssertGreaterThan(try item("wide.mp4").size, 256 << 10, "the frames should outweigh what is read at the start")

        let wide = try await iconPreview(of: "wide.mp4")
        let upright = try await iconPreview(of: "upright.mp4")
        let wideSize = try XCTUnwrap(wide).size, uprightSize = try XCTUnwrap(upright).size
        XCTAssertGreaterThan(wideSize.width, wideSize.height)
        XCTAssertGreaterThan(uprightSize.height, uprightSize.width)
        // the video was not fetched
        XCTAssertNil(app.phoneFiles.localCopy(of: try item("wide.mp4"), storage: storage))
    }

    func testTheIndexOfAVideoIsFoundAtItsEnd() async throws {
        try await makeVideo("clip.mp4")
        let data = try Data(contentsOf: phoneRoot.appendingPathComponent("clip.mp4"))
        let bytes = [UInt8](data)

        // the boxes at the top: ftyp, then the frames, then the index
        var offset = 0, types: [String] = [], moov: [UInt8] = []
        while offset + 8 <= bytes.count {
            var length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            if length == 1 {
                // a 64-bit length follows the type
                length = bytes[offset + 8..<offset + 16].reduce(0) { $0 << 8 | Int($1) }
            }
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            types.append(type)
            if type == "moov" { moov = Array(bytes[offset..<offset + length]) }
            offset += length
        }
        XCTAssertEqual(types.last, "moov", "phones write the index last: \(types)")

        let sample = try XCTUnwrap(VideoFrame.firstVideoSample(inMovieBox: moov))
        let mdat = try XCTUnwrap(types.firstIndex(of: "mdat"))
        XCTAssertGreaterThan(mdat, 0)
        XCTAssertGreaterThan(sample.length, 1000, "an intra frame of noise is large")
        XCTAssertLessThan(sample.offset + Int64(sample.length), Int64(bytes.count))
    }

    func testIconPreviewsFollowTheSetting() async throws {
        try makePhoto("DCIM/a.jpg")
        await app.phone.navigate(to: "/DCIM")

        app.setShowsIconPreviews(false)
        XCTAssertNil(app.requestIconPreview(for: try item("a.jpg"), in: .phone, size: 64, scale: 2) { _ in })

        app.setShowsIconPreviews(true)
        let image = try await iconPreview(of: "a.jpg")
        XCTAssertNotNil(image)
    }

    func testACancelledRequestIsNotAnswered() async throws {
        try makePhoto("DCIM/a.jpg")
        try makePhoto("DCIM/b.jpg")
        await app.phone.navigate(to: "/DCIM")

        var answered: [String] = []
        let first = app.requestIconPreview(for: try item("a.jpg"), in: .phone, size: 64, scale: 2) { _ in answered.append("a") }
        first?.cancel()
        _ = app.requestIconPreview(for: try item("b.jpg"), in: .phone, size: 64, scale: 2) { _ in answered.append("b") }

        await wait(for: "the second picture") { answered.contains("b") }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(answered, ["b"])
    }

    // MARK: Quick Look

    func testQuickLookShowsACopyOfThePhoneFile() async throws {
        try makeFile("Download/report.pdf", size: 300_000)
        await app.phone.navigate(to: "/Download")
        app.phone.select(names: ["report.pdf"])

        let preview = try XCTUnwrap(app.previewItems(for: .phone).first)
        XCTAssertNil(preview.previewItemURL, "the panel shows a spinner until the copy is there")
        XCTAssertEqual(preview.previewItemTitle, "report.pdf")

        // what the panel does when it shows the item
        app.quickLook.onShowItem?(preview)
        await wait(for: "the copy") { preview.previewItemURL != nil }

        let url = try XCTUnwrap(preview.previewItemURL)
        XCTAssertEqual(url.lastPathComponent, "report.pdf")
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: phoneRoot.appendingPathComponent("Download/report.pdf")))

        // the next time, it is there at once
        XCTAssertEqual(app.previewItems(for: .phone).first?.previewItemURL, url)
    }

    func testQuickLookLeavesPhoneFoldersOut() async throws {
        try makeFile("Download/a.txt", size: 10)
        try FileManager.default.createDirectory(at: phoneRoot.appendingPathComponent("Download/Folder"), withIntermediateDirectories: true)
        await app.phone.navigate(to: "/Download")
        app.phone.selectAll()

        XCTAssertEqual(app.previewItems(for: .phone).map(\.id), ["/Download/a.txt"])
    }

    func testAChangedFileIsFetchedAgain() async throws {
        try makeFile("Download/a.txt", size: 10)
        await app.phone.navigate(to: "/Download")
        let before = try await app.phoneFiles.fetch(try item("a.txt"), storage: storage, urgent: true)

        try makeFile("Download/a.txt", size: 20)
        await app.phone.reload()
        XCTAssertNil(app.phoneFiles.localCopy(of: try item("a.txt"), storage: storage))
        let after = try await app.phoneFiles.fetch(try item("a.txt"), storage: storage, urgent: true)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(try Data(contentsOf: after).count, 20)
    }

    // MARK: Fetching

    func testTwoRequestsForOneFileFetchItOnce() async throws {
        try makeFile("Download/a.bin", size: 100_000)
        await app.phone.navigate(to: "/Download")
        let file = try item("a.bin")

        let files = app.phoneFiles, storage = storage
        let first = Task { try await files.fetch(file, storage: storage, urgent: false) }
        let second = Task { try await files.fetch(file, storage: storage, urgent: true) }
        let urls = try await [first.value, second.value]
        XCTAssertEqual(urls[0], urls[1])
    }

    func testABigFetchNobodyWaitsForStops() async throws {
        try await makeApp(bytesPerSecond: 8 << 20)
        try makeFile("Movies/long.mp4", size: 40 << 20)
        await app.phone.navigate(to: "/Movies")
        let file = try item("long.mp4")

        let waiting = Task { try await app.phoneFiles.fetch(file, storage: storage, urgent: true) }
        await wait(for: "the fetch to show") { app.phoneFiles.current != nil }
        XCTAssertEqual(app.phoneFiles.current?.name, "long.mp4")

        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("the fetch should have been called off")
        } catch {}

        await wait(for: "the fetch to stop", timeout: 3) { app.phoneFiles.current == nil }
        XCTAssertNil(app.phoneFiles.localCopy(of: file, storage: storage))
        XCTAssertTrue(app.session.isConnected)
    }

    func testATransferStopsFetchingFirst() async throws {
        try await makeApp(bytesPerSecond: 8 << 20)
        try makeFile("Movies/long.mp4", size: 40 << 20)
        await app.phone.navigate(to: "/Movies")
        let file = try item("long.mp4")

        let fetching = Task { try await app.phoneFiles.fetch(file, storage: storage, urgent: true) }
        await wait(for: "the fetch to show") { app.phoneFiles.current != nil }

        let mac = scratch.appendingPathComponent("Mac")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        app.phone.select(names: [])
        try Data(repeating: 1, count: 1000).write(to: mac.appendingPathComponent("up.txt"))
        app.drop(.macFiles([mac.appendingPathComponent("up.txt").path]), on: .phone)

        do {
            _ = try await fetching.value
            XCTFail("the fetch should have made way for the transfer")
        } catch {}
        await app.transfers.waitUntilIdle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: phoneRoot.appendingPathComponent("Movies/up.txt").path))
    }
}
