import AppKit
import CoreImage
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Small pictures of the phone's photos and other files, read over the cable
/// as the files come into view.
///
/// The phone answers one request at a time, so pictures are asked for one
/// after the other; whatever the user does in between goes first. The
/// cheapest source is tried first:
///
/// 1. For a JPEG, its first bytes. Cameras put a small picture in the EXIF
///    data at the start of every photo, along with how to turn it upright.
/// 2. The picture the phone keeps itself, which Android makes for photos,
///    screenshots and other images.
/// 3. Once everything cheaper has been shown: for a video, its first frame,
///    and for a small image or PDF without either picture, the whole file.
@MainActor
final class PhoneThumbnails {
    /// Lets a view say that it no longer needs the picture it asked for.
    final class Ticket {
        fileprivate(set) var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    /// Whether pictures may be asked for now; while files are being copied, they may not.
    var isEnabled: () -> Bool = { true }
    /// Called when a request has ended the session.
    var onSessionEnded: (@MainActor (DeviceError) async -> Void)?

    /// How much of a JPEG is read for the picture at its start. The EXIF
    /// data comes first and cannot be larger than 64 KB.
    static let headerLength = 96 << 10
    /// Images and PDFs up to this size are fetched whole when nothing cheaper gives a picture.
    static let wholeFileLimit: Int64 = 6 << 20

    private let backend: any DeviceBackend
    private let files: PhoneFileCache
    private let images = NSCache<NSString, NSImage>()
    /// Files known to have no picture.
    private var missing: Set<String> = []
    /// Requests for the cheap sources, then those waiting for a whole file.
    private var pending: [Request] = []
    private var deferred: [Request] = []
    private var running: Request?
    private var runner: Task<Void, Never>?

    private final class Request {
        let key: String
        let item: FileItem
        let storage: UInt32
        var waiters: [(ticket: Ticket, completion: @MainActor (NSImage) -> Void)] = []
        /// How the photo is to be turned upright, once its first bytes have been read.
        var orientation = CGImagePropertyOrientation.up
        /// Set once the cheap sources have given nothing and the costly one is to be tried.
        var triedCheapSources = false

        init(key: String, item: FileItem, storage: UInt32) {
            self.key = key
            self.item = item
            self.storage = storage
        }

        var isWanted: Bool { waiters.contains { !$0.ticket.isCancelled } }
    }

    init(backend: any DeviceBackend, files: PhoneFileCache) {
        self.backend = backend
        self.files = files
        images.totalCostLimit = 128 << 20
    }

    // MARK: Asking for pictures

    /// Whether a picture of the file may be had at all.
    static func mayHavePicture(_ item: FileItem) -> Bool {
        guard !item.isFolder else { return false }
        return item.hasThumbnail || isJPEG(item) || hasCostlySource(item)
    }

    /// Whether a picture can be had by reading more of the file than its first bytes.
    private static func hasCostlySource(_ item: FileItem) -> Bool {
        VideoFrame.canRead(item)
            || item.size <= wholeFileLimit && (item.contentType.conforms(to: .image) || item.contentType.conforms(to: .pdf))
    }

    /// The picture of a file, if it is at hand.
    func image(for item: FileItem, storage: UInt32) -> NSImage? {
        images.object(forKey: Self.key(item, storage: storage) as NSString)
    }

    /// Asks for a picture of the file. `completion` is called once it is
    /// there, unless the ticket has been cancelled by then; it is never
    /// called for a file that has none. Returns nil when there is nothing to wait for.
    func request(_ item: FileItem, storage: UInt32, completion: @escaping @MainActor (NSImage) -> Void) -> Ticket? {
        let key = Self.key(item, storage: storage)
        if let image = images.object(forKey: key as NSString) {
            completion(image)
            return nil
        }
        guard Self.mayHavePicture(item), !missing.contains(key), isEnabled() else { return nil }

        let ticket = Ticket()
        let request = [running].compactMap { $0 }.first { $0.key == key }
            ?? pending.first { $0.key == key }
            ?? deferred.first { $0.key == key }
            ?? {
                let request = Request(key: key, item: item, storage: storage)
                pending.append(request)
                return request
            }()
        request.waiters.append((ticket, completion))
        startRunner()
        return ticket
    }

    /// Drops every request that has not been answered yet.
    func cancelAll() {
        for request in pending + deferred + [running].compactMap({ $0 }) {
            request.waiters.forEach { $0.ticket.cancel() }
        }
        pending = []
        deferred = []
    }

    private static func key(_ item: FileItem, storage: UInt32) -> String {
        "\(storage)|\(item.path)|\(item.size)|\(item.modified?.timeIntervalSince1970 ?? 0)"
    }

