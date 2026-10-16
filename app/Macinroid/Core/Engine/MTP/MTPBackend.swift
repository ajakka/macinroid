import Foundation
import os

/// Talks to a phone with Macinroid's own MTP engine, written in Swift on top
/// of the system's USB framework.
///
/// MTP allows one request at a time and every request blocks until the device
/// has answered, so all of them run on one serial queue.
final class MTPBackend: DeviceBackend, @unchecked Sendable {
    /// Finds the device and opens the connection that MTP runs over.
    typealias Connector = @Sendable () throws -> any MTPTransport

    private let connector: Connector
    private let queue = DispatchQueue(label: "com.anyfikra.macinroid.mtp", qos: .userInitiated)
    private let cancelledTransfers = OSAllocatedUnfairLock(initialState: Set<UInt64>())

    /// The open connection. Only touched on `queue`.
    private var connection: Connection?

    private struct Connection {
        var transport: any MTPTransport
        var session: MTPSession
        var files: MTPFileSystem
    }

    init(connector: @escaping Connector = MTPBackend.connectOverUSB) {
        self.connector = connector
    }

    // MARK: DeviceBackend

    func connect() async throws -> DeviceInfo {
        try await run { [self] in
            closeConnection()

            let transport: any MTPTransport
            do {
                transport = try connector()
            } catch {
                throw Self.connectionError(error)
            }

            var session = MTPSession(transport: transport)
            let info: MTPDeviceInfo
            do {
                info = try session.getDeviceInfo()
            } catch {
                transport.close()
                throw DeviceError(code: .deviceInfo, detail: "\(error)")
            }

            do {
                try session.open()
            } catch {
                // A device that will not open a session is reset and given a second chance.
                Log.error("mtp: opening a session failed (\(error)); resetting the device")
                transport.resetDevice()
                Thread.sleep(forTimeInterval: 1)
                do {
                    let fresh = try connector()
                    session = MTPSession(transport: fresh)
                    try session.open()
                } catch {
                    session.transport.close()
                    throw DeviceError(code: .deviceSetup, detail: "\(error)")
                }
            }

            connection = Connection(transport: session.transport, session: session, files: MTPFileSystem(session: session))
            return Self.deviceInfo(info, usb: session.transport.identity)
        }
    }

