import Foundation

public struct RunningApp: Equatable {
    public let bundleID: String
    public let name: String
    /// An app with a Dock icon, as opposed to a menu bar or background agent.
    public let isRegular: Bool

    public init(bundleID: String, name: String, isRegular: Bool = true) {
        self.bundleID = bundleID
        self.name = name
        self.isRegular = isRegular
    }
}

/// An app a person recognises, as opposed to the audio helper processes Core Audio reports.
public struct ListedApp: Identifiable, Equatable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let isPlaying: Bool

    public init(bundleID: String, name: String, isPlaying: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.isPlaying = isPlaying
    }
}

public enum AppCatalog {
    /// Apple Music clients such as Albums hand playback to this system service, so their own process stays silent.
    public static let musicPlayerService = ListedApp(bundleID: "com.apple.MediaPlayer.RemotePlayerService", name: "Apple Music playback", isPlaying: false)

    /// Folds audio processes (`com.electron.pocket-casts.helper`, ...) into the running apps that own them and hides
    /// the ones nobody owns, such as system daemons. Background agents show up only while they are playing, and
    /// `excluding` (the app itself) never does, and `keeping` (the app being streamed) always does. Playing apps come first.
    public static func listed(audio: [AudioApp], running: [RunningApp], excluding: String? = nil, keeping: String? = nil) -> [ListedApp] {
        var playing: [String: Bool] = [:]
        var owners: [String: RunningApp] = [:]
        for process in audio {
            guard let owner = owner(of: process.bundleID, in: running), owner.bundleID != excluding else { continue }
            playing[owner.bundleID] = (playing[owner.bundleID] ?? false) || process.isPlaying
            owners[owner.bundleID] = owner
        }
        var visible = playing.filter { owners[$0.key]?.isRegular == true || $0.value }
        // The app being streamed must not vanish from the list just because it paused and its audio process went away.
        if let keeping, visible[keeping] == nil, let app = running.first(where: { $0.bundleID == keeping }) {
            visible[keeping] = false
            owners[keeping] = app
        }
        var apps = visible.map { ListedApp(bundleID: $0.key, name: owners[$0.key]?.name ?? $0.key, isPlaying: $0.value) }
        if let service = audio.first(where: { $0.bundleID == musicPlayerService.bundleID }) {
            apps.append(ListedApp(bundleID: service.bundleID, name: musicPlayerService.name, isPlaying: service.isPlaying))
        }
        return apps
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
    }

    /// The app whose bundle id is the longest prefix of the process's, on a dot boundary.
    private static func owner(of processID: String, in running: [RunningApp]) -> RunningApp? {
        running
            .filter { processID == $0.bundleID || processID.hasPrefix($0.bundleID + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }
    }
}

public enum SpeakerChoice {
    /// What to have selected after a scan: the user's own pick this session if it is still there, else the speaker
    /// used last time if it showed up, else whatever was selected, else the first one found.
    public static func select(saved: String?, available: [String], current: String, userChose: Bool) -> String {
        if userChose, available.contains(current) { return current }
        if let saved, available.contains(saved) { return saved }
        if available.contains(current) { return current }
        return available.first ?? ""
    }
}

public enum BundleMatch {
    /// Which of `bundleIDs` a person means by `query`. A full bundle id selects that app and its helpers (`.helper`, ...)
    /// and nothing else; anything shorter is a case-insensitive substring, which is what the command line accepts.
    public static func indices(of bundleIDs: [String], matching query: String) -> [Int] {
        let exact = bundleIDs.indices.filter {
            bundleIDs[$0].caseInsensitiveCompare(query) == .orderedSame || bundleIDs[$0].lowercased().hasPrefix(query.lowercased() + ".")
        }
        if !exact.isEmpty { return exact }
        return bundleIDs.indices.filter { bundleIDs[$0].localizedCaseInsensitiveContains(query) }
    }
}
