import Foundation

/// The MTP operations the engine uses.
enum MTPOperation: UInt16 {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case closeSession = 0x1003
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case getThumb = 0x100A
    case deleteObject = 0x100B
    case sendObjectInfo = 0x100C
    case sendObject = 0x100D
    case getPartialObject = 0x101B
    /// Android's GetPartialObject for offsets beyond 4 GB.
    case getPartialObject64 = 0x95C1
    case getObjectPropValue = 0x9803
    case setObjectPropValue = 0x9804
}

/// What a device answers a request with.
struct MTPResponseCode: RawRepresentable, Equatable, Sendable, CustomStringConvertible {
    var rawValue: UInt16

    static let ok = MTPResponseCode(rawValue: 0x2001)
    static let sessionNotOpen = MTPResponseCode(rawValue: 0x2003)
    static let invalidObjectHandle = MTPResponseCode(rawValue: 0x2009)
    static let storeFull = MTPResponseCode(rawValue: 0x200C)
    static let accessDenied = MTPResponseCode(rawValue: 0x200F)
    static let storeNotAvailable = MTPResponseCode(rawValue: 0x2013)
    static let deviceBusy = MTPResponseCode(rawValue: 0x2019)
    static let sessionAlreadyOpen = MTPResponseCode(rawValue: 0x201E)
    static let transactionCancelled = MTPResponseCode(rawValue: 0x201F)

    private static let names: [UInt16: String] = [
        0x2001: "OK", 0x2002: "GeneralError", 0x2003: "SessionNotOpen", 0x2004: "InvalidTransactionID",
        0x2005: "OperationNotSupported", 0x2006: "ParameterNotSupported", 0x2007: "IncompleteTransfer",
        0x2008: "InvalidStorageID", 0x2009: "InvalidObjectHandle", 0x200A: "DevicePropNotSupported",
        0x200B: "InvalidObjectFormatCode", 0x200C: "StoreFull", 0x200D: "ObjectWriteProtected",
        0x200E: "StoreReadOnly", 0x200F: "AccessDenied", 0x2010: "NoThumbnailPresent", 0x2011: "SelfTestFailed",
        0x2012: "PartialDeletion", 0x2013: "StoreNotAvailable", 0x2014: "SpecificationByFormatUnsupported",
        0x2015: "NoValidObjectInfo", 0x2016: "InvalidCodeFormat", 0x2017: "UnknownVendorCode",
        0x2018: "CaptureAlreadyTerminated", 0x2019: "DeviceBusy", 0x201A: "InvalidParentObject",
        0x201B: "InvalidDevicePropFormat", 0x201C: "InvalidDevicePropValue", 0x201D: "InvalidParameter",
        0x201E: "SessionAlreadyOpen", 0x201F: "TransactionCancelled", 0x2020: "SpecificationOfDestinationUnsupported",
        0xA801: "InvalidObjectPropCode", 0xA802: "InvalidObjectPropFormat", 0xA803: "InvalidObjectPropValue",
        0xA804: "InvalidObjectReference", 0xA805: "GroupNotSupported", 0xA806: "InvalidDataset",
        0xA807: "SpecificationByGroupUnsupported", 0xA808: "SpecificationByDepthUnsupported", 0xA809: "ObjectTooLarge",
        0xA80A: "ObjectPropNotSupported",
    ]

    var description: String {
        Self.names[rawValue] ?? String(format: "response 0x%04X", rawValue)
    }
}

enum MTPObjectFormat {
    static let undefined: UInt16 = 0x3000
    /// A folder.
    static let association: UInt16 = 0x3001
}

enum MTPObjectProperty {
    static let objectSize: UInt16 = 0xDC04
    static let objectFileName: UInt16 = 0xDC07
}

enum MTPHandle {
    /// The parent of the objects at the top of a storage.
    static let root: UInt32 = 0xFFFF_FFFF
    /// "All formats" when listing objects.
    static let allFormats: UInt32 = 0
}

/// What a device says about itself.
struct MTPDeviceInfo: Equatable, Sendable {
    var standardVersion: UInt16 = 0
    var vendorExtensionID: UInt32 = 0
    var mtpVersion: UInt16 = 0
    var mtpExtension = ""
    var functionalMode: UInt16 = 0
    var operationsSupported: [UInt16] = []
    var eventsSupported: [UInt16] = []
    var devicePropertiesSupported: [UInt16] = []
    var captureFormats: [UInt16] = []
    var playbackFormats: [UInt16] = []
    var manufacturer = ""
    var model = ""
    var deviceVersion = ""
    var serialNumber = ""

    init() {}

    init(decoding data: Data) throws {
        var reader = MTPReader(data)
        standardVersion = try reader.u16()
        vendorExtensionID = try reader.u32()
        mtpVersion = try reader.u16()
        mtpExtension = try reader.string()
        functionalMode = try reader.u16()
        operationsSupported = try reader.array16()
        eventsSupported = try reader.array16()
        devicePropertiesSupported = try reader.array16()
        captureFormats = try reader.array16()
        playbackFormats = try reader.array16()
        manufacturer = try reader.string()
        model = try reader.string()
        deviceVersion = try reader.string()
        serialNumber = try reader.string()
    }
}

