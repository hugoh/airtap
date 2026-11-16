import XCTest
@testable import AirtapCore

final class HealthWindowTests: XCTestCase {
    private func sample(gaps: Int = 0, dropped: Int = 0, resends: Int = 0, keepAliveFailures: Int = 0, late: Int = 0) -> HealthSample {
        HealthSample(gaps: gaps, dropped: dropped, resends: resends, keepAliveFailures: keepAliveFailures, latenessMilliseconds: late)
    }

    private func feed(_ window: inout HealthWindow, seconds: Range<Int>, _ make: (Int) -> HealthSample) {
        for second in seconds { window.record(make(second), at: TimeInterval(second)) }
    }

    func testAQuietStreamIsGood() {
        var window = HealthWindow()
        feed(&window, seconds: 0..<30) { _ in sample() }
        XCTAssertEqual(window.assess(), HealthAssessment(level: .good, problems: []))
    }

    func testNewGapsInTheLastMinuteMakeItUnstable() {
        var window = HealthWindow()
        feed(&window, seconds: 0..<30) { sample(gaps: $0 >= 10 ? 3 : 0) }
        let assessment = window.assess()
        XCTAssertEqual(assessment.level, .degraded)
        XCTAssertEqual(assessment.problems, ["3 audio gaps in the last minute"])
    }

    func testOldProblemsAgeOut() {
        var window = HealthWindow()
        feed(&window, seconds: 0..<5) { sample(gaps: $0 >= 2 ? 1 : 0) }
        feed(&window, seconds: 5..<90) { _ in sample(gaps: 1) }
        XCTAssertEqual(window.assess().level, .good, "a gap more than a minute ago no longer counts")
    }

    func testACounterThatRestartsWithANewSessionIsNotNegative() {
        var window = HealthWindow()
        feed(&window, seconds: 0..<5) { _ in sample(gaps: 7) }
        feed(&window, seconds: 5..<10) { _ in sample(gaps: 0) }
        XCTAssertEqual(window.assess().level, .good, "a fresh session starting from zero is not a burst of gaps")
        window.record(sample(gaps: 2), at: 10)
        XCTAssertEqual(window.assess().problems, ["2 audio gaps in the last minute"])
    }

    func testLateSendsAreOnlyAProblemWhenLargeAndRecent() {
        var window = HealthWindow()
        feed(&window, seconds: 0..<5) { _ in sample(late: 60) }
        XCTAssertEqual(window.assess().level, .good)
        window.record(sample(late: 180), at: 5)
        XCTAssertEqual(window.assess().problems, ["Mac was slow sending audio (up to 180 ms late)"])
        feed(&window, seconds: 6..<20) { _ in sample(late: 3) }
        XCTAssertEqual(window.assess().level, .good, "after ten quiet seconds the lateness is forgotten")
    }

    func testAFewResendsAreNormalManyAreNot() {
        var window = HealthWindow()
        feed(&window, seconds: 0..<10) { sample(resends: min($0, 4)) }
        XCTAssertEqual(window.assess().level, .good, "four resends in a minute is ordinary Wi-Fi")
        window.record(sample(resends: 12), at: 10)
        XCTAssertEqual(window.assess().problems, ["12 packets lost on the network and resent"])
    }

    func testSeveralProblemsAreListedMostSevereFirst() {
        var window = HealthWindow()
        window.record(sample(), at: 0)
        window.record(sample(gaps: 2, dropped: 1, resends: 9, keepAliveFailures: 1, late: 150), at: 1)
        let problems = window.assess().problems
        XCTAssertEqual(problems.first, "2 audio gaps in the last minute")
        XCTAssertEqual(problems.count, 5)
    }
}

