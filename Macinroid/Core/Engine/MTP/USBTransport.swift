import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

/// An MTP interface of a USB device, found on the bus but not yet opened.
struct USBInterfaceCandidate: CustomStringConvertible {
    /// The interface's entry in the I/O registry. Retained; released by `release()`.
    let service: io_service_t
    let interfaceNumber: UInt8
    let interfaceClass: UInt8
    let endpointCount: Int
    /// The interface's own name; Android calls it "MTP".
    let interfaceName: String
    let identity: DeviceInfo.USB

    var description: String {
        let device = [identity.manufacturer, identity.product].filter { !$0.isEmpty }.joined(separator: " ")
        return String(
            format: "%@ [%04X:%04X] interface %d “%@” class 0x%02X, %d endpoints",
            device.isEmpty ? "USB device" : device, identity.vendorId, identity.productId,
            interfaceNumber, interfaceName, interfaceClass, endpointCount
        )
    }

    /// Android and most other devices name the interface after the protocol.
    /// (Old Samsung phones put it behind a CDC or ACM name.)
    var isNamedForMTP: Bool {
        ["MTP", "CDC", "ACM"].contains { interfaceName.contains($0) }
    }

    /// An interface of the still-image or vendor-specific class may speak MTP
    /// without saying so in the registry; the device itself has to be asked.
    var needsProbing: Bool {
        !isNamedForMTP && (interfaceClass == 0x06 || interfaceClass == 0xFF)
    }

    func release() {
        IOObjectRelease(service)
    }

    /// Every USB interface that has the three endpoints MTP needs.
    static func all() -> [USBInterfaceCandidate] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var candidates: [USBInterfaceCandidate] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            func number(_ key: String, of entry: io_registry_entry_t) -> Int {
                (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
            }
            func text(_ keys: [String], of entry: io_registry_entry_t) -> String {
                for key in keys {
                    if let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                        return value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                return ""
            }

            guard number("bNumEndpoints", of: service) == 3 else {
                IOObjectRelease(service)
                continue
            }

            var device: io_registry_entry_t = 0
            IORegistryEntryGetParentEntry(service, kIOServicePlane, &device)
            defer { if device != 0 { IOObjectRelease(device) } }

            candidates.append(USBInterfaceCandidate(
                service: service,
                interfaceNumber: UInt8(truncatingIfNeeded: number("bInterfaceNumber", of: service)),
                interfaceClass: UInt8(truncatingIfNeeded: number("bInterfaceClass", of: service)),
                endpointCount: 3,
                interfaceName: text(["kUSBString", "USB Interface Name"], of: service),
                identity: DeviceInfo.USB(
                    vendorId: number("idVendor", of: device),
                    productId: number("idProduct", of: device),
                    deviceRelease: number("bcdDevice", of: device),
                    manufacturer: text(["kUSBVendorString", "USB Vendor Name"], of: device),
                    product: text(["kUSBProductString", "USB Product Name"], of: device),
                    serialNumber: text(["kUSBSerialNumberString", "USB Serial Number"], of: device)
                )
            ))
        }
        return candidates
    }
}

/// MTP over USB, by way of the system's IOUSBHost framework.
final class USBTransport: MTPTransport {
    let identity: DeviceInfo.USB
    private(set) var inPacketSize = 512
    private(set) var outPacketSize = 512

    private let interface: IOUSBHostInterface
    private let interfaceNumber: UInt8
    private let service: io_service_t
    private var bulkIn: IOUSBHostPipe!
    private var bulkOut: IOUSBHostPipe!
    private var isClosed = false

    private enum Endpoint {
        static let directionIn: UInt8 = 1
        static let typeBulk: UInt8 = 2
    }

    /// Class-specific requests of still-image (PTP/MTP) devices.
    private enum ClassRequest {
        static let cancel: UInt8 = 0x64
        static let getDeviceStatus: UInt8 = 0x67
        /// To the interface, host to device, and device to host.
        static let out: UInt8 = 0x21
        static let `in`: UInt8 = 0xA1
        /// The event code that goes with a cancel request.
        static let cancelTransactionCode: UInt16 = 0x4001
    }

