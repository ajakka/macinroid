import Foundation
import IOKit
import IOKit.usb

/// Reports USB devices being plugged in and unplugged.
@MainActor
final class USBMonitor {
    struct Device: Sendable, Equatable {
        var vendorID: Int
        var productID: Int
        var name: String
        var serialNumber: String
    }

    enum Event: Sendable, Equatable {
        case attached(Device)
        case detached(Device)
    }

    var onEvent: ((Event) -> Void)?

    private var port: IONotificationPortRef?
    private var attachIterator: io_iterator_t = 0
    private var detachIterator: io_iterator_t = 0

    private static let appleVendorID = 0x05AC
    private static let hubDeviceClass = 9

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)

        let context = Unmanaged.passUnretained(self).toOpaque()

        let attached: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            let monitor = Unmanaged<USBMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.drain(iterator, attached: true, report: true) }
        }
        let detached: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            let monitor = Unmanaged<USBMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.drain(iterator, attached: false, report: true) }
        }

        // A notification only arms once its iterator has been emptied; the
        // devices that are already there are not news, so they are not reported.
        if IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching(kIOUSBDeviceClassName), attached, context, &attachIterator) == KERN_SUCCESS {
            drain(attachIterator, attached: true, report: false)
        }
        if IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching(kIOUSBDeviceClassName), detached, context, &detachIterator) == KERN_SUCCESS {
            drain(detachIterator, attached: false, report: false)
        }
    }

    func stop() {
        for iterator in [attachIterator, detachIterator] where iterator != 0 {
            IOObjectRelease(iterator)
        }
        attachIterator = 0
        detachIterator = 0

        if let port {
            IONotificationPortDestroy(port)
        }
        port = nil
    }

    private func drain(_ iterator: io_iterator_t, attached: Bool, report: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard report, let device = Self.device(for: service) else { continue }
            onEvent?(attached ? .attached(device) : .detached(device))
        }
    }

    /// Reads what identifies a device, leaving out hubs and Apple's own
    /// devices, which are never Android phones.
    private static func device(for service: io_service_t) -> Device? {
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        let vendorID = (property("idVendor") as? NSNumber)?.intValue ?? 0
        let deviceClass = (property("bDeviceClass") as? NSNumber)?.intValue ?? 0
        guard vendorID != appleVendorID, deviceClass != hubDeviceClass else { return nil }

        return Device(
            vendorID: vendorID,
            productID: (property("idProduct") as? NSNumber)?.intValue ?? 0,
            name: property("USB Product Name") as? String ?? "",
            serialNumber: property("USB Serial Number") as? String ?? ""
        )
    }
}
