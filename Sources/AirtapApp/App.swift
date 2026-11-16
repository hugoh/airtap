import AirtapCore
import AppKit
import SwiftUI

@MainActor
final class Model: ObservableObject {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/airtap.log")

    private static let lastSpeakerKey = "lastSpeaker"
    private static let iconSize = NSSize(width: 16, height: 16)

    @Published var apps: [ListedApp] = []
    @Published var speakers: [Speaker] = []
    @Published var app = ""
    @Published var speaker = "" {
        didSet {
            // Only a person's own pick is worth remembering, not the default chosen after a scan.
            guard !isApplyingSelection, speaker != oldValue else { return }
            userChoseSpeaker = true
            UserDefaults.standard.set(speaker, forKey: Self.lastSpeakerKey)
        }
    }
    private(set) var icons: [String: NSImage] = [:]
    private var userChoseSpeaker = false
    private var isApplyingSelection = false
    @Published var volume = 30.0
    @Published var status = "Idle"
    @Published var health: StreamHealth?
    @Published var failed = false
    @Published var showDetails = false
    @Published var isScanning = false
    @Published var isStopping = false
    @Published var debug = Log.isDebugEnabled {
        didSet { Log.isDebugEnabled = debug }
    }
    private var session: StreamSession?

    var isStreaming: Bool { session != nil }

    init() {
        let file = Log.fileSink(url: Self.logURL, maxBytes: 2 * 1024 * 1024)
        Log.sink = { line in
            file(line)
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    func refresh() {
        refreshApps()
        guard !isScanning else { return }
        isScanning = true
        Thread.detachNewThread {
            let found = SpeakerDiscovery.discover(timeout: 4)
            DispatchQueue.main.async {
                self.speakers = found
                self.isApplyingSelection = true
                let saved = UserDefaults.standard.string(forKey: Self.lastSpeakerKey)
                self.speaker = SpeakerChoice.select(saved: saved, available: found.map(\.name), current: self.speaker, userChose: self.userChoseSpeaker)
                self.isApplyingSelection = false
                Log.info("app", "found \(found.count) speakers; selected '\(self.speaker)' (last used: '\(saved ?? "none")')")
                self.isScanning = false
            }
        }
    }

    private func refreshApps() {
        let running = NSWorkspace.shared.runningApplications.compactMap { application -> (RunningApp, NSImage?)? in
            guard application.activationPolicy != .prohibited, let id = application.bundleIdentifier else { return nil }
            return (RunningApp(bundleID: id, name: application.localizedName ?? id, isRegular: application.activationPolicy == .regular), application.icon)
        }
        apps = AppCatalog.listed(audio: audioApps(), running: running.map(\.0), excluding: Bundle.main.bundleIdentifier)
        icons = [:]
        for (app, icon) in running {
            guard let image = icon?.copy() as? NSImage else { continue }
            image.size = Self.iconSize
            icons[app.bundleID] = image
        }
        Log.debug("app") { "apps with audio: \(self.apps.map { "\($0.name)\($0.isPlaying ? "*" : "")" }), icons for \(self.icons.count) running apps" }
        // The app that was selected may have stopped making sound; keep it only if it is still listed.
        if !apps.contains(where: { $0.bundleID == app }) { app = apps.first?.bundleID ?? "" }
    }

    func toggle() {
        if let session {
            // Stopping un-mutes the app and says goodbye to the speaker; a new session must not start before that is done.
            self.session = nil
            isStopping = true
            status = "Stopping…"
            Thread.detachNewThread {
                session.stop()
                DispatchQueue.main.async {
                    self.isStopping = false
                    self.health = nil
                    self.failed = false
                    self.status = "Idle"
                }
            }
            return
        }
        let session = StreamSession(app: app, speaker: speaker, volume: volume)
        session.onState = { state in
            DispatchQueue.main.async { self.show(state) }
        }
        session.onHealth = { health in
            DispatchQueue.main.async { if self.session != nil { self.health = health } }
        }
        failed = false
        do {
            try session.start()
            self.session = session
            status = "Connecting to \(speaker)…"
        } catch {
            failed = true
            status = "\(error)"
        }
    }

    private func show(_ state: StreamSession.State) {
        guard session != nil else { return }
        switch state {
        case .connecting: status = "Connecting to \(speaker)…"
        case .streaming(let name): status = "Streaming to \(name)"
        case .reconnecting(let reason):
            health = nil
            status = "Reconnecting: \(reason)"
        }
    }

    /// What the dot beside the status line means.
    var indicator: (color: Color, text: String) {
        if failed { return (.red, status) }
        guard isStreaming else { return (.secondary, status) }
        guard let health else { return (.orange, status) }
        return (health.assessment.level == .good ? .green : .yellow, health.summary)
    }
}

struct MenuView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("App", selection: $model.app) {
                ForEach(model.apps) { app in
                    Label {
                        Text(app.name + (app.isPlaying ? "  ▶" : ""))
                    } icon: {
                        Image(nsImage: model.icons[app.bundleID] ?? NSImage())
                    }
                    .tag(app.bundleID)
                }
            }
            .disabled(model.isStreaming)
            Picker("Speaker", selection: $model.speaker) {
                ForEach(model.speakers, id: \.name) { Text($0.name).tag($0.name) }
            }
            .disabled(model.isStreaming)
            HStack {
                Text("Volume")
                Slider(value: $model.volume, in: 0...100)
                    .disabled(model.isStreaming)
            }
            HStack {
                Button(model.isStreaming ? "Stop" : "Start") { model.toggle() }
                    .disabled(model.app.isEmpty || model.speaker.isEmpty || model.isStopping)
                Button(model.isScanning ? "Scanning…" : "Refresh") { model.refresh() }
                    .disabled(model.isScanning)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(model.indicator.color).frame(width: 8, height: 8)
                Text(model.indicator.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let health = model.health {
                DisclosureGroup("Details", isExpanded: $model.showDetails) { DetailsView(health: health) }
                    .font(.caption)
            }
            Divider()
            Toggle("Debug log", isOn: $model.debug).font(.caption)
            HStack {
                Button("Open log") { NSWorkspace.shared.open(Model.logURL) }.font(.caption)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 330)
        .onAppear { model.refresh() }
    }
}

struct DetailsView: View {
    let health: StreamHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(health.sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title).font(.caption.weight(.semibold))
                    ForEach(section.rows, id: \.label) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(row.value).monospacedDigit().multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            if !health.assessment.problems.isEmpty {
                Text(health.assessment.problems.joined(separator: "\n")).foregroundStyle(.yellow)
            }
        }
        .font(.caption)
        .padding(.top, 4)
    }
}

@main
struct AirtapApp: App {
    /// Owned here, not by the popover's view, so a running stream stays reachable however the popover is rebuilt.
    @StateObject private var model: Model

    init() {
        // Scan at launch rather than when the popover is first opened, so the last speaker is already picked by then.
        let model = MainActor.assumeIsolated {
            let model = Model()
            model.refresh()
            return model
        }
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        MenuBarExtra("airtap", systemImage: "airplayaudio") { MenuView(model: model) }
            .menuBarExtraStyle(.window)
    }
}
