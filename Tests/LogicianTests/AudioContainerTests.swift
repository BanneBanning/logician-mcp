import Foundation
import XCTest
@testable import Logician

/// The on-disk audio readers walk an IFF chunk table byte by byte, and a
/// `Data` subscript past the end TRAPS — which kills the whole MCP server,
/// not just the request. That is reachable: a render can be measured while
/// Logic is still writing it, so the file can end mid-chunk. These cover the
/// two pure guards that make that case return nil instead, plus the
/// well-formed path they must not disturb.
final class AudioContainerTests: XCTestCase {

    // MARK: - Chunk body bounds

    func testChunkBodyInBoundsAcceptsABodyThatFits() {
        // Header at 70, 10 bytes left after it: a 4-byte field fits.
        XCTAssertTrue(LogicAccessibility.chunkBodyInBounds(offset: 70, bodyBytes: 4, count: 82))
        XCTAssertTrue(LogicAccessibility.chunkBodyInBounds(offset: 0, bodyBytes: 0, count: 8))
    }

    func testChunkBodyInBoundsRejectsATruncatedBody() {
        // The exact SSND case: the 8-byte header is present (the walk loop
        // only guarantees that much) but the offset field behind it is not.
        XCTAssertFalse(LogicAccessibility.chunkBodyInBounds(offset: 70, bodyBytes: 4, count: 80))
        XCTAssertFalse(LogicAccessibility.chunkBodyInBounds(offset: 70, bodyBytes: 4, count: 78))
    }

    func testChunkBodyInBoundsRejectsOutOfRangeAndDegenerateInputs() {
        XCTAssertFalse(LogicAccessibility.chunkBodyInBounds(offset: 0, bodyBytes: 4, count: 4))
        XCTAssertFalse(LogicAccessibility.chunkBodyInBounds(offset: -1, bodyBytes: 4, count: 100))
        XCTAssertFalse(LogicAccessibility.chunkBodyInBounds(offset: 10, bodyBytes: -1, count: 100))
        XCTAssertFalse(LogicAccessibility.chunkBodyInBounds(offset: 200, bodyBytes: 4, count: 100))
    }

    // MARK: - Container completeness

    func testContainerCompleteAcceptsAFullyWrittenFORM() {
        let header = Data(Array("FORM".utf8) + [0x00, 0x00, 0x01, 0x00] + Array("AIFF".utf8))
        XCTAssertEqual(LogicAccessibility.containerComplete(header: header, fileSize: 264), true)
        XCTAssertEqual(LogicAccessibility.containerComplete(header: header, fileSize: 4096), true)
    }

    func testContainerCompleteRejectsAFileStillBeingWritten() {
        // The size-stability test alone accepts this file; the FORM size does
        // not, which is the point of the check.
        let header = Data(Array("FORM".utf8) + [0x00, 0x00, 0x01, 0x00] + Array("AIFF".utf8))
        XCTAssertEqual(LogicAccessibility.containerComplete(header: header, fileSize: 263), false)
        XCTAssertEqual(LogicAccessibility.containerComplete(header: header, fileSize: 0), false)
    }

    func testContainerCompleteReadsRIFFSizesLittleEndian() {
        let header = Data(Array("RIFF".utf8) + [0x00, 0x01, 0x00, 0x00] + Array("WAVE".utf8))
        XCTAssertEqual(LogicAccessibility.containerComplete(header: header, fileSize: 264), true)
        XCTAssertEqual(LogicAccessibility.containerComplete(header: header, fileSize: 100), false)
    }

    func testContainerCompleteReportsNilWhenItCannotJudge() {
        // Unknown container or too few bytes: callers keep their old
        // behaviour rather than waiting for a verdict that never comes.
        XCTAssertNil(LogicAccessibility.containerComplete(
            header: Data(Array("OggS".utf8) + [0, 0, 0, 8]), fileSize: 4096
        ))
        XCTAssertNil(LogicAccessibility.containerComplete(header: Data([0x46, 0x4F]), fileSize: 4096))
        XCTAssertNil(LogicAccessibility.containerComplete(header: Data(), fileSize: 4096))
    }

