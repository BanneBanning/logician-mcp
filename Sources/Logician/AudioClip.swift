@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

// MARK: - Cutting one listenable clip out of an audio file

/// The window-and-encode behind `logic_get_audio_clip`: read a time range out
/// of a local audio file, mix it to mono and write it as a 64 kbps AAC `.m4a`.
///
/// It runs entirely in process, on AVFoundation, and that is a correctness
/// decision before it is a speed one. The route it replaces was
/// "`sliceAudioFile` (AIFF/AIFC parser) → `/usr/bin/afconvert -c 1`", and both
/// halves were unsound, measured 2026-09-02:
///
///  - The parser understood AIFF/AIFC only and returned `nil` on everything
///    else, and the handler's fallthrough then encoded the WHOLE file while
///    reporting the window that was asked for. A 4.0 s WAVE asked for seconds
///    1-9 came back as all 4.0 s from second 0, `success: true`.
///  - `afconvert -c 1` fails with `ExtAudioFileSetProperty ('cclo') failed
///    (-66564)` on any source carrying a channel-layout chunk — every `.m4a`
///    preview this server writes, and every raw Logic AIFF. So the moment the
///    parser declined a file, the call hard-failed.
///
/// Here the window is applied by SEEKING (`framePosition`), so only the window
/// is ever decoded — the old path read all 50 MB of a master to use 5% of it —
/// and the mono mixdown is ours, an explicit average of the source channels,
/// rather than a channel-layout negotiation with an encoder that refuses.
enum AudioClip {

    /// The highest rate this encoder will write. Measured 2026-09-02: an AAC
    /// destination ACCEPTS a 96 kHz setting and then fails at the first write
    /// (-66567), so the ceiling is applied here rather than discovered halfway
    /// through a clip. A source above it is resampled on the way out rather
    /// than refused — Logic bounces up to 192 kHz, and a clip is for
    /// listening, not for mastering.
    static let maximumEncodeRate: Double = 48_000

    /// The nominal encode bitrate. AAC is variable-rate, so this is a target,
    /// not a size: measured 2026-09-02 on the same 8 s window, 50,476 B of
    /// loud material and 6,208 B of near-silence.
    static let bitrate = 64_000

    // MARK: Faults

    /// Why no clip could be made. One case per thing that can actually be
    /// wrong, because the caller's next move differs for each: the old code
    /// funnelled a bad window, an unsupported format and a dead encoder into
    /// one message ("is the source a readable audio file?") that was a lie for
    /// two of the three.
    enum Fault: Error, Equatable {
        /// AVFoundation could not open the file at all.
        case unreadable(path: String, detail: String)
        /// Opened, but there are no frames to cut.
        case emptySource(path: String)
        /// `start_seconds` is at or past the last frame.
        case startPastEnd(startSeconds: Double, fileSeconds: Double)
        /// `start_seconds` is negative.
        case startBeforeFile(startSeconds: Double)
        /// `duration_seconds` is zero, negative or not a number.
        case emptyWindow(durationSeconds: Double)
        /// The window is sound; the encoder is what failed.
        case encoderRefused(detail: String)

        /// The whole message the agent sees. It names what was wrong and the
        /// move out of it, and never invites a retry that cannot work.
        var message: String {
            switch self {
            case .unreadable(let path, let detail):
                let ext = URL(fileURLWithPath: path).pathExtension
                let named = ext.isEmpty ? "no extension" : ".\(ext)"
                return "'\(path)' (\(named)) is not audio this server can decode: \(detail). "
                    + "Decodable here: AIFF/AIFC, WAV, CAF, M4A/AAC, MP3, FLAC - "
                    + "everything logic_bounce_range and logic_render_track write."
            case .emptySource(let path):
                return "'\(path)' opens as audio but holds no frames (0 samples) - "
                    + "if a render is still running, wait for it to finish and call again."
            case .startPastEnd(let start, let file):
                guard start.isFinite else {
                    return "start_seconds is not a finite number of seconds; the file is "
                        + "\(trim(file)) s long, so pass a start between 0 and \(trim(file))."
                }
                return "start_seconds \(trim(start)) is past the end of the file, which is "
                    + "\(trim(file)) s long; pass a start below \(trim(file))."
            case .startBeforeFile(let start):
                return "start_seconds \(trim(start)) is before the start of the file; "
                    + "pass 0 or more."
            case .emptyWindow(let duration):
                return "duration_seconds \(trim(duration)) is not a length; pass more than 0 "
                    + "(default 8, max 20)."
            case .encoderRefused(let detail):
                return "the window was read but the AAC encoder failed on it: \(detail)."
            }
        }

