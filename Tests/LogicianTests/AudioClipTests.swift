@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import Logician

/// `logic_get_audio_clip` cuts a window out of an audio file and hands the
/// model the result as audio it can hear. Until 2026-09-02 it cut that window
/// on AIFF/AIFC only: every other format fell through to `afconvert` on the
/// WHOLE file while the result reported the window that was asked for, and
/// `afconvert -c 1` then refused ('cclo' -66564) on any source carrying a
/// channel layout — which is every `.m4a` preview and every raw Logic AIFF.
///
/// So these tests are about the ONE promise the tool makes: the audio you get
/// is the seconds you asked for, on every format, or you get a refusal that
/// names why. The fixtures are written here by AVFoundation — nothing in this
/// file touches Logic, the captures directory or the network.
final class AudioClipTests: XCTestCase {

    private var scratch: URL!
    private var captures: URL!
    private var server = MCPServer()

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = MCPServer()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("logician-clip-tests-\(UUID().uuidString)")
        captures = scratch.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        Captures.rootOverride = captures
    }

    override func tearDownWithError() throws {
        Captures.rootOverride = nil
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
        captures = nil
        try super.tearDownWithError()
    }

    // MARK: - Window arithmetic

    func testWindowMapsSecondsToFrames() {
        guard case .success(let window) = AudioClip.window(
            startSeconds: 3, durationSeconds: 2, sampleRate: 44100, totalFrames: 8 * 44100
        ) else { return XCTFail("a window inside the file must resolve") }
        XCTAssertEqual(window.startFrame, 132_300)
        XCTAssertEqual(window.frameCount, 88_200)
        XCTAssertEqual(window.startSeconds, 3)
        XCTAssertEqual(window.durationSeconds, 2)
        XCTAssertFalse(window.truncated)
    }

    func testWindowStopsAtTheEndOfTheFileAndSaysSo() {
        // The requested 8 s does not exist; 1 s of it does. The clip is that
        // second, and `truncated` is what makes the result say 1 rather than
        // report the 8 the caller asked for.
        guard case .success(let window) = AudioClip.window(
            startSeconds: 3, durationSeconds: 8, sampleRate: 48000, totalFrames: 4 * 48000
        ) else { return XCTFail("a window that straddles the end keeps the part that exists") }
        XCTAssertEqual(window.frameCount, 48000)
        XCTAssertEqual(window.durationSeconds, 1)
        XCTAssertTrue(window.truncated)
    }

    func testWindowRefusesAStartPastTheEnd() {
        // Measured before the fix: `start_seconds: 10000` on a 141.9 s file
        // came back as "afconvert could not produce the clip (is the source a
        // readable audio file?)" — a diagnosis of the wrong thing entirely.
        guard case .failure(let fault) = AudioClip.window(
            startSeconds: 10000, durationSeconds: 8, sampleRate: 44100, totalFrames: 141 * 44100
        ) else { return XCTFail("a start past the end must refuse") }
        XCTAssertEqual(fault, .startPastEnd(startSeconds: 10000, fileSeconds: 141))
        XCTAssertTrue(fault.message.contains("past the end"), fault.message)
        XCTAssertTrue(fault.message.contains("141"), fault.message)
    }

    func testWindowRefusesANegativeStartAndAnEmptyDuration() {
        guard case .failure(let negative) = AudioClip.window(
            startSeconds: -100, durationSeconds: 8, sampleRate: 44100, totalFrames: 44100
        ) else { return XCTFail("a negative start must refuse") }
        XCTAssertEqual(negative, .startBeforeFile(startSeconds: -100))
        XCTAssertTrue(negative.message.contains("pass 0 or more"), negative.message)

        for duration in [0.0, -4.0] {
            guard case .failure(let empty) = AudioClip.window(
                startSeconds: 0, durationSeconds: duration, sampleRate: 44100, totalFrames: 44100
            ) else { return XCTFail("duration \(duration) is not a length") }
            XCTAssertEqual(empty, .emptyWindow(durationSeconds: duration))
        }
    }

    func testWindowSurvivesTheValuesThatUsedToTrap() {
        // `Int64(1e300 * 44100)` is a Swift runtime trap, and a trap in an MCP
        // server takes down every other in-flight request with it. Every
        // conversion in `window` happens only after the comparison that proves
        // the value fits.
        let unrepresentable = AudioClip.window(
            startSeconds: 1e300, durationSeconds: 1e300, sampleRate: 44100, totalFrames: 44100
        )
        guard case .failure(.startPastEnd) = unrepresentable else {
            return XCTFail("1e300 seconds is past the end of every file")
        }
        guard case .failure(let notANumber) = AudioClip.window(
            startSeconds: .nan, durationSeconds: 8, sampleRate: 44100, totalFrames: 44100
        ) else { return XCTFail("NaN must refuse") }
        XCTAssertTrue(notANumber.message.contains("not a finite number"), notANumber.message)
        guard case .failure(.startBeforeFile) = AudioClip.window(
            startSeconds: -.infinity, durationSeconds: 8, sampleRate: 44100, totalFrames: 44100
        ) else { return XCTFail("-infinity is before the file") }
        guard case .failure(.emptyWindow) = AudioClip.window(
            startSeconds: 0, durationSeconds: .nan, sampleRate: 44100, totalFrames: 44100
        ) else { return XCTFail("a NaN duration is not a length") }
        // A huge duration is not an error — it is the whole rest of the file.
        guard case .success(let clamped) = AudioClip.window(
            startSeconds: 0, durationSeconds: 1e300, sampleRate: 44100, totalFrames: 44100
        ) else { return XCTFail("a duration past the end keeps what exists") }
        XCTAssertEqual(clamped.frameCount, 44100)
    }

    // MARK: - The clip's name

    func testClipFileNamesDoNotCollideInsideOneSecond() {
        // Measured before the fix: four clips of 1/4/8/20 s written inside one
        // wall-clock second all reported the SAME clip_path, and each
        // overwrote the last. An agent holding the path from call 1 heard
        // call 4's audio.
        let names = (0..<8).map { _ in AudioClip.clipFileName(sourcePath: "/tmp/render-bas-a.aif") }
        XCTAssertEqual(Set(names).count, 8, "eight clips in one second need eight names")
        for name in names {
            XCTAssertTrue(name.hasPrefix("clip-"), name)
            XCTAssertTrue(name.hasSuffix("-render-bas-a.m4a"), name)
        }
    }

    func testClipFileNameKeepsTheSourceStemShortAndRecognisable() {
        let name = AudioClip.clipFileName(
            sourcePath: "/tmp/a-very-long-render-name-that-keeps-going-and-going.aif"
        )
        // The stem is the LAST 24 characters of the source's own name, as it
        // always was — long enough to recognise, short enough for a path.
        XCTAssertTrue(name.hasSuffix("-at-keeps-going-and-going.m4a"), name)
    }

    // MARK: - The window is cut, on every format

    func testEveryCaptureFormatHonoursTheWindow() throws {
        // The defect in one assertion, four times over. The fixture is silent
        // everywhere except seconds 3-4; a clip of seconds 3-4 must be loud
        // and a clip of seconds 5-6 must be silent. Before the fix, both
        // returned the whole 8 s file from second 0 on WAV, CAF and M4A.
        for format in ["wav", "aif", "caf", "m4a"] {
            let source = try writeSource(named: "window.\(format)", seconds: 8, loudSecond: 3)
            let loud = try encode(source, start: 3, duration: 1, named: "loud-\(format).m4a")
            XCTAssertEqual(loud.clip.durationSeconds, 1, accuracy: 0.05, format)
            XCTAssertGreaterThan(loud.peak, 0.2, "\(format): seconds 3-4 are the loud ones")

            let quiet = try encode(source, start: 5, duration: 1, named: "quiet-\(format).m4a")
            XCTAssertEqual(quiet.clip.durationSeconds, 1, accuracy: 0.05, format)
            XCTAssertLessThan(quiet.peak, 0.05, "\(format): seconds 5-6 are silence")
        }
    }

    func testAClipIsTheRequestedLengthNotTheWholeFile() throws {
        let source = try writeSource(named: "long.wav", seconds: 8, loudSecond: 0)
        let clip = try encode(source, start: 1, duration: 2, named: "two.m4a")
        XCTAssertEqual(clip.clip.durationSeconds, 2, accuracy: 0.05)
        XCTAssertEqual(clip.decodedSeconds, 2, accuracy: 0.12, "the encoded file itself is 2 s")
        XCTAssertEqual(clip.clip.sourceSeconds, 8, accuracy: 0.05)
    }

    func testAWindowPastTheEndIsShortenedAndReported() throws {
        let source = try writeSource(named: "short.wav", seconds: 4, loudSecond: 0)
        let clip = try encode(source, start: 3, duration: 8, named: "tail.m4a")
        XCTAssertEqual(clip.clip.durationSeconds, 1, accuracy: 0.05)
        XCTAssertTrue(clip.clip.truncated)
    }

    func testStereoIsMixedToMonoRatherThanRefused() throws {
        // `afconvert -c 1` did this until it met a channel layout. The mixdown
        // is ours now: a hard-panned-left source averages to half amplitude,
        // and the clip is one channel.
        let source = try writeSource(named: "panned.wav", seconds: 4, loudSecond: 0, rightSilent: true)
        let clip = try encode(source, start: 0, duration: 1, named: "mono.m4a")
        XCTAssertEqual(clip.clip.sourceChannels, 2)
        XCTAssertEqual(clip.channels, 1)
        XCTAssertEqual(clip.peak, 0.25, accuracy: 0.06, "0.5 left + silence right averages to 0.25")
    }

    func testASourceAboveAACsCeilingIsResampledNotRefused() throws {
        let source = try writeSource(named: "dxd.wav", seconds: 3, loudSecond: 0, rate: 192_000)
        let clip = try encode(source, start: 0, duration: 2, named: "dxd.m4a")
        XCTAssertEqual(clip.clip.sourceSampleRate, 192_000)
        XCTAssertEqual(clip.clip.encodeSampleRate, 48_000)
        XCTAssertEqual(clip.decodedSeconds, 2, accuracy: 0.12)
        XCTAssertGreaterThan(clip.peak, 0.2)
    }

    // MARK: - Refusals name what is actually wrong

    func testAFileThatIsNotAudioIsRefusedByFormatNotByEncoder() throws {
        let notAudio = scratch.appendingPathComponent("notes.txt")
        try Data("this is text, not a bounce".utf8).write(to: notAudio)
        XCTAssertThrowsError(try AudioClip.write(
            sourcePath: notAudio.path, startSeconds: 0, durationSeconds: 8,
            destination: scratch.appendingPathComponent("out.m4a")
        )) { error in
            guard let fault = error as? AudioClip.Fault, case .unreadable = fault else {
                return XCTFail("expected an unreadable-format fault, got \(error)")
            }
            XCTAssertTrue(fault.message.contains("(.txt)"), fault.message)
            XCTAssertTrue(fault.message.contains("Decodable here"), fault.message)
        }
    }

    func testNothingIsLeftBehindWhenAWindowIsRefused() throws {
        // A refused call used to leave its half-made .m4a in the user's own
        // captures directory, which nothing prunes.
        let source = try writeSource(named: "orphan.wav", seconds: 4, loudSecond: 0)
        XCTAssertThrowsError(try server.handleGetAudioClip([
            "path": source.path, "start_seconds": 10000
        ]))
        XCTAssertEqual(try clipsOnDisk(), [], "a refusal writes nothing into captures")
    }

    // MARK: - The handler's contract

    func testTheHandlerReportsTheWindowItActuallyCut() throws {
        let source = try writeSource(named: "handler.wav", seconds: 8, loudSecond: 3)
        let result = try XCTUnwrap(try server.handleGetAudioClip([
            "path": source.path, "start_seconds": 3, "duration_seconds": 2
        ]) as? [String: Any])
        XCTAssertEqual(result["success"] as? Bool, true)
        XCTAssertEqual(result["start_seconds"] as? Double, 3)
        XCTAssertEqual(try XCTUnwrap(result["duration_seconds"] as? Double), 2, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(result["source_seconds"] as? Double), 8, accuracy: 0.05)
        let path = try XCTUnwrap(result["clip_path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let size = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
        )
        XCTAssertEqual(result["encoded_bytes"] as? Int, size, "encoded_bytes is the file on disk")
        XCTAssertNil(result["warning"], "a window fully inside the file has nothing to warn about")
    }

    func testFourCallsInsideOneSecondLeaveFourClips() throws {
        let source = try writeSource(named: "burst.wav", seconds: 8, loudSecond: 0)
        var paths: [String] = []
        var sizes: [Int] = []
        for duration in [1.0, 2.0, 3.0, 4.0] {
            let result = try XCTUnwrap(try server.handleGetAudioClip([
                "path": source.path, "duration_seconds": duration
            ]) as? [String: Any])
            paths.append(try XCTUnwrap(result["clip_path"] as? String))
            sizes.append(try XCTUnwrap(result["encoded_bytes"] as? Int))
        }
        XCTAssertEqual(Set(paths).count, 4, "four clips, four paths")
        XCTAssertEqual(try clipsOnDisk().count, 4, "and four files still on disk")
        for (path, reported) in zip(paths, sizes) {
            let size = try XCTUnwrap(
                try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
            )
            XCTAssertEqual(size, reported, "each file is still the one its call reported")
        }
        XCTAssertTrue(sizes[0] < sizes[3], "a 1 s clip is smaller than a 4 s one")
    }

    func testATruncatedWindowWarnsInsteadOfOverstatingTheClip() throws {
        let source = try writeSource(named: "warn.wav", seconds: 4, loudSecond: 0)
        let result = try XCTUnwrap(try server.handleGetAudioClip([
            "path": source.path, "start_seconds": 3
        ]) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(result["duration_seconds"] as? Double), 1, accuracy: 0.05)
        let warning = try XCTUnwrap(result["warning"] as? String)
        XCTAssertTrue(warning.contains("the file ends at"), warning)
    }

    func testAStartPastTheEndIsAnArgumentErrorNotAnUnreadableFile() throws {
        let source = try writeSource(named: "past.wav", seconds: 4, loudSecond: 0)
        XCTAssertThrowsError(try server.handleGetAudioClip([
            "path": source.path, "start_seconds": 10000
        ])) { error in
            guard case LogicianError.invalidArguments(let message) = error else {
                return XCTFail("expected an argument error, got \(error)")
            }
            XCTAssertTrue(message.contains("past the end"), message)
            XCTAssertFalse(message.contains("readable audio file"), message)
        }
    }

    func testAMissingFileStillRefusesBeforeAnythingIsWritten() throws {
        XCTAssertThrowsError(try server.handleGetAudioClip(["path": "/tmp/does-not-exist.aif"]))
        XCTAssertEqual(try clipsOnDisk(), [])
    }

    // MARK: - Fixtures

    /// One second of 220 Hz at 0.5, the rest silence — so a clip can be
    /// checked for WHERE it was cut, not merely that it decoded.
    @discardableResult
    private func writeSource(
        named name: String, seconds: Int, loudSecond: Int,
        rate: Double = 44100, rightSilent: Bool = false
    ) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        var settings: [String: Any] = [
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2
        ]
        switch URL(fileURLWithPath: name).pathExtension {
        case "m4a":
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 128_000
        default:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(rate)
        for second in 0..<seconds {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let channels = Int(format.channelCount)
            for channel in 0..<channels {
                let samples = try XCTUnwrap(buffer.floatChannelData)[channel]
                for frame in 0..<Int(frames) {
                    let silent = second != loudSecond || (rightSilent && channel == 1)
                    samples[frame] = silent
                        ? 0
                        : 0.5 * sin(2 * .pi * 220 * Float(frame) / Float(rate))
                }
            }
            try file.write(from: buffer)
        }
        return url
    }

    private struct Encoded {
        let clip: AudioClip.Clip
        let peak: Float
        let decodedSeconds: Double
        let channels: Int
    }

    /// Encodes a clip and then MEASURES the file that was written — the whole
    /// point being that the result's numbers and the audio agree.
    private func encode(
        _ source: URL, start: Double, duration: Double, named name: String
    ) throws -> Encoded {
        let destination = scratch.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        let clip = try AudioClip.write(
            sourcePath: source.path, startSeconds: start,
            durationSeconds: duration, destination: destination
        )
        let written = try AVAudioFile(forReading: destination)
        let format = written.processingFormat
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(written.length)
        ))
        try written.read(into: buffer)
        var peak: Float = 0
        if let samples = buffer.floatChannelData {
            for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[0][frame])) }
        }
        return Encoded(
            clip: clip,
            peak: peak,
            decodedSeconds: Double(written.length) / format.sampleRate,
            channels: Int(format.channelCount)
        )
    }

    private func clipsOnDisk() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: captures.path).sorted()
    }
}