    private static func isJPEG(_ item: FileItem) -> Bool {
        item.contentType.conforms(to: .jpeg)
    }

    // MARK: Fetching

    private func startRunner() {
        guard runner == nil else { return }
        runner = Task {
            while let next = takeNext() {
                guard isEnabled() else {
                    cancelAll()
                    break
                }
                running = next
                await load(next)
                running = nil
            }
            runner = nil
        }
    }

    private func takeNext() -> Request? {
        pending.removeAll { !$0.isWanted }
        deferred.removeAll { !$0.isWanted }
        if !pending.isEmpty { return pending.removeFirst() }
        return deferred.isEmpty ? nil : deferred.removeFirst()
    }

    private func load(_ request: Request) async {
        do {
            let image = request.triedCheapSources ? try await costlyPicture(for: request) : try await cheapPicture(for: request)
            if let image {
                deliver(NSImage(cgImage: image, size: .zero), to: request)
                return
            }
            guard request.isWanted else { return }

            if !request.triedCheapSources, Self.hasCostlySource(request.item) {
                // once everything cheaper has been shown
                request.triedCheapSources = true
                deferred.append(request)
            } else {
                missing.insert(request.key)
            }
        } catch is CancellationError {
        } catch {
            // a file that could not be read may be readable another time
            let error = DeviceError(error)
            if error.endsSession {
                cancelAll()
                await onSessionEnded?(error)
            }
        }
    }

    /// The first two sources. Returns nil when neither gives a picture.
    private func cheapPicture(for request: Request) async throws -> CGImage? {
        let item = request.item

        if Self.isJPEG(item) {
            let length = Int(min(item.size, Int64(Self.headerLength)))
            do {
                let header = try await backend.read(storage: request.storage, path: item.path, offset: 0, length: length)
                let isWholeFile = Int64(header.count) >= item.size
                let found = await Task.detached { Self.picture(fromJPEGHeader: header, isWholeFile: isWholeFile) }.value
                if let image = found.image { return image }
                request.orientation = found.orientation
            } catch {
                // a phone that cannot send parts of files may still have a picture of its own
                if DeviceError(error).endsSession { throw error }
            }
            guard request.isWanted else { return nil }
        }

        guard item.hasThumbnail, let data = try await backend.thumbnail(storage: request.storage, path: item.path) else { return nil }
        let orientation = request.orientation
        return await Task.detached { Self.picture(fromThumbnail: data, orientation: orientation) }.value
    }

    /// The first frame of a video, or the picture of a whole small file.
    private func costlyPicture(for request: Request) async throws -> CGImage? {
        let item = request.item
        if VideoFrame.canRead(item) {
            let backend = backend, storage = request.storage, path = item.path
            return try await VideoFrame.picture(ofVideoNamed: item.name, size: item.size, maxPixelSize: Self.maxPixelSize) { offset, length in
                try await backend.read(storage: storage, path: path, offset: offset, length: length)
            }
        }
        let url = try await files.fetch(item, storage: request.storage, urgent: false)
        return await Self.picture(ofFileAt: url)
    }

    private func deliver(_ image: NSImage, to request: Request) {
        // what the picture takes up once drawn
        images.setObject(image, forKey: request.key as NSString, cost: Int(image.size.width * image.size.height) * 4)
        for waiter in request.waiters where !waiter.ticket.isCancelled {
            waiter.completion(image)
        }
        request.waiters = []
    }

    // MARK: Making pictures

    /// The longest side of the pictures, in pixels.
    nonisolated static let maxPixelSize = 256

    /// The picture embedded in a JPEG's EXIF data, turned upright, from the
    /// file's first bytes. Also returns how the photo is to be turned, for
    /// a picture that comes from elsewhere.
    nonisolated static func picture(fromJPEGHeader data: Data, isWholeFile: Bool) -> (image: CGImage?, orientation: CGImagePropertyOrientation) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return (nil, .up) }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up

        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            // a picture made from part of a photo would be cut off
            kCGImageSourceCreateThumbnailFromImageIfAbsent: isWholeFile,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
        return (image, orientation)
    }

    /// A picture sent by the phone, turned upright.
    nonisolated static func picture(fromThumbnail data: Data, orientation: CGImagePropertyOrientation) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary)
        else { return nil }
        guard orientation != .up else { return image }

        // the phone's picture is stored the way the photo is, so it needs the photo's turn
        let turned = CIImage(cgImage: image).oriented(orientation)
        return CIContext().createCGImage(turned, from: turned.extent)
    }

    /// A picture of a file on the Mac, as Finder would draw it.
    nonisolated static func picture(ofFileAt url: URL) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: maxPixelSize / 2, height: maxPixelSize / 2), scale: 2, representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}