    /// Opens the interface. Throws `MTPTransportError` with kind `.inUse` when
    /// another program holds it.
    init(_ candidate: USBInterfaceCandidate) throws {
        identity = candidate.identity
        interfaceNumber = candidate.interfaceNumber
        service = candidate.service
        IOObjectRetain(service)

        do {
            do {
                interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
            } catch where Self.kind(of: error) == .inUse {
                // ask whoever has it — the system's camera service, usually — to let go
                interface = try IOUSBHostInterface(__ioService: service, options: [.deviceSeize], queue: nil, interestHandler: nil)
            }
        } catch {
            IOObjectRelease(service)
            throw Self.transportError(error, doing: "opening the USB interface")
        }

        do {
            try openPipes()
        } catch {
            interface.destroy()
            IOObjectRelease(service)
            throw Self.transportError(error, doing: "opening the USB endpoints")
        }
    }

    deinit {
        close()
        IOObjectRelease(service)
    }

    private func openPipes() throws {
        let configuration = interface.configurationDescriptor
        let descriptor = interface.interfaceDescriptor

        var inAddress: UInt8?
        var outAddress: UInt8?
        var endpoint = IOUSBGetNextEndpointDescriptor(configuration, descriptor, nil)
        while let current = endpoint {
            if IOUSBGetEndpointType(current) == Endpoint.typeBulk {
                let address = IOUSBGetEndpointAddress(current)
                // the low 11 bits; the rest describes high-bandwidth isochronous endpoints
                let packetSize = Int(current.pointee.wMaxPacketSize & 0x07FF)
                if IOUSBGetEndpointDirection(current) == Endpoint.directionIn {
                    inAddress = address
                    if packetSize > 0 { inPacketSize = packetSize }
                } else {
                    outAddress = address
                    if packetSize > 0 { outPacketSize = packetSize }
                }
            }
            endpoint = IOUSBGetNextEndpointDescriptor(
                configuration, descriptor, UnsafeRawPointer(current).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
            )
        }

        guard let inAddress, let outAddress else {
            throw MTPTransportError(kind: .other, detail: "the interface has no pair of bulk endpoints")
        }
        bulkIn = try interface.copyPipe(withAddress: Int(inAddress))
        bulkOut = try interface.copyPipe(withAddress: Int(outAddress))
    }

    /// The interface's name, as the device states it.
    func interfaceName() -> String? {
        let index = Int(interface.interfaceDescriptor.pointee.iInterface)
        guard index != 0 else { return nil }
        return (try? interface.__string(with: index, languageID: 0x0409)).map { String($0) }
    }

    // MARK: MTPTransport

    func write(_ data: Data, timeout: TimeInterval) throws {
        var transferred = 0
        do {
            if data.isEmpty {
                try bulkOut.__sendIORequest(with: nil, bytesTransferred: &transferred, completionTimeout: timeout)
            } else {
                try bulkOut.__sendIORequest(with: NSMutableData(data: data), bytesTransferred: &transferred, completionTimeout: timeout)
            }
        } catch {
            throw Self.transportError(error, doing: "sending to the device")
        }
        guard transferred == data.count else {
            throw MTPTransportError(kind: .other, detail: "only \(transferred) of \(data.count) bytes were sent")
        }
    }

    func read(capacity: Int, timeout: TimeInterval) throws -> Data {
        guard let buffer = NSMutableData(length: capacity) else {
            throw MTPTransportError(kind: .other, detail: "out of memory")
        }
        var transferred = 0
        do {
            try bulkIn.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            throw Self.transportError(error, doing: "receiving from the device")
        }
        return Data(bytes: buffer.bytes, count: min(transferred, capacity))
    }

    func cancelRequest(transactionID: UInt32) throws {
        var payload = MTPWriter()
        payload.u16(ClassRequest.cancelTransactionCode)
        payload.u32(transactionID)

        let request = IOUSBDeviceRequest(
            bmRequestType: ClassRequest.out, bRequest: ClassRequest.cancel,
            wValue: 0, wIndex: UInt16(interfaceNumber), wLength: UInt16(payload.data.count)
        )
        var transferred = 0
        do {
            try interface.__send(request, data: NSMutableData(data: payload.data), bytesTransferred: &transferred, completionTimeout: 2)
        } catch {
            throw Self.transportError(error, doing: "cancelling")
        }
    }

