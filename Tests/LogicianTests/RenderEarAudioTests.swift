@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import Logician

/// The audio a render result CARRIES.
///
/// The defect these cover, measured 2026-09-02 on a 136.7 s freeze render:
/// `encodeEarCopy` encoded the whole file at 64 kbps and returned nil once the
/// result passed the 400 KB attachment cap, so `logic_render_track` answered a
/// full-track render with **no audio block and no listen note** (2/2) while
/// its own description promised the sound rides along — and the encode that
/// produced nothing cost 933–1 004 ms. Everything past ~42 s is over that cap,
/// which is every normal full-track render.
///
/// So the LENGTH now decides before anything is encoded, and a file too long
/// to attach comes back as a named WINDOW instead of as silence. Nothing here
/// touches Logic: the fixtures are written by AVFoundation into a temporary
/// directory.
final class RenderEarAudioTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("logician-ear-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
        try super.tearDownWithError()
    }

    // MARK: - The cap, as arithmetic

    func testTheCapIsTheSecondsThatFitAtTheEncodeBitrate() {
        // 400 000 B at 64 kbps is 50 s nominal; 0.85 of that is the shipped
        // 42 s, the margin being the container plus material that encodes
        // above target.
        XCTAssertEqual(AudioClip.earWindowCapSeconds(maxBytes: 400_000), 42)
        XCTAssertEqual(AudioClip.earWindowCapSeconds(maxBytes: 40_000), 4)
        // Degenerate budgets must not produce a negative or infinite window.
        XCTAssertEqual(AudioClip.earWindowCapSeconds(maxBytes: 0), 0)
        XCTAssertEqual(AudioClip.earWindowCapSeconds(maxBytes: 400_000, bitrate: 0), 0)
    }

    // MARK: - The decision

    func testAShortFileIsAttachedWhole() {
        XCTAssertEqual(AudioClip.earPlan(fileSeconds: 8), .whole)
        XCTAssertEqual(AudioClip.earPlan(fileSeconds: 42), .whole, "the cap itself still fits")
    }

    func testALongFileIsWindowed() {
        // The measured freeze render: 136.7 s, and the reason the old code
        // spent a second to return nothing.
        XCTAssertEqual(AudioClip.earPlan(fileSeconds: 136.727), .window(seconds: 42))
        XCTAssertEqual(AudioClip.earPlan(fileSeconds: 42.001), .window(seconds: 42))
    }

    func testAnUnknownLengthIsTreatedAsLong() {
        // A file this server cannot open has no length to compare, and a
        // whole-file encode of an unknown length is exactly the gamble that
        // produced a silent result. A window is cheap and yields something.
        XCTAssertEqual(AudioClip.earPlan(fileSeconds: nil), .window(seconds: 42))
        XCTAssertEqual(AudioClip.earPlan(fileSeconds: 0), .window(seconds: 42))
        XCTAssertEqual(AudioClip.earPlan(fileSeconds: .nan), .window(seconds: 42))
        XCTAssertEqual(AudioClip.earPlan(fileSeconds: .infinity), .window(seconds: 42))
    }

    func testFileLengthComesOffTheHeader() throws {
        let source = try writeAIFF(named: "ten.aif", seconds: 10)
        let seconds = try XCTUnwrap(AudioClip.seconds(ofFile: source.path))
        XCTAssertEqual(seconds, 10, accuracy: 0.01)
        XCTAssertNil(AudioClip.seconds(ofFile: scratch.appendingPathComponent("nope.aif").path))
    }

    // MARK: - What comes back

    func testALongRenderCarriesANamedWindowInsteadOfNothing() throws {
        // 10 s of audio against a 40 KB cap: the same shape as 136.7 s
        // against 400 KB, small enough to encode inside a unit test.
        let source = try writeAIFF(named: "long.aif", seconds: 10)
        let ear = LogicAccessibility.earAudio(
            sourcePath: source.path, previewPath: nil, maxBytes: 40_000
        )
        let data = try XCTUnwrap(ear.data, "a long render must still arrive audible")
        XCTAssertLessThanOrEqual(data.count, 40_000)
        XCTAssertTrue(ear.windowed)
        XCTAssertEqual(try XCTUnwrap(ear.coveredSeconds), 4, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(ear.sourceSeconds), 10, accuracy: 0.05)
        // The note must say WHICH seconds were heard and where the rest is —
        // a window presented as the whole render is the same lie in a nicer
        // shape.
        XCTAssertTrue(ear.note.contains("FIRST 4 s"), ear.note)
        XCTAssertTrue(ear.note.contains("10 s"), ear.note)
        XCTAssertTrue(ear.note.contains("logic_get_audio_clip"), ear.note)
        XCTAssertTrue(ear.note.contains("preview_path"), ear.note)
    }

    func testAShortRenderIsStillCarriedWhole() throws {
        let source = try writeAIFF(named: "short.aif", seconds: 10)
        let ear = LogicAccessibility.earAudio(
            sourcePath: source.path, previewPath: nil, maxBytes: 400_000
        )
        XCTAssertNotNil(ear.data)
        XCTAssertFalse(ear.windowed)
        XCTAssertTrue(ear.note.contains("CARRIES the rendered audio"), ear.note)
    }

    func testAPreviewThatFitsIsTheBlockRatherThanASecondEncode() throws {
        // The merge the bounce profile shipped: two encodes of one file (a
        // 128 kbps preview to disk, a 64 kbps copy to memory) cost
        // 2 198–2 273 ms together on a 46 MB render. When the preview fits the
        // cap it IS the block, and these bytes prove it was reused rather
        // than re-encoded.
        let source = try writeAIFF(named: "reuse.aif", seconds: 1)
        let preview = scratch.appendingPathComponent("reuse.m4a")
        try Data(repeating: 0x5A, count: 1234).write(to: preview)
        let ear = LogicAccessibility.earAudio(
            sourcePath: source.path, previewPath: preview.path, maxBytes: 400_000
        )
        XCTAssertEqual(ear.data?.count, 1234)
        XCTAssertFalse(ear.windowed)
    }

    func testNoBlockNamesTheReasonAndThePathToOpenInstead() throws {
        // The FS1 promise in its failing half: when nothing can be attached,
        // the result must SAY so rather than arrive quietly audio-less.
        let notAudio = scratch.appendingPathComponent("notes.txt")
        try Data("this is not audio".utf8).write(to: notAudio)
        let ear = LogicAccessibility.earAudio(sourcePath: notAudio.path, previewPath: nil)
        XCTAssertNil(ear.data)
        XCTAssertFalse(ear.windowed)
        XCTAssertTrue(ear.note.contains("NO audio block"), ear.note)
        XCTAssertTrue(ear.note.contains("preview_path"), ear.note)
        XCTAssertTrue(ear.note.contains("logic_get_audio_clip"), ear.note)
    }

    // MARK: - Fixtures

    /// `seconds` of a 220 Hz tone at 0.5, stereo 16-bit 44.1 kHz — an AIFF,
    /// the container Logic's freeze render writes.
    private func writeAIFF(named name: String, seconds: Int) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        let rate = 44100.0
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: true
        ])
        let format = file.processingFormat
        let frames = AVAudioFrameCount(rate)
        for _ in 0..<seconds {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let samples = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frames) {
                    samples[channel][frame] = 0.5 * sin(2 * .pi * 220 * Float(frame) / Float(rate))
                }
            }
            try file.write(from: buffer)
        }
        return url
    }
}
