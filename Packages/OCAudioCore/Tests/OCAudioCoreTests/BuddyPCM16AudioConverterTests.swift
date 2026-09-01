import AVFoundation
import XCTest
@testable import OCAudioCore

final class BuddyPCM16AudioConverterTests: XCTestCase {
    /// A float32 mono buffer of `frames` samples at `sampleRate`, filled with a
    /// low-frequency sine so the conversion has real signal to resample.
    private func makeFloatBuffer(sampleRate: Double, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<Int(frames) {
            channel[i] = Float(sin(Double(i) * 2.0 * .pi * 440.0 / sampleRate)) * 0.5
        }
        return buffer
    }

    func testDownsamplesToPCM16AtTargetRate() throws {
        let converter = BuddyPCM16AudioConverter(targetSampleRate: 16_000)
        let buffer = try makeFloatBuffer(sampleRate: 48_000, frames: 4_800) // 100 ms
        let data = try XCTUnwrap(converter.convertToPCM16Data(from: buffer))
        XCTAssertEqual(data.count % 2, 0, "16-bit samples must not be truncated mid-frame")

        // 100 ms of 48 kHz input is 1600 frames at 16 kHz. Each call feeds the
        // converter once and then answers .noDataNow, so the resampler's tail is
        // never drained and the chunk comes back slightly short (~1360 frames,
        // about 15 ms). That is the shipped behaviour for every streaming
        // provider; this pins it so a change to the conversion loop is visible.
        let frames = data.count / 2
        XCTAssertLessThanOrEqual(frames, 1_600, "cannot produce more than the ideal frame count")
        XCTAssertGreaterThan(frames, 1_200, "lost far more than the known resampler tail: \(frames) frames")
    }

    func testSameRateConversionPreservesFrameCount() throws {
        let converter = BuddyPCM16AudioConverter(targetSampleRate: 16_000)
        let buffer = try makeFloatBuffer(sampleRate: 16_000, frames: 1_600)
        let data = try XCTUnwrap(converter.convertToPCM16Data(from: buffer))
        XCTAssertEqual(data.count, 3_200)
    }

    func testOutputIsNonSilentForNonSilentInput() throws {
        let converter = BuddyPCM16AudioConverter(targetSampleRate: 16_000)
        let buffer = try makeFloatBuffer(sampleRate: 16_000, frames: 1_600)
        let data = try XCTUnwrap(converter.convertToPCM16Data(from: buffer))
        XCTAssertTrue(data.contains { $0 != 0 }, "conversion produced silence from a sine wave")
    }

    func testConverterIsRebuiltWhenInputFormatChanges() throws {
        // The converter caches an AVAudioConverter keyed on the input format; a
        // provider whose tap format changes mid-session must still get output.
        let converter = BuddyPCM16AudioConverter(targetSampleRate: 16_000)
        let first = try XCTUnwrap(converter.convertToPCM16Data(from: try makeFloatBuffer(sampleRate: 48_000, frames: 4_800)))
        let second = try XCTUnwrap(converter.convertToPCM16Data(from: try makeFloatBuffer(sampleRate: 44_100, frames: 4_410)))
        let third = try XCTUnwrap(converter.convertToPCM16Data(from: try makeFloatBuffer(sampleRate: 48_000, frames: 4_800)))
        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(second.isEmpty)
        XCTAssertFalse(third.isEmpty)
    }

    func testEmptyBufferYieldsNoData() throws {
        let converter = BuddyPCM16AudioConverter(targetSampleRate: 16_000)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 0
        XCTAssertNil(converter.convertToPCM16Data(from: buffer), "zero frames must yield nil, not empty Data")
    }

    func testRoundTripThroughWAVBuilderProducesPlayableContainer() throws {
        let converter = BuddyPCM16AudioConverter(targetSampleRate: 16_000)
        let pcm = try XCTUnwrap(converter.convertToPCM16Data(from: try makeFloatBuffer(sampleRate: 16_000, frames: 1_600)))
        let wav = BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: pcm, sampleRate: 16_000)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // AVAudioFile parsing the container is the real proof the header is right.
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, Int64(pcm.count / 2))
    }
}
