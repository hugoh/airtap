import XCTest
@testable import AirtapCore

final class AppCatalogTests: XCTestCase {
    private let running = [
        RunningApp(bundleID: "com.electron.pocket-casts", name: "Pocket Casts"),
        RunningApp(bundleID: "com.apple.Music", name: "Music"),
        RunningApp(bundleID: "com.google.Chrome", name: "Google Chrome"),
        RunningApp(bundleID: "com.google.Chrome.canary", name: "Chrome Canary"),
    ]

    private func audio(_ entries: [(String, Bool)]) -> [AudioApp] {
        entries.map { AudioApp(bundleID: $0.0, isPlaying: $0.1) }
    }

    func testAHelperProcessIsListedAsItsApp() {
        let listed = AppCatalog.listed(audio: audio([("com.electron.pocket-casts.helper", true)]), running: running)
        XCTAssertEqual(listed, [ListedApp(bundleID: "com.electron.pocket-casts", name: "Pocket Casts", isPlaying: true)])
    }

    func testSystemDaemonsWithoutAnAppAreHidden() {
        let listed = AppCatalog.listed(audio: audio([("com.apple.audiomxd", false), ("systemsoundserverd", false), ("com.apple.Music", false)]), running: running)
        XCTAssertEqual(listed.map(\.name), ["Music"])
    }

    func testTheSystemMusicPlayerIsListedBecauseAppsLikeAlbumsPlayThroughIt() {
        let listed = AppCatalog.listed(audio: audio([("com.apple.MediaPlayer.RemotePlayerService", true), ("com.apple.audiomxd", false)]), running: running)
        XCTAssertEqual(listed, [ListedApp(bundleID: "com.apple.MediaPlayer.RemotePlayerService", name: "Apple Music playback", isPlaying: true)])
    }

    func testAppIsPlayingIfAnyOfItsProcessesIs() {
        let listed = AppCatalog.listed(
            audio: audio([("com.google.Chrome", false), ("com.google.Chrome.helper", true), ("com.google.Chrome.helper.Renderer", false)]),
            running: running
        )
        XCTAssertEqual(listed.count, 1)
        XCTAssertTrue(listed[0].isPlaying)
    }

    func testTheMostSpecificAppWins() {
        let listed = AppCatalog.listed(audio: audio([("com.google.Chrome.canary.helper", true)]), running: running)
        XCTAssertEqual(listed.map(\.name), ["Chrome Canary"])
    }

    func testAPrefixWithoutADotBoundaryIsNotAMatch() {
        let listed = AppCatalog.listed(audio: audio([("com.apple.Musicals", true)]), running: running)
        XCTAssertTrue(listed.isEmpty)
    }

    func testBackgroundAgentsAreListedOnlyWhileTheyPlay() {
        let agents = running + [
            RunningApp(bundleID: "com.apple.PowerChime", name: "PowerChime", isRegular: false),
            RunningApp(bundleID: "org.hammerspoon.Hammerspoon", name: "Hammerspoon", isRegular: false),
        ]
        let idle = AppCatalog.listed(audio: audio([("com.apple.PowerChime", false), ("org.hammerspoon.Hammerspoon", true), ("com.apple.Music", false)]), running: agents)
        XCTAssertEqual(idle.map(\.name), ["Hammerspoon", "Music"])
    }

    func testTheAppItselfIsNeverListed() {
        let withSelf = running + [RunningApp(bundleID: "net.hugoh.airtap", name: "Airtap")]
        let listed = AppCatalog.listed(audio: audio([("net.hugoh.airtap", true), ("com.apple.Music", false)]), running: withSelf, excluding: "net.hugoh.airtap")
        XCTAssertEqual(listed.map(\.name), ["Music"])
    }

    func testTheStreamedAppStaysListedEvenWhenItsAudioProcessIsGone() {
        let listed = AppCatalog.listed(audio: audio([("com.apple.Music", false)]), running: running, keeping: "com.apple.Safari" )
        XCTAssertEqual(listed.map(\.name), ["Music"], "an app that is not running at all cannot be listed by name")

        let withSafari = running + [RunningApp(bundleID: "com.apple.Safari", name: "Safari")]
        let kept = AppCatalog.listed(audio: audio([("com.apple.Music", false)]), running: withSafari, keeping: "com.apple.Safari")
        XCTAssertEqual(kept.map(\.name), ["Music", "Safari"])
        XCTAssertEqual(kept.last?.isPlaying, false)
    }

    func testKeepingDoesNotDuplicateAnAppThatIsAlreadyListed() {
        let listed = AppCatalog.listed(audio: audio([("com.apple.Music", true)]), running: running, keeping: "com.apple.Music")
        XCTAssertEqual(listed.map(\.name), ["Music"])
        XCTAssertTrue(listed[0].isPlaying)
    }

    func testPlayingAppsComeFirstThenAlphabetical() {
        let listed = AppCatalog.listed(
            audio: audio([("com.google.Chrome", false), ("com.apple.Music", false), ("com.electron.pocket-casts.helper", true)]),
            running: running
        )
        XCTAssertEqual(listed.map(\.name), ["Pocket Casts", "Google Chrome", "Music"])
    }
}

final class SpeakerChoiceTests: XCTestCase {
    private let available = ["Bedroom", "Kitchen", "Living Room"]

    func testRestoresTheSavedSpeakerWhenItAppears() {
        XCTAssertEqual(SpeakerChoice.select(saved: "Kitchen", available: available, current: "Bedroom", userChose: false), "Kitchen")
    }

    func testKeepsWhatTheUserPickedThisSession() {
        XCTAssertEqual(SpeakerChoice.select(saved: "Kitchen", available: available, current: "Bedroom", userChose: true), "Bedroom")
    }

    func testFallsBackWhenTheSavedSpeakerIsOffline() {
        XCTAssertEqual(SpeakerChoice.select(saved: "Garage", available: available, current: "Kitchen", userChose: false), "Kitchen")
        XCTAssertEqual(SpeakerChoice.select(saved: "Garage", available: available, current: "", userChose: false), "Bedroom")
    }

    func testAPickedSpeakerThatDisappearedIsReplaced() {
        XCTAssertEqual(SpeakerChoice.select(saved: nil, available: ["Kitchen"], current: "Bedroom", userChose: true), "Kitchen")
    }

    func testNothingAvailableMeansNoSelection() {
        XCTAssertEqual(SpeakerChoice.select(saved: "Kitchen", available: [], current: "Kitchen", userChose: true), "")
    }
}

final class BundleMatchTests: XCTestCase {
    private let processes = [
        "com.apple.Music", "com.apple.Music.helper", "com.apple.MusicRecognitionAgent", "com.electron.pocket-casts.helper", "systemsoundserverd",
    ]

    private func matches(_ query: String) -> [String] {
        BundleMatch.indices(of: processes, matching: query).map { processes[$0] }
    }

    func testAFullBundleIdMatchesItselfAndItsHelpersOnly() {
        XCTAssertEqual(matches("com.apple.Music"), ["com.apple.Music", "com.apple.Music.helper"])
    }

    func testAPartialNameStillMatchesBySubstring() {
        XCTAssertEqual(matches("pocket-casts"), ["com.electron.pocket-casts.helper"])
        XCTAssertEqual(matches("SOUNDSERVER"), ["systemsoundserverd"])
    }

    func testNothingMatches() {
        XCTAssertTrue(matches("nonexistent").isEmpty)
    }
}
