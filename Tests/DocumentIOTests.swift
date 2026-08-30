import XCTest
@testable import Pane

@MainActor
final class DocumentIOTests: XCTestCase {
    func testUTF8BOMAndCRLFArePreserved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sample.txt")
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("one\r\ntwo\r\n".utf8))
        try data.write(to: url)

        let decoded = try DocumentIO.load(url: url)
        XCTAssertEqual(decoded.encoding, .utf8BOM)
        XCTAssertEqual(decoded.lineEnding, .crlf)
        XCTAssertEqual(decoded.text, "one\ntwo\n")

        let document = EditorDocument(
            url: url,
            text: decoded.text + "three\n",
            encoding: decoded.encoding,
            lineEnding: decoded.lineEnding,
            isReadOnly: false,
            isBinary: false
        )
        try DocumentIO.save(document)
        let saved = try Data(contentsOf: url)
        XCTAssertTrue(saved.starts(with: [0xEF, 0xBB, 0xBF]))
        XCTAssertTrue(String(data: saved.dropFirst(3), encoding: .utf8)?.contains("two\r\nthree\r\n") == true)
    }

    func testBinaryFilesAreReadOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0x00, 0x01, 0x02]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoded = try DocumentIO.load(url: url)
        XCTAssertTrue(decoded.isBinary)
        XCTAssertTrue(decoded.isReadOnly)
    }
}
