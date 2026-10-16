import Foundation

/// A problem with the bytes of an MTP dataset.
enum MTPCodingError: Error, Equatable {
    /// The data ends before the value does.
    case truncated
    /// MTP strings hold at most 254 UTF-16 code units.
    case stringTooLong
}

/// Reads the little-endian values MTP datasets are made of.
struct MTPReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var isAtEnd: Bool { offset >= bytes.count }
    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw MTPCodingError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        try integer()
    }

    mutating func u32() throws -> UInt32 {
        try integer()
    }

    mutating func u64() throws -> UInt64 {
        try integer()
    }

    private mutating func integer<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw MTPCodingError.truncated }
        defer { offset += size }

        var value: T = 0
        for index in 0..<size {
            value |= T(bytes[offset + index]) << T(8 * index)
        }
        return value
    }

    /// A string: a count of UTF-16 code units, including the terminating
    /// null, followed by the units. A count of zero is the empty string.
    mutating func string() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        guard remaining >= 2 * count else { throw MTPCodingError.truncated }

        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count {
            units.append(try u16())
        }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// An array: a 32-bit count followed by the elements.
    mutating func array16() throws -> [UInt16] {
        let count = Int(try u32())
        guard remaining >= 2 * count else { throw MTPCodingError.truncated }
        return try (0..<count).map { _ in try u16() }
    }

    mutating func array32() throws -> [UInt32] {
        let count = Int(try u32())
        guard remaining >= 4 * count else { throw MTPCodingError.truncated }
        return try (0..<count).map { _ in try u32() }
    }

    /// A date and time, sent as a string. Returns nil when it is empty or not understood.
    mutating func date() throws -> Date? {
        MTPDate.parse(try string())
    }
}

/// Builds MTP datasets.
struct MTPWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    mutating func u16(_ value: UInt16) {
        integer(value)
    }

    mutating func u32(_ value: UInt32) {
        integer(value)
    }

    mutating func u64(_ value: UInt64) {
        integer(value)
    }

    private mutating func integer<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func string(_ value: String) throws {
        guard !value.isEmpty else {
            u8(0)
            return
        }
        let units = Array(value.utf16)
        guard units.count <= 254 else { throw MTPCodingError.stringTooLong }

        u8(UInt8(units.count + 1))
        units.forEach { u16($0) }
        u16(0)
    }

    mutating func date(_ value: Date?) throws {
        try string(value.map(MTPDate.format) ?? "")
    }
}

/// MTP's date-time strings: `YYYYMMDDThhmmss`, optionally followed by tenths
/// of a second and by `Z` or `±hhmm`.
///
/// Without a zone the time is the device's local time. Macinroid reads that as
/// the Mac's local time, which is right when both are in the same time zone.
enum MTPDate {
    static func parse(_ text: String) -> Date? {
        // Samsung pads the string with dots
        var text = text.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard text.count >= 15 else { return nil }

        var timeZone = TimeZone.current
        if text.hasSuffix("Z") {
            timeZone = .gmt
            text.removeLast()
        } else if text.count >= 20, let sign = text.dropLast(4).last, sign == "+" || sign == "-" {
            let digits = text.suffix(4)
            guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else { return nil }
            let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
            guard let zone = TimeZone(secondsFromGMT: seconds) else { return nil }
            timeZone = zone
            text.removeLast(5)
        }

        let characters = Array(text)
        guard characters.count >= 15, characters[8] == "T" else { return nil }
        func number(_ range: Range<Int>) -> Int? { Int(String(characters[range])) }

        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15)
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }

    /// The device's local time, without a zone, as Android itself writes it.
    static func format(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }
}
