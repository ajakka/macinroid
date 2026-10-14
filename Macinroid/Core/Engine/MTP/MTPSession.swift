import Foundation

/// An MTP conversation with one device: commands, data and responses, in the
/// framing MTP uses over USB.
///
/// Every transaction is a command container, optionally a data phase in one
/// direction, and a response container. All calls block and must come from
/// one thread at a time.
///
/// The handling of transactions — when a data phase continues, when an empty
/// packet is due, how a header sent by itself is recognised — follows
/// go-mtpfs (© 2012 Google Inc., BSD licence; see THIRD-PARTY-NOTICES.md),
/// whose behaviour with real phones is what OpenMTP relies on.
final class MTPSession {
    struct Response {
        var code: MTPResponseCode
        var parameters: [UInt32]
    }

    /// Reports how many bytes of an object have gone over the wire so far.
    /// Throwing stops the transfer.
    typealias Progress = (Int64) throws -> Void

    /// The data phase of a transaction that sends data to the device.
    struct Outgoing {
        var size: Int64
        /// Returns up to the given number of bytes; fewer only at the end.
        var read: (Int) throws -> Data

        init(size: Int64, read: @escaping (Int) throws -> Data) {
            self.size = size
            self.read = read
        }

        init(_ data: Data) {
            var remaining = data
            self.init(size: Int64(data.count)) { count in
                let chunk = remaining.prefix(count)
                remaining = remaining.dropFirst(chunk.count)
                return Data(chunk)
            }
        }
    }

    let transport: any MTPTransport

    /// How long the device gets to answer.
    var timeout: TimeInterval = 15

    /// Receives a line for every request and response, for problem reports.
    var trace: ((String) -> Void)?

    /// Set once the two sides are out of step; the connection has to be made anew.
    private(set) var isBroken = false

    private var sessionID: UInt32?
    private var nextTransactionID: UInt32 = 0
    private var currentTransactionID: UInt32 = 0
    /// Some devices want the header of a data phase in a packet of its own.
    private var usesSeparateHeader = false

    private enum ContainerType {
        static let command: UInt16 = 1
        static let data: UInt16 = 2
        static let response: UInt16 = 3
    }

    private static let headerLength = 12
    /// How much is handed to USB at once. Whole multiples of every packet size.
    private static let chunkSize = 256 << 10

    init(transport: any MTPTransport) {
        self.transport = transport
    }

    var isOpen: Bool { sessionID != nil }

    // MARK: Operations

    func getDeviceInfo() throws -> MTPDeviceInfo {
        try MTPDeviceInfo(decoding: receive(.getDeviceInfo))
    }

    /// Opens a session, which every request about storage needs. A session
    /// that an earlier connection left open is closed first.
    func open() throws {
        do {
            try openSession()
        } catch let error as MTPError where error.responseCode == .sessionAlreadyOpen {
            // closing works without a transaction id, at least on Android
            try? closeSession()
            try openSession()
        }
    }

    private func openSession() throws {
        guard sessionID == nil else { throw MTPError.protocolViolation("session already open") }

        // neither 0 nor 0xFFFFFFFF may be used as a session id
        let id = UInt32.random(in: 1..<0x7FFF_FFFF) | 1
        _ = try run(.openSession, [id])
        sessionID = id
        nextTransactionID = 1
    }

    func closeSession() throws {
        defer { sessionID = nil }
        _ = try run(.closeSession)
    }

    func getStorageIDs() throws -> [UInt32] {
        var reader = MTPReader(try receive(.getStorageIDs))
        return try reader.array32()
    }

    func getStorageInfo(_ storage: UInt32) throws -> MTPStorageInfo {
        try MTPStorageInfo(decoding: receive(.getStorageInfo, [storage]))
    }

    /// The handles of the objects directly inside `parent`.
    func getObjectHandles(storage: UInt32, parent: UInt32) throws -> [UInt32] {
        var reader = MTPReader(try receive(.getObjectHandles, [storage, MTPHandle.allFormats, parent]))
        return try reader.array32()
    }

    func getObjectInfo(_ handle: UInt32) throws -> MTPObjectInfo {
        try MTPObjectInfo(decoding: receive(.getObjectInfo, [handle]))
    }

    func getObjectFileName(_ handle: UInt32) throws -> String {
        var reader = MTPReader(try receive(.getObjectPropValue, [handle, UInt32(MTPObjectProperty.objectFileName)]))
        return try reader.string()
    }

    /// The size of an object that is too large for the size field of its description.
    func getObjectSize(_ handle: UInt32) throws -> UInt64 {
        var reader = MTPReader(try receive(.getObjectPropValue, [handle, UInt32(MTPObjectProperty.objectSize)]))
        return try reader.u64()
    }

    func setObjectFileName(_ handle: UInt32, to name: String) throws {
        var writer = MTPWriter()
        try writer.string(name)
        _ = try run(.setObjectPropValue, [handle, UInt32(MTPObjectProperty.objectFileName)], send: Outgoing(writer.data))
    }

