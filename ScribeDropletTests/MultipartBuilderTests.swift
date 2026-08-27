import XCTest
import Foundation

/// The multipart envelope either works or it does not, and a malformed one
/// comes back as a bare 400 with no diagnostic. These tests assert on exact
/// bytes so that failure mode never reaches the network.
final class MultipartBuilderTests: XCTestCase {

    private let boundary = "TESTBOUNDARY"

    private func makeBody(fields: [String: String] = [:],
                          fileName: String = "clip.mp3",
                          mime: String = "audio/mpeg",
                          fileData: Data = Data("AUDIO".utf8)) -> Data {
        MultipartBuilder(boundary: boundary).body(fields: fields,
                                                  fileFieldName: "file",
                                                  fileName: fileName,
                                                  fileMIMEType: mime,
                                                  fileData: fileData)
    }

    func testExactEnvelopeForOneFieldAndOneFile() throws {
        let body = makeBody(fields: ["model_id": "scribe_v2"])
        let expected = [
            "--TESTBOUNDARY",
            "Content-Disposition: form-data; name=\"model_id\"",
            "",
            "scribe_v2",
            "--TESTBOUNDARY",
            "Content-Disposition: form-data; name=\"file\"; filename=\"clip.mp3\"",
            "Content-Type: audio/mpeg",
            "",
            "AUDIO",
            "--TESTBOUNDARY--",
            "",
        ].joined(separator: "\r\n")

        XCTAssertEqual(String(data: body, encoding: .utf8), expected)
    }

    func testEveryLineTerminatorIsCRLF() throws {
        let body = makeBody(fields: ["diarize": "true", "model_id": "scribe_v2"])
        let bytes = [UInt8](body)
        let lf = UInt8(0x0A)
        let cr = UInt8(0x0D)

        for (index, byte) in bytes.enumerated() where byte == lf {
            XCTAssertTrue(index > 0 && bytes[index - 1] == cr,
                          "Bare LF at offset \(index): the envelope must use CRLF throughout")
        }
    }

    func testClosingBoundaryIsPrefixedAndSuffixed() throws {
        let body = makeBody()
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
        // Opening boundaries are prefixed only.
        XCTAssertTrue(text.hasPrefix("--\(boundary)\r\n"))
    }

    func testFieldsAreEmittedInSortedOrderSoTheBodyIsDeterministic() throws {
        let fields = ["model_id": "scribe_v2", "diarize": "true", "language_code": "por"]
        let first = makeBody(fields: fields)
        let second = makeBody(fields: fields)
        XCTAssertEqual(first, second)

        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        let diarize = try XCTUnwrap(text.range(of: "name=\"diarize\""))
        let languageCode = try XCTUnwrap(text.range(of: "name=\"language_code\""))
        let modelID = try XCTUnwrap(text.range(of: "name=\"model_id\""))
        XCTAssertTrue(diarize.lowerBound < languageCode.lowerBound)
        XCTAssertTrue(languageCode.lowerBound < modelID.lowerBound)
    }

    func testBinaryFileBytesSurviveUnchanged() throws {
        // Bytes that are not valid UTF-8. Building the body as a String would
        // corrupt these; building it as Data must not.
        let audio = Data([0xFF, 0xD8, 0x00, 0x01, 0xFE, 0x0A, 0x0D])
        let body = makeBody(fields: [:], fileData: audio)

        let header = Data("\r\n\r\n".utf8)
        let headerEnd = try XCTUnwrap(body.range(of: header))
        let trailer = Data("\r\n--\(boundary)--\r\n".utf8)
        let trailerStart = try XCTUnwrap(body.range(of: trailer))

        XCTAssertEqual(body[headerEnd.upperBound..<trailerStart.lowerBound], audio)
    }

    func testEmptyFieldsStillProduceAValidFilePart() throws {
        let body = makeBody(fields: [:])
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertEqual(text.components(separatedBy: "--\(boundary)").count - 1, 2,
                       "One opening boundary for the file part, one closing boundary")
    }

    func testQuotesInFilenameCannotBreakOutOfTheHeader() throws {
        let body = makeBody(fileName: "my\"weird\"\r\nname.mp3")
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(text.contains("filename=\"my'weird'name.mp3\""))
        // Still exactly two boundaries: the filename did not inject a part.
        XCTAssertEqual(text.components(separatedBy: "--\(boundary)").count - 1, 2)
    }

    func testNonASCIIFieldValuesAreUTF8Encoded() throws {
        let body = makeBody(fields: ["note": "obrigação"])
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(text.contains("\r\n\r\nobrigação\r\n"))
    }

    func testContentTypeHeaderCarriesTheBoundary() {
        XCTAssertEqual(MultipartBuilder(boundary: boundary).contentType,
                       "multipart/form-data; boundary=TESTBOUNDARY")
    }

    func testRandomBoundariesAreUnique() {
        XCTAssertNotEqual(MultipartBuilder.randomBoundary(), MultipartBuilder.randomBoundary())
    }

    func testMIMETypeLookup() {
        XCTAssertEqual(MultipartBuilder.mimeType(forPathExtension: "mp3"), "audio/mpeg")
        XCTAssertEqual(MultipartBuilder.mimeType(forPathExtension: "M4A"), "audio/mp4")
        XCTAssertEqual(MultipartBuilder.mimeType(forPathExtension: "wav"), "audio/wav")
        XCTAssertEqual(MultipartBuilder.mimeType(forPathExtension: "xyz"), "application/octet-stream")
    }

    func testBodyFromFileURLReadsTheFileAndDerivesItsMIMEType() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-test-\(UUID().uuidString).wav")
        let audio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0xFF])
        try audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let body = try MultipartBuilder(boundary: boundary)
            .body(fields: ["model_id": "scribe_v2"], fileFieldName: "file", fileURL: url)
        let text = try XCTUnwrap(String(data: body, encoding: .isoLatin1))

        XCTAssertTrue(text.contains("Content-Type: audio/wav"))
        XCTAssertTrue(text.contains("filename=\"\(url.lastPathComponent)\""))
        XCTAssertNotNil(body.range(of: audio))
    }
}
