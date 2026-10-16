import AppKit
import Observation

/// The connection to the phone: whether there is one, to what, and which of
/// its storages is being browsed.
@MainActor
@Observable
final class DeviceSession {
    enum State: Equatable {
        /// No phone is connected.
        case disconnected
        case connecting
        case connected(DeviceInfo)
        /// A phone is there, but it cannot be used as it is.
        case failed(DeviceError)
    }

    let backend: any DeviceBackend

    private(set) var state: State = .disconnected
    private(set) var storages: [StorageInfo] = []
    private(set) var selectedStorageID: UInt32?

    /// Whether the phone connected last is the one that was connected before it.
    private(set) var isSameDeviceAsBefore = false

    /// Apps known to grab the phone before Macinroid can.
    private(set) var conflictingApps: [NSRunningApplication] = []

    /// Called every time a session has been opened.
    @ObservationIgnored var onConnected: (@MainActor () async -> Void)?

    @ObservationIgnored private var connectTask: Task<Bool, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var lastSerialNumber: String?

    init(backend: any DeviceBackend) {
        self.backend = backend
    }

    // MARK: Derived state

    var device: DeviceInfo? {
        if case .connected(let info) = state { return info }
        return nil
    }

    var isConnected: Bool { device != nil }
    var isConnecting: Bool { state == .connecting }

    var selectedStorage: StorageInfo? {
        storages.first { $0.id == selectedStorageID }
    }

    var deviceName: String { device?.displayName ?? "Phone" }

    // MARK: Connecting

    /// Opens a session with the phone. Returns whether that worked.
    @discardableResult
    func connect() async -> Bool {
        if let connectTask {
            return await connectTask.value
        }

        let task = Task { await performConnect() }
        connectTask = task
        let connected = await task.value
        connectTask = nil
        return connected
    }

    private func performConnect() async -> Bool {
        state = .connecting

        do {
            let info = try await backend.connect()
            let storages = try await backend.storages()

            let isSameDevice = info.serialNumber == lastSerialNumber
            lastSerialNumber = info.serialNumber
            isSameDeviceAsBefore = isSameDevice

            self.storages = storages
            if !isSameDevice || !storages.contains(where: { $0.id == selectedStorageID }) {
                selectedStorageID = storages.first?.id
            }
            conflictingApps = []
            state = .connected(info)
            Log.info("connected to \(info.displayName) with \(storages.count) storage(s)")
            await onConnected?()
            return true
        } catch {
            let error = DeviceError(error)
            storages = []
            conflictingApps = Self.findConflictingApps()
            if error.code == .mtpDetectFailed {
                state = .disconnected
            } else {
                state = .failed(error)
                Log.error("connecting failed: \(error.code.rawValue) \(error.detail)")
            }
            return false
        }
    }

    /// Keeps trying for a while. A phone that was just plugged in needs a
    /// moment, and often a tap on its screen, before it answers.
    func connectPersistently(attempts: Int = 8) {
        guard retryTask == nil, !isConnected else { return }

        retryTask = Task {
            defer { retryTask = nil }
            for attempt in 0..<attempts {
                // 0.7 s, then growing to 4 s: about 20 s in all
                try? await Task.sleep(for: .milliseconds(min(700 + attempt * 500, 4000)))
                if Task.isCancelled || isConnected { return }
                if await connect() { return }
                // nothing will change by itself when several devices are plugged in
                if case .failed(let error) = state, error.code == .multipleDevice { return }
            }
        }
    }

    func stopRetrying() {
        retryTask?.cancel()
        retryTask = nil
    }

    func disconnect() async {
        stopRetrying()
        await backend.disconnect()
        storages = []
        state = .disconnected
    }

    /// Closes and reopens the session, as is needed after a cancelled transfer.
    func reconnect() async {
        await backend.disconnect()
        for attempt in 0..<6 {
            if await connect() { return }
            // the phone re-enumerates on the bus after a USB reset
            try? await Task.sleep(for: .milliseconds(600 + attempt * 400))
        }
    }

    /// Records that a request failed in a way that ended the session.
    func noteFailure(_ error: DeviceError) {
        guard error.endsSession, state != .connecting else { return }
        storages = []
        conflictingApps = Self.findConflictingApps()
        state = error.code == .mtpDetectFailed || error.code == .deviceChanged ? .disconnected : .failed(error)
        Log.info("session ended: \(error.code.rawValue)")
        Task { await backend.disconnect() }
    }

    /// Reacts to the phone having been unplugged.
    func deviceWasDetached(serialNumber: String) async {
        guard let device else { return }

        let known = device.usb.serialNumber
        if !serialNumber.isEmpty, !known.isEmpty {
            guard serialNumber == known else { return }
        } else if (try? await backend.storages()) != nil {
            // it was some other device; ours still answers
            return
        }

        stopRetrying()
        storages = []
        state = .disconnected
        await backend.disconnect()
        Log.info("device detached")
    }

    // MARK: Storages

    func selectStorage(_ id: UInt32) {
        guard storages.contains(where: { $0.id == id }) else { return }
        selectedStorageID = id
    }

    /// Updates the free space figures.
    func refreshStorages() async {
        guard isConnected else { return }
        do {
            storages = try await backend.storages()
        } catch {
            noteFailure(DeviceError(error))
        }
    }

    // MARK: Conflicting apps

    /// Apps that claim MTP devices for themselves while they run.
    private static let conflictingAppNames = ["Android File Transfer", "Smart Switch", "Samsung Kies", "HiSuite"]

    private static func findConflictingApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard let name = app.localizedName else { return false }
            return conflictingAppNames.contains { name.localizedCaseInsensitiveContains($0) }
        }
    }

    func quitConflictingApps() {
        for app in conflictingApps {
            app.terminate()
        }
        conflictingApps = []
    }
}
