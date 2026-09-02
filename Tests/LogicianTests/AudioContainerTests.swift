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

    // MARK: - A finished render, not merely a covered container

    /// The bytes below are LOGIC'S OWN, copied out of the sandbox on
    /// 2026-09-02: the first 96 bytes of a freeze render caught before it
    /// streamed any samples, and of the finished file from the same track.
    /// The header-only snapshot passes `containerComplete` — FORM declares
    /// 504 bytes and 4 096 are there — which is how two renders were copied
    /// out in 3.3 s and came back as 0-frame captures. `numSampleFrames` is
    /// the field that tells them apart.
    private let headerOnlyFreezeHead = Data(
        [0x46, 0x4F, 0x52, 0x4D, 0x00, 0x00, 0x01, 0xF8, 0x41, 0x49, 0x46, 0x43,
         0x43, 0x4F, 0x4D, 0x4D, 0x00, 0x00, 0x01, 0xB4, 0x00, 0x02, 0x00, 0x00,
         0x00, 0x00, 0x00, 0x20, 0x40, 0x0E, 0xAC, 0x44]
    )

    private let finishedFreezeHead = Data(
        [0x46, 0x4F, 0x52, 0x4D, 0x02, 0xE0, 0x0C, 0x60, 0x41, 0x49, 0x46, 0x43,
         0x43, 0x4F, 0x4D, 0x4D, 0x00, 0x00, 0x01, 0xB4, 0x00, 0x02, 0x00, 0x5C,
         0x01, 0x4D, 0x00, 0x20, 0x40, 0x0E, 0xAC, 0x44]
    )

    func testAHeaderOnlyFreezeSnapshotIsNotAFinishedRender() {
        // Its container IS covered — that is the trap.
        XCTAssertEqual(
            LogicAccessibility.containerComplete(header: headerOnlyFreezeHead, fileSize: 4096),
            true
        )
        XCTAssertEqual(
            LogicAccessibility.audioRenderComplete(head: headerOnlyFreezeHead, fileSize: 4096),
            false
        )
    }

    func testAFinishedFreezeRenderIsComplete() {
        XCTAssertEqual(
            LogicAccessibility.audioRenderComplete(
                head: finishedFreezeHead, fileSize: 48_237_672
            ),
            true
        )
    }

    func testAFinishedHeaderOnAShortFileIsStillIncomplete() {
        // The samples are declared but not all written yet.
        XCTAssertEqual(
            LogicAccessibility.audioRenderComplete(
                head: finishedFreezeHead, fileSize: 1_000_000
            ),
            false
        )
    }

    func testARenderVerdictIsWithheldOnAContainerItCannotJudge() {
        XCTAssertNil(LogicAccessibility.audioRenderComplete(
            head: Data(Array("OggS".utf8) + [0, 0, 0, 8]), fileSize: 4096
        ))
        // FORM says covered, but the head read reached no COMM chunk: judging
        // nothing is the honest answer, and the caller keeps its old evidence.
        XCTAssertNil(LogicAccessibility.audioRenderComplete(
            head: Data(Array("FORM".utf8) + [0, 0, 0, 8 + 4] + Array("AIFF".utf8)),
            fileSize: 4096
        ))
    }

    func testAWavRenderFallsBackToTheContainerCheck() {
        let header = Data(Array("RIFF".utf8) + [0x00, 0x01, 0x00, 0x00] + Array("WAVE".utf8))
        XCTAssertEqual(
            LogicAccessibility.audioRenderComplete(head: header, fileSize: 264), true
        )
        XCTAssertEqual(
            LogicAccessibility.audioRenderComplete(head: header, fileSize: 100), false
        )
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

    func testSliceAudioFileRefusesAStartBeforeTheFile() {
        // `start_seconds` reaches the slicer straight from the tool argument
        // (the schema's `minimum` is advisory - the server validates only
        // additionalProperties), and the frame window used to be clamped at
        // the TOP only. A negative start therefore produced a negative
        // firstFrame with a positive sliceFrames, and the sample loop read
        // megabytes BEFORE the buffer through an unsafe pointer.
        let path = writeTemporaryFile(aiff(chunks: [chunk("COMM", commBody), chunk("SSND", ssndBody)]))
        let destination = path + ".wav"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: destination)
        }
        XCTAssertNil(LogicAccessibility.sliceAudioFile(
            path: path, startSeconds: -100, endSeconds: -99, destinationPath: destination
        ))
        // A window that STRADDLES zero keeps the part of it that exists.
        XCTAssertNotNil(LogicAccessibility.sliceAudioFile(
            path: path, startSeconds: -100, endSeconds: 1, destinationPath: destination
        ))
    }

    func testSliceAudioFileRefusesUnrepresentableSecondsInsteadOfTrapping() {
        // `Int(1e300 * 44100)` is a Swift runtime trap, and a trap here takes
        // the whole MCP server down rather than failing the one request.
        let path = writeTemporaryFile(aiff(chunks: [chunk("COMM", commBody), chunk("SSND", ssndBody)]))
        let destination = path + ".wav"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: destination)
        }
        XCTAssertNil(LogicAccessibility.sliceAudioFile(
            path: path, startSeconds: 1e300, endSeconds: 1e301, destinationPath: destination
        ))
        XCTAssertNil(LogicAccessibility.sliceAudioFile(
            path: path, startSeconds: .nan, endSeconds: .nan, destinationPath: destination
        ))
        XCTAssertNil(LogicAccessibility.sliceAudioFile(
            path: path, startSeconds: -.infinity, endSeconds: .infinity, destinationPath: destination
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