struct MTPStorageInfo: Equatable, Sendable {
    var storageType: UInt16 = 0
    var filesystemType: UInt16 = 0
    var accessCapability: UInt16 = 0
    var maxCapacity: UInt64 = 0
    var freeSpaceInBytes: UInt64 = 0
    var freeSpaceInImages: UInt32 = 0
    var storageDescription = ""
    var volumeLabel = ""

    init() {}

    init(decoding data: Data) throws {
        var reader = MTPReader(data)
        storageType = try reader.u16()
        filesystemType = try reader.u16()
        accessCapability = try reader.u16()
        maxCapacity = try reader.u64()
        freeSpaceInBytes = try reader.u64()
        freeSpaceInImages = try reader.u32()
        storageDescription = try reader.string()
        volumeLabel = try reader.string()
    }

    /// Removable ROM or removable RAM, such as an SD card.
    var isRemovable: Bool { storageType == 0x0002 || storageType == 0x0004 }
}

/// The description of one file or folder.
struct MTPObjectInfo: Equatable, Sendable {
    /// The size field of an object too large for it; the real size is a property.
    static let sizeUnknown: UInt32 = 0xFFFF_FFFF

    var storageID: UInt32 = 0
    var objectFormat: UInt16 = MTPObjectFormat.undefined
    var protectionStatus: UInt16 = 0
    var compressedSize: UInt32 = 0
    var thumbFormat: UInt16 = 0
    var thumbCompressedSize: UInt32 = 0
    var thumbPixWidth: UInt32 = 0
    var thumbPixHeight: UInt32 = 0
    var imagePixWidth: UInt32 = 0
    var imagePixHeight: UInt32 = 0
    var imageBitDepth: UInt32 = 0
    var parentObject: UInt32 = 0
    var associationType: UInt16 = 0
    var associationDesc: UInt32 = 0
    var sequenceNumber: UInt32 = 0
    var filename = ""
    var captureDate: Date?
    var modificationDate: Date?
    var keywords = ""

    init() {}

    init(decoding data: Data) throws {
        var reader = MTPReader(data)
        storageID = try reader.u32()
        objectFormat = try reader.u16()
        protectionStatus = try reader.u16()
        compressedSize = try reader.u32()
        thumbFormat = try reader.u16()
        thumbCompressedSize = try reader.u32()
        thumbPixWidth = try reader.u32()
        thumbPixHeight = try reader.u32()
        imagePixWidth = try reader.u32()
        imagePixHeight = try reader.u32()
        imageBitDepth = try reader.u32()
        parentObject = try reader.u32()
        associationType = try reader.u16()
        associationDesc = try reader.u32()
        sequenceNumber = try reader.u32()
        filename = try reader.string()
        captureDate = try reader.date()
        modificationDate = try reader.date()
        // some devices leave the last field out
        keywords = (try? reader.string()) ?? ""
    }

    func encoded() throws -> Data {
        var writer = MTPWriter()
        writer.u32(storageID)
        writer.u16(objectFormat)
        writer.u16(protectionStatus)
        writer.u32(compressedSize)
        writer.u16(thumbFormat)
        writer.u32(thumbCompressedSize)
        writer.u32(thumbPixWidth)
        writer.u32(thumbPixHeight)
        writer.u32(imagePixWidth)
        writer.u32(imagePixHeight)
        writer.u32(imageBitDepth)
        writer.u32(parentObject)
        writer.u16(associationType)
        writer.u32(associationDesc)
        writer.u32(sequenceNumber)
        try writer.string(filename)
        try writer.date(captureDate)
        try writer.date(modificationDate)
        try writer.string(keywords)
        return writer.data
    }

    var isFolder: Bool { objectFormat == MTPObjectFormat.association }

    /// Whether the device keeps a small picture of the object, which GetThumb returns.
    var hasThumbnail: Bool { thumbCompressedSize > 0 }
}

/// A failure of the engine, before it is put into the app's terms.
enum MTPError: Error, CustomStringConvertible {
    /// The device answered with something other than OK.
    case response(MTPResponseCode, during: String)
    /// The conversation with the device went out of step.
    case protocolViolation(String)
    /// A problem on the USB connection itself.
    case transport(MTPTransportError)
    case noDevice
    case multipleDevices([String])
    case cancelled

    var description: String {
        switch self {
        case .response(let code, let operation): "\(operation): \(code)"
        case .protocolViolation(let detail): "protocol error: \(detail)"
        case .transport(let error): error.description
        case .noDevice: "no MTP devices found"
        case .multipleDevices(let names): "more than 1 device: \(names.joined(separator: ", "))"
        case .cancelled: "cancelled"
        }
    }

    var responseCode: MTPResponseCode? {
        if case .response(let code, _) = self { return code }
        return nil
    }
}
