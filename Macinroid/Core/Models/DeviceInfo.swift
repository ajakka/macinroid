import Foundation

/// What a connected device reports about itself.
struct DeviceInfo: Sendable, Equatable, Codable {
    struct MTP: Sendable, Equatable, Codable {
        var manufacturer = ""
        var model = ""
        var deviceVersion = ""
        var serialNumber = ""
        var standardVersion = 0
        var mtpVersion = 0
        var mtpExtension = ""
        var vendorExtensionId = 0
        var functionalMode = 0
    }

    struct USB: Sendable, Equatable, Codable {
        var vendorId = 0
        var productId = 0
        var deviceRelease = 0
        var manufacturer = ""
        var product = ""
        var serialNumber = ""
    }

    var mtp = MTP()
    var usb = USB()

    /// The name the device is referred to by throughout the app.
    var displayName: String {
        for candidate in [mtp.model, usb.product] {
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return "Android Device"
    }

    var manufacturer: String {
        let name = mtp.manufacturer.isEmpty ? usb.manufacturer : mtp.manufacturer
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Identifies the physical device across reconnects.
    var serialNumber: String {
        mtp.serialNumber.isEmpty ? usb.serialNumber : mtp.serialNumber
    }
}

/// One storage of a device, such as its internal memory or an SD card.
struct StorageInfo: Identifiable, Sendable, Equatable, Codable {
    var id: UInt32
    var description = ""
    var volumeLabel = ""
    var capacity: UInt64 = 0
    var freeSpace: UInt64 = 0
    var storageType = 0
    var filesystemType = 0
    var accessCapability = 0
    var isRemovable = false

    var displayName: String {
        for candidate in [description, volumeLabel] {
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return isRemovable ? "SD Card" : "Internal Storage"
    }

    var usedSpace: UInt64 { capacity > freeSpace ? capacity - freeSpace : 0 }

    /// 0…1, or nil when the device does not report a capacity.
    var usedFraction: Double? {
        capacity > 0 ? Double(usedSpace) / Double(capacity) : nil
    }

    var symbolName: String { isRemovable ? "sdcard" : "internaldrive" }
}
