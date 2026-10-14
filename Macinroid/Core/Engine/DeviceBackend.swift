import Foundation

/// The operations Macinroid needs from an MTP device.
///
/// A backend drives a single device session; callers issue one request at a
/// time. `cancelTransfer` is the exception and may be called at any moment.
protocol DeviceBackend: Sendable {
    /// Opens a session with the connected device.
    func connect() async throws -> DeviceInfo

    /// Closes the session. Safe to call when none is open.
    func disconnect() async

    func storages() async throws -> [StorageInfo]

    func list(storage: UInt32, path: String, includeHidden: Bool) async throws -> [FileItem]

    /// Creates the folder, including missing parents.
    func makeDirectory(storage: UInt32, path: String) async throws

    /// Answers, for every path, whether an item exists there. When the device
    /// cannot tell, the answer is `true`, so that nothing is overwritten unasked.
    func exists(storage: UInt32, paths: [String]) async throws -> [Bool]

    /// Deletes files and folders; folders are deleted with their contents.
    func delete(storage: UInt32, paths: [String]) async throws

    func rename(storage: UInt32, path: String, newName: String) async throws

    /// Copies files between the Mac and the device. The stream finishes when
    /// the transfer is done and throws a `DeviceError` when it fails or is cancelled.
    func transfer(_ request: TransferRequest) -> AsyncThrowingStream<TransferEvent, any Error>

    func cancelTransfer(id: UInt64)

    /// A protocol trace of connecting to the device, for problem reports.
    /// The session must be closed while this runs.
    func debugReport() async -> String
}