    func testContainerCompleteRejectsAnEmptyDeclaredPayload() {
        // A header written before any payload size is known.
        let header = Data(Array("FORM".utf8) + [0, 0, 0, 0] + Array("AIFF".utf8))
        XCTAssertEqual(LogicAccessibility.containerComplete(header: header, fileSize: 4096), false)
    }

    // MARK: - The readers, on real bytes

    func testAudioFileMetricsReadsAWellFormedAIFF() {
        // Success path for the SSND bounds guard: a complete file must still
        // measure exactly as before. Four stereo frames, left at 0.5 (-6.02
        // dBFS constant, so RMS == peak), right silent.
        let path = writeTemporaryFile(aiff(chunks: [chunk("COMM", commBody), chunk("SSND", ssndBody)]))
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let metrics = LogicAccessibility.audioFileMetrics(path: path) else {
            return XCTFail("a well-formed AIFF must measure")
        }
        XCTAssertEqual(metrics["channels"] as? Int, 2)
        XCTAssertEqual(metrics["bits"] as? Int, 16)
        XCTAssertEqual(metrics["frames"] as? Int, 4)
        XCTAssertEqual((metrics["rms_db"] as? [Double])?.first ?? 0, -6.02, accuracy: 0.01)
        XCTAssertEqual((metrics["peak_db"] as? [Double])?.first ?? 0, -6.02, accuracy: 0.01)
        XCTAssertEqual((metrics["peak_db"] as? [Double])?.last, -140)
    }

    func testAudioFileMetricsReturnsNilOnAnAIFFTruncatedInsideSSND() {
        // The whole point: before the bounds check this TRAPPED on the Data
        // subscript reading the SSND offset field, so reaching the assertion
        // at all is most of the test.
        let path = writeTemporaryFile(truncatedInsideSSND)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertNil(LogicAccessibility.audioFileMetrics(path: path))
    }

    func testSliceAudioFileReturnsNilOnAnAIFFTruncatedInsideSSND() {
        let path = writeTemporaryFile(truncatedInsideSSND)
        let destination = path + ".wav"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: destination)
        }
        XCTAssertNil(LogicAccessibility.sliceAudioFile(
            path: path, startSeconds: 0, endSeconds: 1, destinationPath: destination
        ))
    }

    // MARK: - Byte helpers

    /// 2 channels, 4 frames, 16-bit, 44100 Hz (80-bit extended float).
    private let commBody: [UInt8] = [
        0x00, 0x02,
        0x00, 0x00, 0x00, 0x04,
        0x00, 0x10,
        0x40, 0x0E, 0xAC, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ]

    /// offset 0, blockSize 0, then four stereo frames: left 0x4000 (0.5),
    /// right silent.
    private let ssndBody: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]
        + [[UInt8]](repeating: [0x40, 0x00, 0x00, 0x00], count: 4).flatMap { $0 }

    /// A file whose last chunk stops two bytes into the SSND body — what a
    /// render caught mid-write looks like. Padded past the readers' 64-byte
    /// minimum with a filler chunk so the chunk walk is actually entered.
    private var truncatedInsideSSND: [UInt8] {
        aiff(chunks: [
            chunk("COMM", commBody),
            chunk("ANNO", [UInt8](repeating: 0x41, count: 24)),
            Array("SSND".utf8) + be32(24) + [0x00, 0x00]
        ])
    }

    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
        Array(id.utf8) + be32(UInt32(body.count)) + body + (body.count % 2 == 1 ? [0] : [])
    }

    private func aiff(chunks: [[UInt8]]) -> [UInt8] {
        let payload = Array("AIFF".utf8) + chunks.flatMap { $0 }
        return Array("FORM".utf8) + be32(UInt32(payload.count)) + payload
    }

    private func writeTemporaryFile(_ bytes: [UInt8]) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("logician-test-\(UUID().uuidString).aif")
        XCTAssertNoThrow(try Data(bytes).write(to: url))
        return url.path
    }
}
