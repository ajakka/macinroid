import Foundation

/// A failure reported by the device or by the engine that talks to it.
struct DeviceError: Error, Equatable, Sendable {
    /// The kinds of failure. The raw values name them in logs and problem reports.
    enum Code: String, Sendable {
        case mtpDetectFailed = "ErrorMtpDetectFailed"
        case mtpLockExists = "ErrorMtpLockExists"
        case deviceChanged = "ErrorDeviceChanged"
        case deviceSetup = "ErrorDeviceSetup"
        case multipleDevice = "ErrorMultipleDevice"
        case allowStorageAccess = "ErrorAllowStorageAccess"
        case deviceLocked = "ErrorDeviceLocked"
        case deviceInfo = "ErrorDeviceInfo"
        case storageInfo = "ErrorStorageInfo"
        case noStorage = "ErrorNoStorage"
        case storageFull = "ErrorStorageFull"
        case listDirectory = "ErrorListDirectory"
        case fileNotFound = "ErrorFileNotFound"
        case filePermission = "ErrorFilePermission"
        case localFileRead = "ErrorLocalFileRead"
        case invalidPath = "ErrorInvalidPath"
        case fileTransfer = "ErrorFileTransfer"
        case fileObjectRead = "ErrorFileObjectRead"
        case sendObject = "ErrorSendObject"
        case transferCancelled = "ErrorTransferCancelled"
        case general = "ErrorGeneral"
    }

    var code: Code
    /// The engine's own wording, kept for logs and problem reports.
    var detail = ""
    /// The engine closed the MTP session; it has to be opened again.
    var sessionReset = false
    /// A file that was only partly written when a transfer was cancelled.
    var abortedPath: String?

    static let notConnected = DeviceError(code: .mtpDetectFailed)
    static let cancelled = DeviceError(code: .transferCancelled)

    var isCancellation: Bool { code == .transferCancelled }

    /// Whether the error means that there is no usable connection to the device any more.
    var endsSession: Bool {
        switch code {
        case .mtpDetectFailed, .deviceChanged, .deviceSetup, .multipleDevice, .allowStorageAccess,
             .deviceLocked, .deviceInfo, .storageInfo, .noStorage:
            true
        default:
            sessionReset
        }
    }

    /// Whether the phone is there but waiting for the user to do something on it.
    var needsUserActionOnDevice: Bool {
        code == .allowStorageAccess || code == .deviceLocked
    }

    /// A short statement of what went wrong.
    var title: String {
        switch code {
        case .mtpDetectFailed: "No Phone Connected"
        case .mtpLockExists: "The Phone Is Busy"
        case .deviceChanged: "The Phone Was Disconnected"
        case .deviceSetup: "Couldn’t Connect to the Phone"
        case .multipleDevice: "More Than One Device Is Connected"
        case .allowStorageAccess: "Allow Access on Your Phone"
        case .deviceLocked: "Unlock Your Phone"
        case .deviceInfo: "Couldn’t Read the Device Information"
        case .storageInfo: "Couldn’t Read the Storage Information"
        case .noStorage: "The Phone’s Storage Is Unavailable"
        case .storageFull: "The Phone’s Storage Is Full"
        case .listDirectory: "Couldn’t Open the Folder"
        case .fileNotFound: "The Item Can’t Be Found"
        case .filePermission: "You Don’t Have Permission"
        case .localFileRead: "A File on Your Mac Can’t Be Read"
        case .invalidPath: "The Path Isn’t Valid"
        case .fileTransfer: "The Transfer Failed"
        case .fileObjectRead: "Couldn’t Read from the Phone"
        case .sendObject: "Couldn’t Write to the Phone"
        case .transferCancelled: "Transfer Cancelled"
        case .general: "Something Went Wrong"
        }
    }

    /// What the user can do about it.
    var suggestion: String {
        switch code {
        case .mtpDetectFailed:
            "Connect your phone with a USB cable, unlock it, and choose File Transfer in its USB notification."
        case .mtpLockExists:
            "Wait for the current operation to finish, then try again."
        case .deviceChanged:
            "Reconnect it to continue."
        case .deviceSetup:
            "Another app may be using the phone. Quit apps that read USB devices, then reconnect the cable."
        case .multipleDevice:
            "Macinroid works with one device at a time. Disconnect the others, then refresh."
        case .allowStorageAccess:
            "Tap Allow on the “Allow access to phone data?” prompt, then refresh."
        case .deviceLocked:
            "Unlock it and choose File Transfer in its USB notification, then refresh."
        case .deviceInfo, .storageInfo, .general:
            "Reconnect the cable and try again."
        case .noStorage:
            "Unlock your phone and make sure File Transfer is selected in its USB notification."
        case .storageFull:
            "Free up some space on the phone and try again."
        case .listDirectory:
            "The folder may have been moved or deleted. Refresh and try again."
        case .fileNotFound:
            "It may have been moved or deleted. Refresh and try again."
        case .filePermission:
            "The phone or your Mac doesn’t allow changes to this item."
        case .localFileRead:
            "Check that the file still exists and that Macinroid is allowed to read it."
        case .invalidPath:
            "The name contains characters that can’t be used here."
        case .fileTransfer, .fileObjectRead, .sendObject:
            "Keep the phone unlocked and the cable connected, then try again."
        case .transferCancelled:
            ""
        }
    }

    init(code: Code, detail: String = "", sessionReset: Bool = false, abortedPath: String? = nil) {
        self.code = code
        self.detail = detail
        self.sessionReset = sessionReset
        self.abortedPath = abortedPath
    }

    /// Wraps any error so that callers can treat failures uniformly.
    init(_ error: any Error) {
        if let error = error as? DeviceError {
            self = error
        } else if error is CancellationError {
            self = .cancelled
        } else {
            self.init(code: .general, detail: error.localizedDescription)
        }
    }
}

extension DeviceError: LocalizedError {
    var errorDescription: String? { title }
    var recoverySuggestion: String? { suggestion }
}