        private func trim(_ value: Double) -> String {
            guard value.isFinite else { return "\(value)" }
            return value == value.rounded()
                ? String(Int(value.rounded()))
                : String(format: "%.3f", value)
        }
    }

    // MARK: The window, as pure arithmetic

    /// The frames a request actually maps to. Separately computed and
    /// separately tested because every argument in it is agent-supplied: the
    /// JSON Schema's `minimum`/`maximum` are advisory here (this server
    /// validates only `additionalProperties`), and `Int64(_:)` traps on a
    /// value a Double can hold, so every conversion below happens only after
    /// the comparison that makes it representable.
    struct Window: Equatable {
        let startFrame: Int64
        let frameCount: Int64
        /// Where the clip really starts, in seconds (frame-quantised).
        let startSeconds: Double
        /// How long the clip really is - NOT what was asked for when the file
        /// ended first. The result reports this one.
        let durationSeconds: Double
        /// The file ended before the requested window did.
        let truncated: Bool
    }

    static func window(
        startSeconds: Double, durationSeconds: Double,
        sampleRate: Double, totalFrames: Int64
    ) -> Result<Window, Fault> {
        guard sampleRate.isFinite, sampleRate > 0, totalFrames > 0 else {
            return .failure(.emptySource(path: ""))
        }
        let fileSeconds = (Double(totalFrames) / sampleRate * 1000).rounded() / 1000
        // Written as `!(x < 0)` deliberately: that is false for -infinity and
        // TRUE for NaN, so -infinity lands on "before the file" and NaN falls
        // through to the finiteness guard below, which names itself.
        guard !(startSeconds < 0) else {
            return .failure(.startBeforeFile(startSeconds: startSeconds))
        }
        guard startSeconds.isFinite else {
            return .failure(.startPastEnd(startSeconds: startSeconds, fileSeconds: fileSeconds))
        }
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return .failure(.emptyWindow(durationSeconds: durationSeconds))
        }
        // Compared as Doubles, converted only once the comparison proves the
        // value fits: `Int64(1e300 * 44100)` is a runtime trap, and a trap in
        // an MCP server takes down every other request with it.
        let startProduct = (startSeconds * sampleRate).rounded(.down)
        guard startProduct < Double(totalFrames) else {
            return .failure(.startPastEnd(startSeconds: startSeconds, fileSeconds: fileSeconds))
        }
        let startFrame = Int64(startProduct)
        let available = totalFrames - startFrame
        let wanted = (durationSeconds * sampleRate).rounded()
        let frameCount = Int64(min(wanted, Double(available)))
        guard frameCount > 0 else {
            return .failure(.emptyWindow(durationSeconds: durationSeconds))
        }
        return .success(Window(
            startFrame: startFrame,
            frameCount: frameCount,
            startSeconds: (Double(startFrame) / sampleRate * 1000).rounded() / 1000,
            durationSeconds: (Double(frameCount) / sampleRate * 1000).rounded() / 1000,
            truncated: wanted > Double(frameCount)
        ))
    }

    // MARK: The clip's name

    /// A name no second call can collide with.
    ///
    /// The old name stamped WHOLE seconds
    /// (`clip-<epoch>-<stem>.m4a`), so two calls on one source inside one
    /// wall-clock second wrote the same path and the second overwrote the
    /// first — measured 2026-09-02: four clips of 1/4/8/20 s, four different
    /// pieces of audio, all reporting `clip-1788300050-render-bas-a-…m4a`. An
    /// agent that took the path from call 1 and opened it after call 2 heard
    /// the wrong clip with nothing to warn it. Milliseconds plus a random
    /// suffix, the way `scratchBase` already names its temporaries.
    static func clipFileName(sourcePath: String, now: Date = Date()) -> String {
        let stem = URL(fileURLWithPath: sourcePath)
            .deletingPathExtension().lastPathComponent.suffix(24)
        let millis = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let entropy = UUID().uuidString.prefix(8)
        return "clip-\(millis)-\(entropy)-\(stem).m4a"
    }

    // MARK: How much of a file can ride along

    /// What an audio-carrying result can attach: the whole file, or a window
    /// of it.
    enum EarPlan: Equatable {
        /// Short enough to encode entire.
        case whole
        /// Too long for the byte cap — attach this many seconds from the
        /// start and SAY so.
        case window(seconds: Double)
    }

    /// The seconds of AAC that fit in `maxBytes`.
    ///
    /// AAC is variable-rate, so this is the nominal length with a margin
    /// (0.85) for the container and for material that encodes above target.
    /// At the shipped 400 000 B / 64 kbps that is **42 s** — measured
    /// 2026-09-02: a 136.7 s freeze render encoded whole came to 1.0 MB and
    /// was DROPPED, and the 8 s window `logic_get_audio_clip` writes of loud
    /// material came to 50 476 B (6.3 KB/s, well inside the 8 KB/s nominal).
    static func earWindowCapSeconds(maxBytes: Int, bitrate: Int = AudioClip.bitrate) -> Double {
        guard maxBytes > 0, bitrate > 0 else { return 0 }
        let bytesPerSecond = Double(bitrate) / 8
        return (Double(maxBytes) / bytesPerSecond * 0.85).rounded(.down)
    }

    /// Whether a file of `fileSeconds` can be attached whole, decided BEFORE
    /// anything is encoded.
    ///
    /// This is the arithmetic that was missing: `encodeEarCopy` encoded the
    /// whole file and then compared the RESULT to the cap, so a long render
    /// paid a full encode (933–1 004 ms measured 2026-09-02 on 136.7 s) to
    /// produce `nil`. An unknown length (a file this server cannot open)
    /// counts as long: a window is cheap and always yields something, while
    /// a whole-file encode of an unknown length is the exact gamble that
    /// produced silence.
    static func earPlan(
        fileSeconds: Double?, maxBytes: Int = 400_000, bitrate: Int = AudioClip.bitrate
    ) -> EarPlan {
        let cap = earWindowCapSeconds(maxBytes: maxBytes, bitrate: bitrate)
        guard let fileSeconds, fileSeconds.isFinite, fileSeconds > 0 else {
            return .window(seconds: cap)
        }
        return fileSeconds <= cap ? .whole : .window(seconds: cap)
    }

    /// How long an audio file is, from its header alone — no decoding.
    ///
    /// `audioFileMetrics` already reports `frames`, but only for AIFF/AIFC and
    /// only after reading and measuring every sample; this answers the one
    /// question the ear-copy decision asks, for every format AVFoundation
    /// opens, and returns nil rather than guessing when it opens none.
    static func seconds(ofFile path: String) -> Double? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
            return nil
        }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return (Double(file.length) / rate * 1000).rounded() / 1000
    }

    // MARK: Read, mix, encode

    /// What one written clip turned out to be. Every number here is measured
    /// off the audio that was actually written, not off the request.
    struct Clip {
        let path: String
        let startSeconds: Double
        let durationSeconds: Double
        let sourceSeconds: Double
        let sourceChannels: Int
        let sourceSampleRate: Double
        let encodeSampleRate: Double
        /// The file ended before the requested window did.
        let truncated: Bool
    }

    /// Cuts `[startSeconds, startSeconds + durationSeconds)` out of
    /// `sourcePath`, mixes it to mono and writes it to `destination` as AAC.
    ///
    /// Throws a `Fault` naming the ONE thing that was wrong. A window or format
    /// refusal happens before the destination is touched; an encoder failure
    /// can leave a partial `.m4a` behind, which is why the caller sweeps the
    /// destination on every throwing path rather than trusting this one.
    static func write(
        sourcePath: String, startSeconds: Double, durationSeconds: Double, destination: URL
    ) throws -> Clip {
        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: URL(fileURLWithPath: sourcePath))
        } catch {
            throw Fault.unreadable(
                path: sourcePath,
                detail: (error as NSError).localizedDescription
            )
        }
        let readFormat = source.processingFormat
        let sourceRate = readFormat.sampleRate
        let channels = Int(readFormat.channelCount)
        guard sourceRate > 0, channels > 0, source.length > 0 else {
            throw Fault.emptySource(path: sourcePath)
        }
        let window: Window
        switch Self.window(
            startSeconds: startSeconds, durationSeconds: durationSeconds,
            sampleRate: sourceRate, totalFrames: source.length
        ) {
        case .success(let resolved): window = resolved
        case .failure(let fault): throw fault
        }

        let encodeRate = min(sourceRate, maximumEncodeRate)
        let encoder = try AACEncoder(
            destination: destination, clientRate: sourceRate, encodeRate: encodeRate,
            seconds: window.durationSeconds
        )
        do {
            try pump(source: source, window: window, readFormat: readFormat, into: encoder)
        } catch {
            encoder.close()
            throw error
        }
        // Closed - so the AAC stream is flushed and the moov atom written -
        // before anyone measures or reads the result.
        encoder.close()
        return Clip(
            path: destination.path,
            startSeconds: window.startSeconds,
            durationSeconds: window.durationSeconds,
            sourceSeconds: (Double(source.length) / sourceRate * 1000).rounded() / 1000,
            sourceChannels: channels,
            sourceSampleRate: sourceRate,
            encodeSampleRate: encodeRate,
            truncated: window.truncated
        )
    }

    /// Seeks to the window, decodes it a chunk at a time, mixes each chunk to
    /// mono and writes it. Only the window is decoded: a 2.8 MB slice of a
    /// 50 MB master no longer costs a 50 MB read.
    private static func pump(
        source: AVAudioFile, window: Window, readFormat: AVAudioFormat, into encoder: AACEncoder
    ) throws {
        let chunk: AVAudioFrameCount = 16_384
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: chunk) else {
            throw Fault.encoderRefused(detail: "could not allocate the decode buffer")
        }
        var mono = [Float](repeating: 0, count: Int(chunk))

        source.framePosition = window.startFrame
        var remaining = window.frameCount
        while remaining > 0 {
            let want = AVAudioFrameCount(min(Int64(chunk), remaining))
            do {
                try source.read(into: readBuffer, frameCount: want)
            } catch {
                throw Fault.unreadable(
                    path: source.url.path, detail: (error as NSError).localizedDescription
                )
            }
            let got = Int(readBuffer.frameLength)
            // A short read at the end of a compressed file is the file
            // telling the truth about its own length; stop, do not spin.
            guard got > 0 else { break }
            remaining -= Int64(got)
            mixToMono(from: readBuffer, into: &mono, frames: got)
            try encoder.write(&mono, frames: got)
        }
    }

    /// The mono mixdown, ours and explicit: the straight average of the
    /// source channels. `afconvert -c 1` used to do this, and refused
    /// (`'cclo'` -66564) on every source that declared a channel layout —
    /// which is every `.m4a` this server writes and every raw Logic AIFF.
    private static func mixToMono(
        from source: AVAudioPCMBuffer, into mono: inout [Float], frames: Int
    ) {
        guard let input = source.floatChannelData else { return }
        let channels = Int(source.format.channelCount)
        if channels == 1 {
            mono.withUnsafeMutableBufferPointer { $0.baseAddress?.update(from: input[0], count: frames) }
            return
        }
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += input[channel][frame] }
            mono[frame] = sum * scale
        }
    }

    // MARK: - The encoder

    /// A 64 kbps mono AAC `.m4a` writer, on `ExtAudioFile`.
    ///
    /// `AVAudioFile(forWriting:settings:)` is the obvious API and the wrong
    /// one: measured 2026-09-02, it IGNORES `AVEncoderBitRateKey` (64 kbps
    /// asked, 103 kbps written — 103,724 B for the 8 s clip afconvert wrote in
    /// 50,476 B), and no `AVEncoderBitRateStrategyKey` fixes it. Bytes are the
    /// first-class cost of a tool that returns audio inline, so the encode
    /// goes through `ExtAudioFile`, where the bitrate can be set on the
    /// underlying converter — and where the reserved-metadata size can be set
    /// too: without that, an 8 s clip carries a 55 KB `free` atom and comes
    /// out twice the size it should be. With both, this writes the SAME
    /// 50,476 B afconvert did, in process, with no subprocess to spawn.
    private final class AACEncoder {
        private var file: ExtAudioFileRef?

        init(destination: URL, clientRate: Double, encodeRate: Double, seconds: Double) throws {
            var target = AudioStreamBasicDescription(
                mSampleRate: encodeRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
            )
            var created: ExtAudioFileRef?
            try check(
                ExtAudioFileCreateWithURL(
                    destination as CFURL, kAudioFileM4AType, &target, nil,
                    AudioFileFlags.eraseFile.rawValue, &created
                ),
                "creating the .m4a"
            )
            guard let created else {
                throw Fault.encoderRefused(detail: "the encoder returned no file")
            }
            file = created
            // Float32 mono at the SOURCE rate: ExtAudioFile does the sample
            // rate conversion itself when the encode rate differs, so nothing
            // above resamples by hand.
            var client = AudioStreamBasicDescription(
                mSampleRate: clientRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
            )
            try check(
                ExtAudioFileSetProperty(
                    created, kExtAudioFileProperty_ClientDataFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client
                ),
                "setting the client format"
            )
            // The converter exists only once the client format is set.
            var converter: AudioConverterRef?
            var converterSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
            try check(
                ExtAudioFileGetProperty(
                    created, kExtAudioFileProperty_AudioConverter, &converterSize, &converter
                ),
                "reaching the AAC converter"
            )
            if let converter {
                var rate = UInt32(AudioClip.bitrate)
                try check(
                    AudioConverterSetProperty(
                        converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate
                    ),
                    "setting the 64 kbps bitrate"
                )
            }
            // Right-size the reserved metadata area, or the clip doubles.
            var audioFile: AudioFileID?
            var audioFileSize = UInt32(MemoryLayout<AudioFileID?>.size)
            if ExtAudioFileGetProperty(
                created, kExtAudioFileProperty_AudioFile, &audioFileSize, &audioFile
            ) == noErr, let audioFile {
                var reserve = Float64(max(seconds, 1))
                _ = AudioFileSetProperty(
                    audioFile, kAudioFilePropertyReserveDuration,
                    UInt32(MemoryLayout<Float64>.size), &reserve
                )
            }
            // Hands the converter's new settings back to ExtAudioFile; without
            // it the bitrate above is set on a converter the file has already
            // configured around.
            var configuration: UnsafeRawPointer?
            try check(
                withUnsafePointer(to: &configuration) { pointer in
                    ExtAudioFileSetProperty(
                        created, kExtAudioFileProperty_ConverterConfig,
                        UInt32(MemoryLayout<UnsafeRawPointer?>.size), pointer
                    )
                },
                "applying the converter settings"
            )
        }

        func write(_ samples: inout [Float], frames: Int) throws {
            guard let file, frames > 0 else { return }
            let status = samples.withUnsafeMutableBufferPointer { pointer -> OSStatus in
                guard let base = pointer.baseAddress else { return noErr }
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(base)
                    )
                )
                return ExtAudioFileWrite(file, UInt32(frames), &list)
            }
            try check(status, "encoding \(frames) frames")
        }

        func close() {
            if let file { ExtAudioFileDispose(file) }
            file = nil
        }

        deinit { close() }

        private func check(_ status: OSStatus, _ what: String) throws {
            guard status != noErr else { return }
            throw Fault.encoderRefused(detail: "\(what) failed (OSStatus \(status))")
        }
    }
}