    func deviceStatus() throws -> MTPResponseCode {
        // the answer is its own length, a response code and, at most, a few parameters
        let capacity = 32
        guard let buffer = NSMutableData(length: capacity) else {
            throw MTPTransportError(kind: .other, detail: "out of memory")
        }
        let request = IOUSBDeviceRequest(
            bmRequestType: ClassRequest.in, bRequest: ClassRequest.getDeviceStatus,
            wValue: 0, wIndex: UInt16(interfaceNumber), wLength: UInt16(capacity)
        )
        var transferred = 0
        do {
            try interface.__send(request, data: buffer, bytesTransferred: &transferred, completionTimeout: 2)
        } catch {
            throw Self.transportError(error, doing: "asking for the device status")
        }
        guard transferred >= 4 else {
            throw MTPTransportError(kind: .other, detail: "the device status is \(transferred) bytes long")
        }

        var reader = MTPReader(Data(bytes: buffer.bytes, count: transferred))
        _ = try reader.u16()
        return MTPResponseCode(rawValue: try reader.u16())
    }

    func clearStalls() {
        guard !isClosed else { return }
        try? bulkIn.__abort(with: .synchronous)
        try? bulkOut.__abort(with: .synchronous)
        try? bulkIn.clearStall()
        try? bulkOut.clearStall()
    }

    func resetDevice() {
        close()

        var device: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &device) == KERN_SUCCESS, device != 0 else { return }
        defer { IOObjectRelease(device) }

        // re-enumerates the device; it shows up on the bus as new afterwards
        if let host = try? IOUSBHostDevice(__ioService: device, options: [], queue: nil, interestHandler: nil) {
            try? host.reset()
            host.destroy()
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        try? bulkIn?.__abort(with: .synchronous)
        try? bulkOut?.__abort(with: .synchronous)
        bulkIn = nil
        bulkOut = nil
        interface.destroy()
    }

    // MARK: Errors

    /// IOKit result codes that matter here. The USB ones are not visible to Swift by name.
    private enum IOResult {
        static let pipeStalled = Int32(bitPattern: 0xE000_404F)
        static let transactionTimeout = Int32(bitPattern: 0xE000_4051)
    }

    private static func kind(of error: any Error) -> MTPTransportError.Kind {
        if let error = error as? MTPTransportError { return error.kind }

        switch Int32(truncatingIfNeeded: (error as NSError).code) {
        case kIOReturnTimeout, IOResult.transactionTimeout:
            return .timeout
        case kIOReturnNoDevice, kIOReturnNotResponding, kIOReturnNotAttached, kIOReturnOffline, kIOReturnNotOpen, kIOReturnAborted:
            return .disconnected
        case kIOReturnExclusiveAccess, kIOReturnBusy:
            return .inUse
        case IOResult.pipeStalled:
            return .stalled
        default:
            return .other
        }
    }

    private static func transportError(_ error: any Error, doing action: String) -> MTPTransportError {
        if let error = error as? MTPTransportError { return error }

        let code = Int32(truncatingIfNeeded: (error as NSError).code)
        let name: String = switch kind(of: error) {
        case .timeout: "timed out"
        case .disconnected: "the device is gone"
        case .inUse: "another program is using the device"
        case .stalled: "the device refused the transfer"
        case .other: error.localizedDescription
        }
        return MTPTransportError(kind: kind(of: error), detail: String(format: "%@: %@ (0x%08X)", action, name, UInt32(bitPattern: code)))
    }
}

/// Looks at USB devices the way libusb does: by their descriptors rather than
/// by what macOS has made of them.
///
/// macOS only lists the interfaces of a device it has configured. A phone it
/// leaves unconfigured has none in the registry, so `USBInterfaceCandidate.all()`
/// cannot see it. libusb — and with it OpenMTP — selects the configuration
/// itself when it finds no interface to claim; this does the same.
enum USBDeviceScan {
    struct Device: CustomStringConvertible {
        var vendorID: Int
        var productID: Int
        var deviceClass: Int
        var name: String
        var interfaceCount: Int

        var description: String {
            String(format: "%@ [%04X:%04X] class 0x%02X, %d interface(s) in the registry", name.isEmpty ? "USB device" : name, vendorID, productID, deviceClass, interfaceCount)
        }
    }