    func deleteObject(_ handle: UInt32) throws {
        _ = try run(.deleteObject, [handle, 0])
    }

    /// Announces an object that is about to be sent, or creates a folder.
    /// Returns the handle the device gave it.
    func sendObjectInfo(storage: UInt32, parent: UInt32, info: MTPObjectInfo) throws -> UInt32 {
        let response = try run(.sendObjectInfo, [storage, parent], send: Outgoing(info.encoded()))
        guard response.parameters.count >= 3 else {
            throw MTPError.protocolViolation("SendObjectInfo: need 3 response parameters, got \(response.parameters.count)")
        }
        return response.parameters[2]
    }

    /// Sends the contents of the object announced by the last `sendObjectInfo`.
    func sendObject(_ source: Outgoing, progress: Progress? = nil) throws {
        _ = try run(.sendObject, send: source, progress: progress)
    }

    /// Fetches the contents of an object, handing them to `sink` piece by piece.
    func getObject(_ handle: UInt32, into sink: @escaping (Data) throws -> Void, progress: Progress? = nil) throws {
        _ = try run(.getObject, [handle], receive: sink, progress: progress)
    }

    private func receive(_ operation: MTPOperation, _ parameters: [UInt32] = []) throws -> Data {
        var received = Data()
        _ = try run(operation, parameters, receive: { received.append($0) })
        return received
    }

    // MARK: Transactions

    /// Runs one transaction. `send` and `receive` cannot both be given.
    ///
    /// A failure that leaves the two sides out of step, such as a USB error
    /// or an answer that belongs to another transaction, marks the session
    /// as broken.
    func run(
        _ operation: MTPOperation,
        _ parameters: [UInt32] = [],
        send: Outgoing? = nil,
        receive: ((Data) throws -> Void)? = nil,
        progress: Progress? = nil
    ) throws -> Response {
        guard !isBroken else {
            throw MTPError.transport(.init(kind: .disconnected, detail: "the connection to the device is closed"))
        }

        do {
            return try transact(operation, parameters, send: send, receive: receive, progress: progress)
        } catch let error as MTPTransportError {
            trace?("\(operation): \(error.detail)")
            isBroken = true
            throw MTPError.transport(error)
        } catch let error as MTPError {
            trace?("\(operation): \(error)")
            if case .protocolViolation = error { isBroken = true }
            throw error
        }
    }

    private func transact(
        _ operation: MTPOperation,
        _ parameters: [UInt32],
        send: Outgoing?,
        receive: ((Data) throws -> Void)?,
        progress: Progress?
    ) throws -> Response {
        var transactionID: UInt32 = 0
        if sessionID != nil {
            transactionID = nextTransactionID
            nextTransactionID &+= 1
        }
        currentTransactionID = transactionID
        trace?("request \(operation) \(parameters.map { String(format: "0x%X", $0) })")

        // command
        var command = MTPWriter()
        command.u32(UInt32(Self.headerLength + 4 * parameters.count))
        command.u16(ContainerType.command)
        command.u16(operation.rawValue)
        command.u32(transactionID)
        parameters.forEach { command.u32($0) }
        try transport.write(command.data, timeout: timeout)

        // data to the device
        if let send {
            try write(send, operation: operation, transactionID: transactionID, progress: progress)
        }

        // data from the device, or straight away the response
        let packetSize = transport.inPacketSize
        var packet = try transport.read(capacity: packetSize, timeout: timeout)
        var header = try Header(packet)
        var gotUnexpectedData = false

        if header.type == ContainerType.data {
            if receive == nil {
                gotUnexpectedData = true
                trace?("discarding 0x\(String(header.length, radix: 16)) bytes of unexpected data")
            }
            let sink = receive ?? { _ in }
            let payload = packet.dropFirst(Self.headerLength)
            try sink(Data(payload))
            var received = Int64(payload.count)
            try progress?(received)

            var finalPacket = Data()
            if packet.count == packetSize || UInt32(packet.count) < header.length {
                // A device may send the 12 bytes of the header by themselves
                // and expects the same of the host from then on.
                if packet.count == Self.headerLength, UInt32(packet.count) < header.length {
                    usesSeparateHeader = true
                    trace?("the device sends headers separately; doing the same")
                }
                finalPacket = try readData(into: sink, received: &received, progress: progress)
            }

            // the response follows; it may have arrived in place of the empty
            // packet that ends the data
            packet = finalPacket.isEmpty ? try transport.read(capacity: packetSize, timeout: timeout) : finalPacket
            header = try Header(packet)
        }

        guard header.type == ContainerType.response else {
            throw MTPError.protocolViolation("got a container of type \(header.type) where a response was expected")
        }

        let body = [UInt8](packet.dropFirst(Self.headerLength))
        let parameterCount = min((Int(header.length) - Self.headerLength) / 4, body.count / 4)
        let responseParameters = (0..<max(0, parameterCount)).map { index in
            UInt32(body[4 * index]) | UInt32(body[4 * index + 1]) << 8 | UInt32(body[4 * index + 2]) << 16 | UInt32(body[4 * index + 3]) << 24
        }
        let code = MTPResponseCode(rawValue: header.code)
        trace?("response \(code) \(responseParameters.map { String(format: "0x%X", $0) })")

        if gotUnexpectedData {
            throw MTPError.protocolViolation("unexpected data for \(operation)")
        }
        guard code == .ok else {
            throw MTPError.response(code, during: "\(operation)")
        }
        if sessionID != nil, header.transactionID != transactionID {
            throw MTPError.protocolViolation("the response belongs to transaction \(header.transactionID), not \(transactionID)")
        }
        return Response(code: code, parameters: responseParameters)
    }