final class StreamHealthTests: XCTestCase {
    private func health(level: HealthAssessment.Level = .good, problems: [String] = [], silent: Bool = false) -> StreamHealth {
        StreamHealth(
            speaker: "Kitchen", address: "192.168.68.27:7000", assessment: HealthAssessment(level: level, problems: problems),
            pairingMilliseconds: 210, setupMilliseconds: 480, uptimeSeconds: 125, reconnects: 1, lastReconnectReason: "system woke from sleep",
            keepAliveMilliseconds: 14, packetsPerSecond: 125, resendsLastMinute: 2, worstLatenessMilliseconds: 3,
            bufferMilliseconds: 148, targetBufferMilliseconds: 150, gapsLastMinute: 0, droppedLastMinute: 0, driftCorrections: 4,
            inputLevel: 0.2, isSilent: silent, tapSampleRate: 48000
        )
    }

    func testSummaryWhenHealthy() {
        XCTAssertEqual(health().summary, "Streaming to Kitchen · delay ≈ 1.7 s")
    }

    func testSummaryWhenTheAppIsSilentIsNotAFault() {
        let silent = health(silent: true)
        XCTAssertEqual(silent.assessment.level, .good)
        XCTAssertEqual(silent.summary, "Streaming to Kitchen · the app is silent")
    }

    func testSummaryNamesTheTwoMostImportantProblems() {
        let unstable = health(level: .degraded, problems: ["3 audio gaps in the last minute", "2 packets dropped", "slow keep-alives"])
        XCTAssertEqual(unstable.summary, "Unstable: 3 audio gaps in the last minute · 2 packets dropped")
    }

