import XCTest
@testable import Macinroid

final class FilePathTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(FilePath.normalize("//DCIM//Camera/"), "/DCIM/Camera")
        XCTAssertEqual(FilePath.normalize(""), "/")
        XCTAssertEqual(FilePath.normalize("/"), "/")
    }

    func testParentAndName() {
        XCTAssertEqual(FilePath.parent(of: "/DCIM/Camera"), "/DCIM")
        XCTAssertEqual(FilePath.parent(of: "/DCIM"), "/")
        XCTAssertEqual(FilePath.parent(of: "/"), "/")
        XCTAssertEqual(FilePath.name(of: "/DCIM/Camera/IMG 1.jpg"), "IMG 1.jpg")
        XCTAssertEqual(FilePath.name(of: "/"), "")
    }

    func testJoin() {
        XCTAssertEqual(FilePath.join("/", "Music"), "/Music")
        XCTAssertEqual(FilePath.join("/Music/", "/a.mp3"), "/Music/a.mp3")
    }

    func testAncestors() {
        XCTAssertEqual(FilePath.ancestors(of: "/a/b/c"), ["/", "/a", "/a/b", "/a/b/c"])
        XCTAssertEqual(FilePath.ancestors(of: "/"), ["/"])
    }

    func testIsSameOrInside() {
        XCTAssertTrue(FilePath.isSame("/a/b", orInside: "/a"))
        XCTAssertTrue(FilePath.isSame("/a", orInside: "/a"))
        XCTAssertTrue(FilePath.isSame("/a", orInside: "/"))
        XCTAssertFalse(FilePath.isSame("/ab", orInside: "/a"))
        XCTAssertFalse(FilePath.isSame("/a", orInside: "/a/b"))
    }
}

final class FileSortTests: XCTestCase {
    private func item(_ name: String, folder: Bool = false, size: Int64 = 0, modified: TimeInterval = 0) -> FileItem {
        FileItem(path: "/" + name, name: name, isFolder: folder, size: size, modified: Date(timeIntervalSince1970: modified))
    }

    func testNamesSortNaturallyAndIgnoreCase() {
        let items = [item("file10.txt"), item("File2.txt"), item("apple.txt"), item("file1.txt")]
        let sorted = FileSort().sorted(items, foldersFirst: false).map(\.name)
        XCTAssertEqual(sorted, ["apple.txt", "file1.txt", "File2.txt", "file10.txt"])
    }

    func testFoldersFirstInBothDirections() {
        let items = [item("b.txt"), item("Zoo", folder: true), item("a.txt"), item("Alpha", folder: true)]

        XCTAssertEqual(FileSort(key: .name, ascending: true).sorted(items, foldersFirst: true).map(\.name),
                       ["Alpha", "Zoo", "a.txt", "b.txt"])
        XCTAssertEqual(FileSort(key: .name, ascending: false).sorted(items, foldersFirst: true).map(\.name),
                       ["Zoo", "Alpha", "b.txt", "a.txt"])
        XCTAssertEqual(FileSort(key: .name, ascending: true).sorted(items, foldersFirst: false).map(\.name),
                       ["a.txt", "Alpha", "b.txt", "Zoo"])
    }

    func testSizeAndDate() {
        let items = [item("big", size: 300, modified: 10), item("small", size: 1, modified: 30), item("mid", size: 20, modified: 20)]

        XCTAssertEqual(FileSort(key: .size, ascending: false).sorted(items, foldersFirst: false).map(\.name), ["big", "mid", "small"])
        XCTAssertEqual(FileSort(key: .modified, ascending: true).sorted(items, foldersFirst: false).map(\.name), ["big", "mid", "small"])
    }

    func testEqualKeysFallBackToName() {
        let items = [item("b", size: 5), item("a", size: 5), item("c", size: 5)]
        XCTAssertEqual(FileSort(key: .size, ascending: false).sorted(items, foldersFirst: false).map(\.name), ["a", "b", "c"])
    }
}

final class FileNameRuleTests: XCTestCase {
    func testEmptyAndIllegalNames() {
        XCTAssertEqual(FileNameRule.validate("   ", siblings: []), .empty)
        for name in ["a/b", "a\\b", "what?", "50%", "star*", "a:b", "pipe|", "\"quoted\"", "<tag>", ".", ".."] {
            XCTAssertEqual(FileNameRule.validate(name, siblings: []), .illegalCharacters, name)
        }
        XCTAssertNil(FileNameRule.validate("Holiday photos (2026)", siblings: []))
    }

    func testTakenNames() {
        XCTAssertEqual(FileNameRule.validate("music", siblings: ["Music", "Movies"]), .taken("music"))
        XCTAssertNil(FileNameRule.validate("Podcasts", siblings: ["Music", "Movies"]))
    }

    func testRenamingOnlyTheCaseIsAllowed() {
        XCTAssertNil(FileNameRule.validate("Notes.TXT", siblings: ["other.txt"], current: "notes.txt"))
        XCTAssertEqual(FileNameRule.validate("other.txt", siblings: ["other.txt"], current: "notes.txt"), .taken("other.txt"))
    }
}