    /// The data phase towards the device: a header, then the bytes.
    private func write(_ source: Outgoing, operation: MTPOperation, transactionID: UInt32, progress: Progress?) throws {
        let packetSize = transport.outPacketSize
        let total = source.size

        var header = MTPWriter()
        // an object too large for the length field is announced as 0xFFFFFFFF
        header.u32(UInt32(clamping: total + Int64(Self.headerLength)))
        header.u16(ContainerType.data)
        header.u16(operation.rawValue)
        header.u32(transactionID)

        // The first packet carries the header and as much data as fits next to it.
        var first = header.data
        var sent: Int64 = 0
        if !usesSeparateHeader {
            let room = Int(min(Int64(packetSize - Self.headerLength), total))
            if room > 0 {
                let chunk = try source.read(room)
                first.append(chunk)
                sent += Int64(chunk.count)
            }
        }
        try transport.write(first, timeout: timeout)
        try progress?(sent)

        var lastTransfer = 0
        while sent < total {
            let chunk = try source.read(Int(min(Int64(Self.chunkSize), total - sent)))
            guard !chunk.isEmpty else {
                throw MTPError.protocolViolation("the data ended after \(sent) of \(total) bytes")
            }
            try transport.write(chunk, timeout: timeout)
            lastTransfer = chunk.count
            sent += Int64(chunk.count)
            try progress?(sent)
        }

        if lastTransfer % packetSize == 0 {
            // tells the device that the data is complete; not every device waits for it
            try? transport.write(Data(), timeout: 0.25)
        }
    }

    /// The rest of a data phase from the device. Returns the packet that
    /// arrived after the data when that already is the response.
    private func readData(into sink: (Data) throws -> Void, received: inout Int64, progress: Progress?) throws -> Data {
        var lastRead = 0
        while true {
            let chunk = try transport.read(capacity: Self.chunkSize, timeout: timeout)
            lastRead = chunk.count
            if !chunk.isEmpty {
                try sink(chunk)
                received += Int64(chunk.count)
            }
            try progress?(received)
            // a transfer that stops short of the buffer ends the data
            if chunk.count < Self.chunkSize { break }
        }

        if lastRead % transport.inPacketSize == 0 {
            // The data ended on a full packet, so an empty one follows — unless
            // the host controller has swallowed it, in which case this is the response.
            return try transport.read(capacity: Self.chunkSize, timeout: timeout)
        }
        return Data()
    }

    private struct Header {
        var length: UInt32
        var type: UInt16
        var code: UInt16
        var transactionID: UInt32

        init(_ packet: Data) throws {
            guard packet.count >= MTPSession.headerLength else {
                throw MTPError.protocolViolation("a container of \(packet.count) bytes is too short")
            }
            var reader = MTPReader(packet.prefix(MTPSession.headerLength))
            length = try reader.u32()
            type = try reader.u16()
            code = try reader.u16()
            transactionID = try reader.u32()
        }
    }

    // MARK: Stopping a transfer

    /// Abandons the transaction in progress, after a data phase was cut short,
    /// and tries to get both sides back in step.
    ///
    /// Returns whether the session can still be used. If not, it is marked as
    /// broken and the connection has to be made anew.
    func cancelCurrentTransaction() -> Bool {
        trace?("cancelling transaction \(currentTransactionID)")
        try? transport.cancelRequest(transactionID: currentTransactionID)
        transport.clearStalls()

        // swallow what the device had already queued up for the host
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, let leftover = try? transport.read(capacity: Self.chunkSize, timeout: 0.3) {
            trace?("discarded \(leftover.count) bytes")
        }

        // wait until the device is ready for the next transaction
        for _ in 0..<30 {
            if let status = try? transport.deviceStatus(), status == .ok { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        // and make sure that it really answers again
        isBroken = false
        if (try? getStorageIDs()) != nil {
            trace?("the session survived the cancellation")
            return true
        }
        isBroken = true
        return false
    }

    /// Ends the session and marks the connection as closed.
    func close() {
        if sessionID != nil, !isBroken {
            let patience = timeout
            timeout = 2
            try? closeSession()
            timeout = patience
        }
        sessionID = nil
        isBroken = true
    }
}