    func testDetailRowsGroupedByWhatAPersonWouldAsk() {
        let sections = health().sections
        XCTAssertEqual(sections.map(\.title), ["Connection", "Stream", "Audio"])
        let rows = Dictionary(uniqueKeysWithValues: sections.flatMap(\.rows).map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Speaker"], "Kitchen (192.168.68.27:7000)")
        XCTAssertEqual(rows["Handshake"], "pairing 210 ms · setup 480 ms")
        XCTAssertEqual(rows["Connected for"], "2 min 5 s")
        XCTAssertEqual(rows["Reconnects"], "1 (last: system woke from sleep)")
        XCTAssertEqual(rows["Keep-alive"], "14 ms")
        XCTAssertEqual(rows["Packets"], "125 per second")
        XCTAssertEqual(rows["Resends (1 min)"], "2")
        XCTAssertEqual(rows["Buffer"], "148 ms of 150 ms")
        XCTAssertEqual(rows["Gaps (1 min)"], "0")
        XCTAssertEqual(rows["Input level"], "0.20 · 48 kHz")
    }

    func testRowsSayWhenThereIsNothingToReportYet() {
        var fresh = health()
        fresh.keepAliveMilliseconds = nil
        fresh.reconnects = 0
        fresh.lastReconnectReason = nil
        let rows = Dictionary(uniqueKeysWithValues: fresh.sections.flatMap(\.rows).map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Keep-alive"], "not yet measured")
        XCTAssertEqual(rows["Reconnects"], "none")
    }

    func testDurationsReadNaturally() {
        XCTAssertEqual(StreamHealth.duration(seconds: 7), "7 s")
        XCTAssertEqual(StreamHealth.duration(seconds: 125), "2 min 5 s")
        XCTAssertEqual(StreamHealth.duration(seconds: 3840), "1 h 4 min")
    }
}

final class HealthReporterTests: XCTestCase {
    private let speaker = Speaker(name: "Kitchen", host: "192.168.68.27", port: 7000)
    private let feed = FeedStats(bufferedMilliseconds: 148, targetMilliseconds: 150, underruns: 0, overflows: 0, driftCorrections: 3)

    private func connection(packets: Int, dropped: Int = 0, late: Double = 3, keepAlive: Int? = 14, reconnects: Int = 0) -> ReconnectingStream.Connection {
        var sender = SenderStats()
        sender.packetsSent = packets
        sender.packetsDropped = dropped
        sender.maxLateMilliseconds = late
        sender.keepAliveMilliseconds = keepAlive
        sender.pairingMilliseconds = 210
        sender.setupMilliseconds = 480
        return ReconnectingStream.Connection(
            speaker: speaker, connectedSince: Date().addingTimeInterval(-125), reconnects: reconnects, lastReconnectReason: nil, sender: sender
        )
    }

    func testNoConnectionMeansNoHealth() {
        var reporter = HealthReporter(speakerName: "Kitchen")
        XCTAssertNil(reporter.report(connection: .init(), feed: feed, inputLevel: 0.2, sampleRate: 48000, now: 0))
    }

    func testReportsTheNumbersTheMenuShows() throws {
        var reporter = HealthReporter(speakerName: "Kitchen")
        let health = try XCTUnwrap(reporter.report(connection: connection(packets: 125), feed: feed, inputLevel: 0.2, sampleRate: 48000, now: 0))
        XCTAssertEqual(health.speaker, "Kitchen")
        XCTAssertEqual(health.address, "192.168.68.27:7000")
        XCTAssertEqual([health.pairingMilliseconds, health.setupMilliseconds, health.keepAliveMilliseconds], [210, 480, 14])
        XCTAssertEqual([health.bufferMilliseconds, health.targetBufferMilliseconds, health.driftCorrections], [148, 150, 3])
        XCTAssertEqual(health.uptimeSeconds, 125, accuracy: 1)
        XCTAssertEqual(health.assessment.level, .good)
        XCTAssertEqual(health.tapSampleRate, 48000)
    }

    func testPacketsPerSecondIsTheDifferenceBetweenTicksAndSurvivesANewSession() throws {
        var reporter = HealthReporter(speakerName: "Kitchen")
        _ = reporter.report(connection: connection(packets: 1000), feed: feed, inputLevel: 0.2, sampleRate: 48000, now: 0)
        let steady = try XCTUnwrap(reporter.report(connection: connection(packets: 1125), feed: feed, inputLevel: 0.2, sampleRate: 48000, now: 1))
        XCTAssertEqual(steady.packetsPerSecond, 125)
        let restarted = try XCTUnwrap(reporter.report(connection: connection(packets: 120), feed: feed, inputLevel: 0.2, sampleRate: 48000, now: 2))
        XCTAssertEqual(restarted.packetsPerSecond, 120, "a new session counts from zero")
    }

    func testProblemsFeedTheAssessment() throws {
        var reporter = HealthReporter(speakerName: "Kitchen")
        _ = reporter.report(connection: connection(packets: 125), feed: feed, inputLevel: 0.2, sampleRate: 48000, now: 0)
        var gappy = feed
        gappy.underruns = 2
        let health = try XCTUnwrap(reporter.report(connection: connection(packets: 250, dropped: 1), feed: gappy, inputLevel: 0.2, sampleRate: 48000, now: 1))
        XCTAssertEqual(health.assessment.level, .degraded)
        XCTAssertEqual(health.gapsLastMinute, 2)
        XCTAssertEqual(health.droppedLastMinute, 1)
    }

    func testTheAppCountsAsSilentOnlyAfterTenQuietSeconds() throws {
        var reporter = HealthReporter(speakerName: "Kitchen")
        var health: StreamHealth?
        for second in 0..<9 { health = reporter.report(connection: connection(packets: 125 * second), feed: feed, inputLevel: 0, sampleRate: 48000, now: TimeInterval(second)) }
        XCTAssertEqual(health?.isSilent, false)
        health = reporter.report(connection: connection(packets: 1125), feed: feed, inputLevel: 0, sampleRate: 48000, now: 9)
        XCTAssertEqual(health?.isSilent, true)
        health = reporter.report(connection: connection(packets: 1250), feed: feed, inputLevel: 0.1, sampleRate: 48000, now: 10)
        XCTAssertEqual(health?.isSilent, false, "any sound ends the silence")
    }
}