    func disconnect() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closeConnection()
                continuation.resume()
            }
        }
    }

    func storages() async throws -> [StorageInfo] {
        try await perform { try $0.storages() }
    }

    func list(storage: UInt32, path: String, includeHidden: Bool) async throws -> [FileItem] {
        try await perform { try $0.list(storage: storage, path: path, includeHidden: includeHidden).map(\.fileItem) }
    }

    func makeDirectory(storage: UInt32, path: String) async throws {
        _ = try await perform { try $0.makeDirectory(storage: storage, path: path) }
    }

    func exists(storage: UInt32, paths: [String]) async throws -> [Bool] {
        try await perform { try $0.exists(storage: storage, paths: paths) }
    }

    func delete(storage: UInt32, paths: [String]) async throws {
        try await perform { try $0.delete(storage: storage, paths: paths) }
    }

    func rename(storage: UInt32, path: String, newName: String) async throws {
        try await perform { try $0.rename(storage: storage, path: path, newName: newName) }
    }

    func thumbnail(storage: UInt32, path: String) async throws -> Data? {
        try await perform { try $0.thumbnail(storage: storage, path: path) }
    }

    func read(storage: UInt32, path: String, offset: Int64, length: Int) async throws -> Data {
        try await perform { try $0.read(storage: storage, path: path, offset: offset, length: length) }
    }

    func transfer(_ request: TransferRequest) -> AsyncThrowingStream<TransferEvent, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            queue.async { [self] in
                defer { cancelledTransfers.withLock { _ = $0.remove(request.id) } }

                let hooks = MTPTransferHooks(
                    isCancelled: { [cancelledTransfers] in cancelledTransfers.withLock { $0.contains(request.id) } },
                    emit: { continuation.yield($0) }
                )
                do {
                    try withFiles { files in
                        switch request.direction {
                        case .upload: try files.upload(request, hooks: hooks)
                        case .download: try files.download(request, hooks: hooks)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func cancelTransfer(id: UInt64) {
        cancelledTransfers.withLock { _ = $0.insert(id) }
    }

    func debugReport() async -> String {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: makeDebugReport())
            }
        }
    }

    // MARK: Running requests

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable (MTPFileSystem) throws -> T) async throws -> T {
        try await run { [self] in try withFiles(body) }
    }

    /// Runs a request against the open connection, and closes the connection
    /// if the request leaves it unusable.
    private func withFiles<T>(_ body: (MTPFileSystem) throws -> T) throws -> T {
        guard let connection else { throw DeviceError.notConnected }
        connection.files.beginOperation()

        do {
            return try body(connection.files)
        } catch {
            var failure = DeviceError(error)
            if connection.session.isBroken || failure.sessionReset {
                failure.sessionReset = true
                closeConnection()
            }
            if !failure.isCancellation {
                Log.error("mtp: \(failure.code.rawValue): \(failure.detail)")
            }
            throw failure
        }
    }

    private func closeConnection() {
        guard let connection else { return }
        connection.session.close()
        connection.transport.close()
        self.connection = nil
    }

    // MARK: Finding the device

    /// Opens the one MTP device on the bus.
    static func connectOverUSB() throws -> any MTPTransport {
        do {
            return try findAndOpen()
        } catch MTPError.noDevice {
            // a phone that macOS has not configured shows no interfaces; libusb
            // configures such a device itself, and so does this
            let log = USBDeviceScan.configureUnconfiguredMTPDevices()
            log.forEach { Log.info("usb: \($0)") }
            guard log.contains(where: { $0.contains("selected configuration") }) else { throw MTPError.noDevice }

            // the interfaces appear a moment after the configuration is selected
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.1)
                if let transport = try? findAndOpen() { return transport }
            }
            return try findAndOpen()
        }
    }

    private static func findAndOpen() throws -> any MTPTransport {
        let candidates = USBInterfaceCandidate.all()
        defer { candidates.forEach { $0.release() } }

        var devices = candidates.filter(\.isNamedForMTP)
        var blocked: MTPTransportError?

        // The registry does not always carry the interface's name, so an
        // interface that may speak MTP is opened and asked: first for its
        // name, as libusb-based tools do, then for its MTP extensions.
        for candidate in candidates where candidate.needsProbing {
            let transport: USBTransport
            do {
                transport = try USBTransport(candidate)
            } catch let error as MTPTransportError {
                if error.kind == .inUse { blocked = error }
                continue
            } catch {
                continue
            }
            defer { transport.close() }

            if let name = transport.interfaceName(), ["MTP", "CDC", "ACM"].contains(where: name.contains) {
                devices.append(candidate)
            } else if let info = try? MTPSession(transport: transport).getDeviceInfo(), isMTP(info.mtpExtension) {
                devices.append(candidate)
            }
        }

        guard let device = devices.first else {
            // a phone that something else holds is not the same as no phone
            if let blocked { throw MTPError.transport(blocked) }
            throw MTPError.noDevice
        }
        guard devices.count == 1 else {
            throw MTPError.multipleDevices(devices.map { $0.identity.product.isEmpty ? "USB device" : $0.identity.product })
        }
        return try USBTransport(device)
    }

    /// Whether a device's extensions show that it speaks MTP, not just PTP.
    private static func isMTP(_ extensions: String) -> Bool {
        ["microsoft.com", "android.com", "microsoft/WindowsPhone", "fujifilm.co.jp"].contains { extensions.contains($0) }
    }

    private static func connectionError(_ error: any Error) -> DeviceError {
        if let error = error as? DeviceError { return error }

        switch error {
        case MTPError.noDevice:
            return DeviceError(code: .mtpDetectFailed, detail: "no MTP devices found")
        case MTPError.multipleDevices:
            return DeviceError(code: .multipleDevice, detail: "\(error)")
        default:
            return DeviceError(code: .deviceSetup, detail: "\(error)")
        }
    }

    private static func deviceInfo(_ info: MTPDeviceInfo, usb: DeviceInfo.USB) -> DeviceInfo {
        DeviceInfo(
            mtp: .init(
                manufacturer: info.manufacturer,
                model: info.model,
                deviceVersion: info.deviceVersion,
                serialNumber: info.serialNumber,
                standardVersion: Int(info.standardVersion),
                mtpVersion: Int(info.mtpVersion),
                mtpExtension: info.mtpExtension,
                vendorExtensionId: Int(info.vendorExtensionID),
                functionalMode: Int(info.functionalMode)
            ),
            usb: usb
        )
    }

    // MARK: Problem reports

    /// Connects with every request and answer written down, to show where it goes wrong.
    private func makeDebugReport() -> String {
        closeConnection()
        var lines: [String] = []

        let devices = USBDeviceScan.devices()
        lines.append("USB devices: \(devices.count)")
        devices.forEach { lines.append("  \($0)") }

        let candidates = USBInterfaceCandidate.all()
        lines.append("USB interfaces with three endpoints: \(candidates.count)")
        for candidate in candidates {
            lines.append("  \(candidate)\(candidate.isNamedForMTP ? "  <- MTP" : candidate.needsProbing ? "  (to be asked what it is)" : "")")
        }
        candidates.forEach { $0.release() }

        do {
            let transport = try connector()
            defer { transport.close() }
            lines.append("opened; packet sizes in \(transport.inPacketSize), out \(transport.outPacketSize)")

            let session = MTPSession(transport: transport)
            session.trace = { lines.append("  " + $0) }

            let info = try session.getDeviceInfo()
            lines.append("device: \(info.manufacturer) \(info.model), version \(info.deviceVersion), MTP \(info.mtpVersion), extensions \(info.mtpExtension)")
            lines.append("operations: \(info.operationsSupported.map { String(format: "%04X", $0) }.joined(separator: " "))")

            try session.open()
            for storage in try MTPFileSystem(session: session).storages() {
                lines.append("storage \(String(format: "0x%08X", storage.id)): \(storage.displayName), \(storage.freeSpace) of \(storage.capacity) bytes free")
            }
            session.close()
        } catch {
            lines.append("failed: \(error)")
        }
        return lines.joined(separator: "\n")
    }
}
