import AVFoundation

/// A picture of a video on the phone, made from a few of its bytes.
///
/// Decoding a video's first frame takes the index of its samples, which
/// phones write at the end of the file, and the frame itself, which is near
/// the start. Only those are read. They are put in place in an otherwise
/// empty copy of the file, which is mostly holes and takes up no room, and
/// the frame is decoded from there.
enum VideoFrame {
    typealias Read = @Sendable (_ offset: Int64, _ length: Int) async throws -> Data

    /// The kinds of video whose index can be found this way: MPEG-4 and QuickTime.
    static func canRead(_ item: FileItem) -> Bool {
        ["mp4", "m4v", "mov", "3gp", "3g2"].contains(item.pathExtension)
    }

    /// How much of the start is read to find where the index is.
    private static let headLength = 64 << 10
    /// Larger indexes and frames are not worth reading for a picture.
    private static let indexLimit = 16 << 20
    private static let frameLimit = 8 << 20

    static func picture(ofVideoNamed name: String, size: Int64, maxPixelSize: Int, read: Read) async throws -> CGImage? {
        let head = try await read(0, Int(min(size, Int64(headLength))))

        // the index, a top-level box called moov
        guard let index = try await findTopLevelBox("moov", in: head, fileSize: size, read: read),
              index.length <= Int64(indexLimit)
        else { return nil }
        let indexData = index.offset + index.length <= Int64(head.count)
            ? head.subdata(in: Int(index.offset)..<Int(index.offset + index.length))
            : try await read(index.offset, Int(index.length))

        // the first frame of the video track
        guard let frame = firstVideoSample(inMovieBox: [UInt8](indexData)),
              frame.length > 0, frame.length <= frameLimit, frame.offset + Int64(frame.length) <= size
        else { return nil }
        let frameData = try await read(frame.offset, frame.length)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Macinroid/Frames/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: UInt64(size))
        for (offset, data) in [(Int64(0), head), (index.offset, indexData), (frame.offset, frameData)] {
            try writer.seek(toOffset: UInt64(offset))
            try writer.write(contentsOf: data)
        }
        try writer.close()

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // the first frame, which is the one that was read
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? await generator.image(at: .zero).image
    }

    // MARK: Boxes

    /// Walks the boxes at the top of the file, reading the header of each
    /// one that lies beyond `head`, and returns where the box of `type` is.
    private static func findTopLevelBox(_ type: String, in head: Data, fileSize: Int64, read: Read) async throws -> (offset: Int64, length: Int64)? {
        var offset: Int64 = 0
        for _ in 0..<64 {
            guard offset + 8 <= fileSize else { return nil }
            let header = offset + 16 <= Int64(head.count)
                ? [UInt8](head.subdata(in: Int(offset)..<Int(offset) + 16))
                : [UInt8](try await read(offset, 16))
            guard header.count >= 8 else { return nil }

            var length = Int64(be32(header, 0))
            if length == 1 {
                guard header.count >= 16 else { return nil }
                length = Int64(bitPattern: be64(header, 8))
            } else if length == 0 {
                length = fileSize - offset
            }
            guard length >= 8 else { return nil }

            if fourCC(header, 4) == type { return (offset, length) }
            offset += length
        }
        return nil
    }

    /// Where the first sample of the video track is, from the movie box.
    static func firstVideoSample(inMovieBox moov: [UInt8]) -> (offset: Int64, length: Int)? {
        for track in children(of: moov, in: range(ofBox: moov, at: 0)).filter({ $0.type == "trak" }) {
            guard let media = child("mdia", of: moov, in: track.payload),
                  let handler = child("hdlr", of: moov, in: media.payload),
                  handler.payload.count >= 12, fourCC(moov, handler.payload.lowerBound + 8) == "vide",
                  let information = child("minf", of: moov, in: media.payload),
                  let table = child("stbl", of: moov, in: information.payload),
                  let sizes = child("stsz", of: moov, in: table.payload), sizes.payload.count >= 12
            else { continue }

            // the first chunk's offset, in 32 or 64 bits
            let firstChunk: Int64
            if let offsets = child("stco", of: moov, in: table.payload), offsets.payload.count >= 12, be32(moov, offsets.payload.lowerBound + 4) > 0 {
                firstChunk = Int64(be32(moov, offsets.payload.lowerBound + 8))
            } else if let offsets = child("co64", of: moov, in: table.payload), offsets.payload.count >= 16, be32(moov, offsets.payload.lowerBound + 4) > 0 {
                firstChunk = Int64(bitPattern: be64(moov, offsets.payload.lowerBound + 8))
            } else {
                continue
            }

            // the first sample's size: the same for all, or the first entry of the table
            let start = sizes.payload.lowerBound
            let common = be32(moov, start + 4)
            guard be32(moov, start + 8) > 0 else { continue }
            if common > 0 { return (firstChunk, Int(common)) }
            guard sizes.payload.count >= 16 else { continue }
            return (firstChunk, Int(be32(moov, start + 12)))
        }
        return nil
    }

    private struct Box {
        var type: String
        var payload: Range<Int>
    }

    /// The payload of the box that starts at `offset`.
    private static func range(ofBox bytes: [UInt8], at offset: Int) -> Range<Int> {
        guard bytes.count >= offset + 8 else { return 0..<0 }
        let length = min(Int(be32(bytes, offset)), bytes.count - offset)
        return (offset + 8)..<(offset + max(8, length))
    }

    private static func children(of bytes: [UInt8], in range: Range<Int>) -> [Box] {
        var boxes: [Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var length = Int(be32(bytes, offset))
            var headerLength = 8
            if length == 1, offset + 16 <= range.upperBound {
                length = Int(clamping: be64(bytes, offset + 8))
                headerLength = 16
            } else if length == 0 {
                length = range.upperBound - offset
            }
            guard length >= headerLength, offset + length <= range.upperBound else { break }
            boxes.append(Box(type: fourCC(bytes, offset + 4), payload: (offset + headerLength)..<(offset + length)))
            offset += length
        }
        return boxes
    }

    private static func child(_ type: String, of bytes: [UInt8], in range: Range<Int>) -> Box? {
        children(of: bytes, in: range).first { $0.type == type }
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func be64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        guard offset + 8 <= bytes.count else { return 0 }
        return bytes[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func fourCC(_ bytes: [UInt8], _ offset: Int) -> String {
        guard offset + 4 <= bytes.count else { return "" }
        return String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
    }
}
