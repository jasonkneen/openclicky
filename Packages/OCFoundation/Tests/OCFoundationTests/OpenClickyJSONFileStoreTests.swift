import XCTest
@testable import OCFoundation

final class OpenClickyJSONFileStoreTests: XCTestCase {
    private struct Sample: Codable, Equatable {
        var name: String
        var count: Int
        var tags: [String]
    }

    private struct Stamped: Codable, Equatable {
        var when: Date
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCFoundationTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testWriteThenReadRoundTrips() throws {
        let url = scratch.appendingPathComponent("sample.json")
        let value = Sample(name: "alpha", count: 3, tags: ["x", "y"])
        try OpenClickyJSONFileStore.write(value, to: url)
        XCTAssertEqual(OpenClickyJSONFileStore.read(Sample.self, from: url), value)
    }

    func testWriteCreatesIntermediateDirectories() throws {
        let url = scratch
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent("c", isDirectory: true)
            .appendingPathComponent("deep.json")
        try OpenClickyJSONFileStore.write(Sample(name: "deep", count: 1, tags: []), to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testReadReturnsNilForMissingFile() {
        let url = scratch.appendingPathComponent("missing.json")
        XCTAssertNil(OpenClickyJSONFileStore.read(Sample.self, from: url))
    }

    func testReadReturnsNilForMalformedJSON() throws {
        try OpenClickyJSONFileStore.ensureDirectoryExists(scratch)
        let url = scratch.appendingPathComponent("bad.json")
        try Data("{ not json".utf8).write(to: url)
        XCTAssertNil(OpenClickyJSONFileStore.read(Sample.self, from: url))
    }

    func testReadReturnsNilForSchemaMismatch() throws {
        try OpenClickyJSONFileStore.ensureDirectoryExists(scratch)
        let url = scratch.appendingPathComponent("mismatch.json")
        try Data(#"{"unrelated": true}"#.utf8).write(to: url)
        XCTAssertNil(OpenClickyJSONFileStore.read(Sample.self, from: url))
    }

    func testWriteOverwritesAtomically() throws {
        let url = scratch.appendingPathComponent("overwrite.json")
        let first = Sample(name: "first", count: 1, tags: ["long", "payload", "that", "is", "wider"])
        let second = Sample(name: "2", count: 2, tags: [])
        try OpenClickyJSONFileStore.write(first, to: url)
        try OpenClickyJSONFileStore.write(second, to: url)
        XCTAssertEqual(OpenClickyJSONFileStore.read(Sample.self, from: url), second)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("first"), "stale bytes from the previous write leaked into the file")
    }

    func testDefaultEncoderIsDeterministicAndSorted() throws {
        let value = Sample(name: "z", count: 9, tags: ["b", "a"])
        let a = try OpenClickyJSONFileStore.defaultEncoder.encode(value)
        let b = try OpenClickyJSONFileStore.defaultEncoder.encode(value)
        XCTAssertEqual(a, b)
        let text = String(decoding: a, as: UTF8.self)
        let countIndex = text.range(of: "\"count\"")!.lowerBound
        let nameIndex = text.range(of: "\"name\"")!.lowerBound
        let tagsIndex = text.range(of: "\"tags\"")!.lowerBound
        XCTAssertLessThan(countIndex, nameIndex)
        XCTAssertLessThan(nameIndex, tagsIndex)
        XCTAssertTrue(text.contains("\n"), "expected pretty-printed output")
    }

    func testCustomEncoderAndDecoderAreHonored() throws {
        let url = scratch.appendingPathComponent("dates.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stamped = Stamped(when: Date(timeIntervalSince1970: 1_700_000_000))
        try OpenClickyJSONFileStore.write(stamped, to: url, encoder: encoder)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("2023-11-14T22:13:20Z"), "expected ISO-8601 date, got: \(raw)")
        XCTAssertEqual(OpenClickyJSONFileStore.read(Stamped.self, from: url, decoder: decoder), stamped)
        XCTAssertNil(OpenClickyJSONFileStore.read(Stamped.self, from: url), "default decoder must not silently accept ISO-8601 dates")
    }

    func testApplicationSupportDirectoryFallsBackToHome() {
        final class NoURLsFileManager: FileManager {
            override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [] }
        }
        let fm = NoURLsFileManager()
        let expected = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        XCTAssertEqual(OpenClickyJSONFileStore.applicationSupportDirectory(fileManager: fm).standardizedFileURL, expected.standardizedFileURL)
    }

    func testApplicationSupportDirectoryUsesFileManagerResult() {
        let dir = OpenClickyJSONFileStore.applicationSupportDirectory()
        XCTAssertTrue(dir.path.hasSuffix("Application Support"), dir.path)
    }

    func testEnsureDirectoryExistsReturnsSameURL() throws {
        let dir = scratch.appendingPathComponent("made", isDirectory: true)
        let returned = try OpenClickyJSONFileStore.ensureDirectoryExists(dir)
        XCTAssertEqual(returned, dir)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}