final class TransferRequestTests: XCTestCase {
    func testLocalPathOfADownloadedFile() {
        let request = TransferRequest(direction: .download, storageID: 1, sources: ["/DCIM/Camera", "/notes.txt"], destination: "/Users/me/Desktop", countFirst: true)

        XCTAssertEqual(request.localPath(forDevicePath: "/DCIM/Camera/2026/IMG.jpg"), "/Users/me/Desktop/Camera/2026/IMG.jpg")
        XCTAssertEqual(request.localPath(forDevicePath: "/notes.txt"), "/Users/me/Desktop/notes.txt")
        XCTAssertNil(request.localPath(forDevicePath: "/Music/a.mp3"))
    }

    func testUploadsHaveNoLocalPartialFile() {
        let request = TransferRequest(direction: .upload, storageID: 1, sources: ["/tmp/a"], destination: "/", countFirst: false)
        XCTAssertNil(request.localPath(forDevicePath: "/a"))
    }

    func testIdentifiersAreUniqueAndNonZero() {
        let ids = (0..<50).map { _ in TransferRequest(direction: .upload, storageID: 1, sources: [], destination: "/", countFirst: false).id }
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertFalse(ids.contains(0))
    }
}

final class DeviceErrorTests: XCTestCase {
    func testErrorsThatEndTheSession() {
        for code: DeviceError.Code in [.mtpDetectFailed, .deviceChanged, .deviceSetup, .multipleDevice, .allowStorageAccess, .deviceLocked, .noStorage] {
            XCTAssertTrue(DeviceError(code: code).endsSession, code.rawValue)
        }
        for code: DeviceError.Code in [.fileNotFound, .invalidPath, .storageFull, .sendObject, .transferCancelled, .general] {
            XCTAssertFalse(DeviceError(code: code).endsSession, code.rawValue)
        }
        XCTAssertTrue(DeviceError(code: .transferCancelled, sessionReset: true).endsSession)
    }

    func testEveryErrorExplainsItself() {
        let codes: [DeviceError.Code] = [
            .mtpDetectFailed, .mtpLockExists, .deviceChanged, .deviceSetup, .multipleDevice, .allowStorageAccess, .deviceLocked,
            .deviceInfo, .storageInfo, .noStorage, .storageFull, .listDirectory, .fileNotFound, .filePermission, .localFileRead,
            .invalidPath, .fileTransfer, .fileObjectRead, .sendObject, .general,
        ]
        for code in codes {
            let error = DeviceError(code: code)
            XCTAssertFalse(error.title.isEmpty, code.rawValue)
            XCTAssertFalse(error.suggestion.isEmpty, code.rawValue)
        }
    }

    func testWrappingOtherErrors() {
        XCTAssertTrue(DeviceError(CancellationError()).isCancellation)
        XCTAssertEqual(DeviceError(DeviceError(code: .deviceLocked)).code, .deviceLocked)
        XCTAssertEqual(DeviceError(CocoaError(.fileNoSuchFile)).code, .general)
    }
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private func release(_ version: String, prerelease: Bool = false) -> UpdateChecker.Release {
        UpdateChecker.Release(version: version, title: version, notes: "", pageURL: URL(string: "https://example.com")!, downloadURL: nil, isPrerelease: prerelease)
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("1.10", newerThan: "1.9"))
        XCTAssertTrue(UpdateChecker.isVersion("2.0", newerThan: "1.99.99"))
        XCTAssertTrue(UpdateChecker.isVersion("1.0.1", newerThan: "1.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2", newerThan: "1.3"))
        // a final release beats its own betas
        XCTAssertTrue(UpdateChecker.isVersion("1.2", newerThan: "1.2-beta.3"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2-beta.3", newerThan: "1.2"))
        XCTAssertTrue(UpdateChecker.isVersion("1.2-beta.10", newerThan: "1.2-beta.9"))
    }

    func testNewestRelease() {
        let releases = [release("1.1"), release("1.3"), release("2.0-beta.1", prerelease: true), release("1.2")]

        XCTAssertEqual(UpdateChecker.newestRelease(in: releases, after: "1.0", includingPrereleases: false)?.version, "1.3")
        XCTAssertEqual(UpdateChecker.newestRelease(in: releases, after: "1.0", includingPrereleases: true)?.version, "2.0-beta.1")
        XCTAssertNil(UpdateChecker.newestRelease(in: releases, after: "1.3", includingPrereleases: false))
        XCTAssertNil(UpdateChecker.newestRelease(in: [], after: "1.0", includingPrereleases: true))
    }
}

@MainActor
final class SymbolTests: XCTestCase {
    /// A misspelt symbol name shows up as an empty space in the interface.
    func testEverySymbolExists() {
        for symbol in Symbol.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: nil), symbol.rawValue)
        }
        for mode in ViewMode.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: nil), mode.symbolName)
        }
    }
}

final class FormatTests: XCTestCase {
    func testItems() {
        XCTAssertEqual(Format.items(1), "1 item")
        XCTAssertEqual(Format.items(0), "0 items")
        XCTAssertTrue(Format.items(12).hasSuffix("items"))
    }

    func testRemainingTimeIsRounded() {
        XCTAssertEqual(Format.remaining(2), "a few seconds")
        XCTAssertTrue(Format.remaining(42).hasPrefix("about "))
        XCTAssertEqual(Format.remaining(-1), "")
        XCTAssertEqual(Format.remaining(.infinity), "")
    }
}
