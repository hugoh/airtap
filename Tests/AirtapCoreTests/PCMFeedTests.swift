import XCTest
@testable import AirtapCore

final class PCMFeedTests: XCTestCase {
    private func sine(frames: Int, rate: Double, frequency: Double = 1000, amplitude: Float = 0.5, offset: Int = 0) -> [Float] {
        (0..<frames).flatMap { index -> [Float] in
            let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(index + offset) / rate))
            return [value, value]
        }
    }

    private func samples(_ packets: Data) -> [Int16] {
        stride(from: 0, to: packets.count - 1, by: 2).map {
            Int16(bitPattern: UInt16(packets[packets.startIndex + $0]) << 8 | UInt16(packets[packets.startIndex + $0 + 1]))
        }
    }

    private func leftChannel(_ packets: Data) -> [Int16] {
        let all = samples(packets)
        return stride(from: 0, to: all.count, by: 2).map { all[$0] }
    }

    private func frequency(of left: some Collection<Int16>) -> Double {
        let crossings = zip(left, left.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        return Double(crossings) / (Double(left.count) / 44100)
    }

    private func push(_ samples: [Float], into feed: PCMFeed) {
        samples.withUnsafeBufferPointer { feed.push($0.baseAddress!, frames: samples.count / 2) }
    }

    private let silentPacket = Data(repeating: 0, count: 352 * 4)

    func testResamplesToBigEndian44k() {
        let feed = PCMFeed(inputRate: 48000, prebufferSeconds: 1, maxBufferedSeconds: 2)
        push(sine(frames: 48000, rate: 48000), into: feed)

        var output = Data()
        for _ in 0..<100 { output += feed.readPacket(frames: 352) }
        XCTAssertEqual(output.count, 100 * 352 * 4)

        let left = leftChannel(output).dropFirst(2000)
        XCTAssertEqual(Double(left.map { abs(Int($0)) }.max() ?? 0), 0.5 * 32767, accuracy: 0.03 * 32767)
        XCTAssertEqual(frequency(of: left), 1000, accuracy: 20)
    }

    func testStarvedFeedYieldsSilence() {
        XCTAssertEqual(PCMFeed(inputRate: 48000).readPacket(frames: 352), silentPacket)
    }

    func testOverflowKeepsNewestAudio() {
        let feed = PCMFeed(inputRate: 44100, maxBufferedSeconds: 0.1)
        push([Float](repeating: 0.9, count: 2 * 44100), into: feed)
        push([Float](repeating: -0.5, count: 2 * 4410), into: feed)
        XCTAssertLessThanOrEqual(feed.stats.bufferedMilliseconds, 100)
        XCTAssertTrue(samples(feed.readPacket(frames: 352)).prefix(4).allSatisfy { $0 < 0 })
    }

    func testStaysSilentUntilTheCushionIsBuilt() {
        let feed = PCMFeed(inputRate: 44100, prebufferSeconds: 0.1, maxBufferedSeconds: 1)
        push(sine(frames: 2205, rate: 44100), into: feed)
        XCTAssertEqual(feed.readPacket(frames: 352), silentPacket)
        XCTAssertEqual(feed.stats.bufferedMilliseconds, 50, "audio is kept while the cushion builds")
        XCTAssertEqual(feed.stats.underruns, 0, "waiting for the cushion is not an underrun")

        push(sine(frames: 2646, rate: 44100, offset: 2205), into: feed)
        XCTAssertNotEqual(feed.readPacket(frames: 352), silentPacket)
    }

    func testAnUnderrunRebuildsTheCushionBeforePlayingAgain() {
        let feed = PCMFeed(inputRate: 44100, prebufferSeconds: 0.1, maxBufferedSeconds: 1)
        push(sine(frames: 4410, rate: 44100), into: feed)
        for _ in 0..<20 { _ = feed.readPacket(frames: 352) }
        XCTAssertEqual(feed.stats.underruns, 1)

        push(sine(frames: 1000, rate: 44100), into: feed)
        XCTAssertEqual(feed.readPacket(frames: 352), silentPacket, "one glitch, then silence until the cushion is back")
        XCTAssertEqual(feed.stats.underruns, 1)
    }

    func testPlanarPushInterleavesChannels() {
        let feed = PCMFeed(inputRate: 44100, prebufferSeconds: 0.05, maxBufferedSeconds: 1)
        let left = [Float](repeating: 0.5, count: 4410)
        let right = [Float](repeating: -0.5, count: 4410)
        feed.push(left: left, right: right, frames: 4410)
        _ = feed.readPacket(frames: 352)
        let second = samples(feed.readPacket(frames: 352))
        XCTAssertGreaterThan(second[200], 10000)
        XCTAssertLessThan(second[201], -10000)
    }

    func testReconfigureSwitchesTheInputRate() {
        let feed = PCMFeed(inputRate: 48000, prebufferSeconds: 1, maxBufferedSeconds: 2)
        push(sine(frames: 48000, rate: 48000), into: feed)
        _ = feed.readPacket(frames: 352)

        feed.reconfigure(inputRate: 44100)
        XCTAssertEqual(feed.stats.bufferedMilliseconds, 0, "audio at the old rate is discarded")
        push(sine(frames: 44100, rate: 44100), into: feed)
        var output = Data()
        for _ in 0..<100 { output += feed.readPacket(frames: 352) }
        XCTAssertEqual(frequency(of: leftChannel(output).dropFirst(2000)), 1000, accuracy: 20)
    }

    /// Replays a tap delivering 512-frame chunks against a sender pulling 352-frame packets, in virtual time.
    private func simulate(seconds: Double, producerRate: Double, feed: PCMFeed, chunk: Int = 512) {
        let block = [Float](repeating: 0.25, count: chunk * 2)
        let produceEvery = Double(chunk) / producerRate
        let consumeEvery = 352.0 / 44100
        var nextProduce = 0.0
        var nextConsume = 0.0
        while min(nextProduce, nextConsume) < seconds {
            if nextProduce <= nextConsume {
                push(block, into: feed)
                nextProduce += produceEvery
            } else {
                _ = feed.readPacket(frames: 352)
                nextConsume += consumeEvery
            }
        }
    }

    func testChunkedRealTimeDeliveryNeverUnderruns() {
        let feed = PCMFeed(inputRate: 48000)
        simulate(seconds: 20, producerRate: 48000, feed: feed)
        XCTAssertEqual(feed.stats.underruns, 0)
        XCTAssertEqual(feed.stats.overflows, 0)
    }

    func testAFastSourceClockIsAbsorbedByDroppingFrames() {
        let feed = PCMFeed(inputRate: 48000)
        simulate(seconds: 600, producerRate: 48000 * 1.001, feed: feed)
        XCTAssertEqual(feed.stats.underruns, 0)
        XCTAssertEqual(feed.stats.overflows, 0, "drift must be corrected before the buffer overflows")
        XCTAssertGreaterThan(feed.stats.driftCorrections, 0)
    }

    func testASlowSourceClockIsAbsorbedByRepeatingFrames() {
        let feed = PCMFeed(inputRate: 48000)
        simulate(seconds: 600, producerRate: 48000 * 0.999, feed: feed)
        XCTAssertEqual(feed.stats.underruns, 0, "drift must be corrected before the cushion runs dry")
        XCTAssertEqual(feed.stats.overflows, 0)
        XCTAssertGreaterThan(feed.stats.driftCorrections, 0)
    }

    func testBacklogWhileNothingIsReadIsNotReportedAsOverflow() {
        let feed = PCMFeed(inputRate: 44100, prebufferSeconds: 0.05, maxBufferedSeconds: 0.1)
        for _ in 0..<10 { push([Float](repeating: 0.1, count: 2 * 4410), into: feed) }
        XCTAssertEqual(feed.stats.overflows, 0, "before playback starts, dropping old audio is expected")

        _ = feed.readPacket(frames: 352)
        for _ in 0..<10 { push([Float](repeating: 0.1, count: 2 * 4410), into: feed) }
        XCTAssertGreaterThan(feed.stats.overflows, 0, "during playback it means the reader fell behind")
    }
}