    private static let appleVendorID = 0x05AC
    private static let hubClass = 9

    /// Every USB device on the bus, with the number of interfaces macOS has made for it.
    static func devices() -> [Device] {
        forEachDevice { service, device in
            _ = service
            return device
        }
    }

    /// Selects the configuration of every unconfigured device whose descriptors
    /// show an MTP interface. Returns a line for everything it did, for problem reports.
    static func configureUnconfiguredMTPDevices() -> [String] {
        var log: [String] = []

        _ = forEachDevice { service, device -> Device in
            guard device.interfaceCount == 0, device.vendorID != appleVendorID, device.deviceClass != hubClass else { return device }
            log.append("\(device): looking for an MTP interface in its descriptors")
            log.append(contentsOf: configureIfMTP(service))
            return device
        }
        return log
    }

    private static func configureIfMTP(_ service: io_service_t) -> [String] {
        let host: IOUSBHostDevice
        do {
            do {
                host = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
            } catch {
                host = try IOUSBHostDevice(__ioService: service, options: [.deviceSeize], queue: nil, interestHandler: nil)
            }
        } catch {
            return ["  cannot open the device: \(error.localizedDescription)"]
        }
        defer { host.destroy() }

        let configurations = Int(host.deviceDescriptor?.pointee.bNumConfigurations ?? 1)
        for index in 0..<max(1, configurations) {
            guard let configuration = try? host.configurationDescriptor(with: index) else { continue }

            var interface = IOUSBGetNextInterfaceDescriptor(configuration, nil)
            while let current = interface {
                var bulkIn = false, bulkOut = false, interruptIn = false
                var endpoint = IOUSBGetNextEndpointDescriptor(configuration, current, nil)
                while let candidate = endpoint {
                    let isIn = IOUSBGetEndpointDirection(candidate) == 1
                    switch IOUSBGetEndpointType(candidate) {
                    case 2: if isIn { bulkIn = true } else { bulkOut = true }
                    case 3: if isIn { interruptIn = true }
                    default: break
                    }
                    endpoint = IOUSBGetNextEndpointDescriptor(configuration, current, UnsafeRawPointer(candidate).assumingMemoryBound(to: IOUSBDescriptorHeader.self))
                }

                let stringIndex = Int(current.pointee.iInterface)
                let name = stringIndex == 0 ? "" : ((try? host.__string(with: stringIndex, languageID: 0x0409)).map { String($0) } ?? "")
                let interfaceClass = current.pointee.bInterfaceClass
                let looksLikeMTP = bulkIn && bulkOut && interruptIn
                    && (["MTP", "CDC", "ACM"].contains(where: name.contains) || interfaceClass == 0x06 || interfaceClass == 0xFF)

                if looksLikeMTP {
                    let value = Int(configuration.pointee.bConfigurationValue)
                    do {
                        try host.__configure(withValue: value, matchInterfaces: true)
                        return ["  interface \(current.pointee.bInterfaceNumber) “\(name)” class \(interfaceClass): selected configuration \(value)"]
                    } catch {
                        return ["  interface \(current.pointee.bInterfaceNumber) “\(name)”: selecting configuration \(value) failed: \(error.localizedDescription)"]
                    }
                }
                interface = IOUSBGetNextInterfaceDescriptor(configuration, UnsafeRawPointer(current).assumingMemoryBound(to: IOUSBDescriptorHeader.self))
            }
        }
        return ["  no MTP interface in its descriptors"]
    }

    private static func forEachDevice(_ body: (io_service_t, Device) -> Device) -> [Device] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [Device] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            func number(_ key: String) -> Int {
                (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
            }
            func text(_ key: String) -> String {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? ""
            }

            var interfaceCount = 0
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS {
                while case let child = IOIteratorNext(children), child != 0 {
                    if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 { interfaceCount += 1 }
                    IOObjectRelease(child)
                }
                IOObjectRelease(children)
            }

            let device = Device(
                vendorID: number("idVendor"), productID: number("idProduct"), deviceClass: number("bDeviceClass"),
                name: text("kUSBProductString").isEmpty ? text("USB Product Name") : text("kUSBProductString"),
                interfaceCount: interfaceCount
            )
            devices.append(body(service, device))
        }
        return devices
    }
}
