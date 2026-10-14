import Foundation

/// A problem on the connection that carries the MTP conversation.
struct MTPTransportError: Error, CustomStringConvertible {
    enum Kind: Equatable {
        /// The device did not answer in time.
        case timeout
        /// The device is no longer there.
        case disconnected
        /// Another program has the device to itself.
        case inUse
        /// The device refused the transfer; the pipe has to be cleared.
        case stalled
        case other
    }

    var kind: Kind
    var detail: String

    var description: String { detail }
}

/// The pipes an MTP conversation runs over: bulk out for commands and data,
/// bulk in for data and responses, and the class-specific control requests.
///
/// The USB implementation is `USBTransport`; tests supply a simulated device.
protocol MTPTransport: AnyObject {
    /// What USB reports about the device.
    var identity: DeviceInfo.USB { get }

    /// The largest packet of each bulk endpoint. A transfer that ends on a
    /// packet of exactly this size has to be closed with an empty packet.
    var inPacketSize: Int { get }
    var outPacketSize: Int { get }

    /// Sends the bytes as one bulk transfer. Empty data sends a zero-length packet.
    func write(_ data: Data, timeout: TimeInterval) throws

    /// Receives one bulk transfer: it ends when `capacity` bytes have arrived
    /// or the device sends a short packet. Returns what was received, which is
    /// empty for a zero-length packet.
    func read(capacity: Int, timeout: TimeInterval) throws -> Data

    /// The class request that tells the device to abandon a transaction.
    func cancelRequest(transactionID: UInt32) throws

    /// The class request that asks whether the device is ready for the next transaction.
    func deviceStatus() throws -> MTPResponseCode

    /// Clears a refused (stalled) bulk pipe on both ends.
    func clearStalls()

    /// Resets the device on the bus, as a last resort. The transport is
    /// unusable afterwards.
    func resetDevice()

    func close()
}
