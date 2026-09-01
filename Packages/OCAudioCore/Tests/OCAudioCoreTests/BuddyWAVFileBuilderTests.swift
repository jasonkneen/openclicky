import XCTest
@testable import OCAudioCore

final class BuddyWAVFileBuilderTests: XCTestCase {
    private func u32(_ d: Data, _ offset: Int) -> UInt32 {
        d.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }
    private func u16(_ d: Data, _ offset: Int) -> UInt16 {
        d.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }
    private func ascii(_ d: Data, _ offset: Int) -> String {
        String(decoding: d.subdata(in: offset..<(offset + 4)), as: UTF8.self)
    }

    private let pcm = Data((0..<100).map { UInt8($0 % 256) })

    func testHeaderIsA44ByteCanonicalRIFFWAVE() {
        let wav = BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: pcm, sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(ascii(wav, 0), "RIFF")
        XCTAssertEqual(ascii(wav, 8), "WAVE")
        XCTAssertEqual(ascii(wav, 12), "fmt ")
        XCTAssertEqual(ascii(wav, 36), "data")
    }

    func testChunkSizesAccountForPayload() {
        let wav = BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: pcm, sampleRate: 16_000)
        // RIFF size is everything after the first 8 bytes.
        XCTAssertEqual(u32(wav, 4), UInt32(36 + pcm.count))
        XCTAssertEqual(u32(wav, 16), 16, "PCM fmt chunk is 16 bytes")
        XCTAssertEqual(u16(wav, 20), 1, "format tag 1 = uncompressed PCM")
        XCTAssertEqual(u32(wav, 40), UInt32(pcm.count))
    }

    func testMonoSixteenBitDerivedFields() {
        let wav = BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: pcm, sampleRate: 16_000)
        XCTAssertEqual(u16(wav, 22), 1, "channels")
        XCTAssertEqual(u32(wav, 24), 16_000, "sample rate")
        XCTAssertEqual(u32(wav, 28), 32_000, "byte rate = 16000 * 1 * 16/8")
        XCTAssertEqual(u16(wav, 32), 2, "block align = 1 * 16/8")
        XCTAssertEqual(u16(wav, 34), 16, "bits per sample")
    }

    func testStereoAndDepthAffectByteRateAndBlockAlign() {
        let wav = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: pcm, sampleRate: 44_100, channelCount: 2, bitsPerSample: 24
        )
        XCTAssertEqual(u16(wav, 22), 2)
        XCTAssertEqual(u32(wav, 28), UInt32(44_100 * 2 * 3))
        XCTAssertEqual(u16(wav, 32), 6)
        XCTAssertEqual(u16(wav, 34), 24)
    }

    func testPayloadIsAppendedVerbatim() {
        let wav = BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: pcm, sampleRate: 16_000)
        XCTAssertEqual(wav.subdata(in: 44..<wav.count), pcm)
    }

    func testEmptyPayloadStillProducesAValidHeader() {
        let wav = BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: Data(), sampleRate: 8_000)
        XCTAssertEqual(wav.count, 44)
        XCTAssertEqual(u32(wav, 40), 0)
        XCTAssertEqual(u32(wav, 4), 36)
    }
}
