import AirtapCore
import AppKit
import SwiftUI

@MainActor
final class Model: ObservableObject {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/airtap.log")

    @Published var apps: [AudioApp] = []
    @Published var speakers: [Speaker] = []
    @Published var app = ""
    @Published var speaker = ""
    @Published var volume = 30.0
    @Published var status = "Idle"
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
        apps = audioApps().sorted { ($0.isPlaying ? 0 : 1, $0.bundleID) < ($1.isPlaying ? 0 : 1, $1.bundleID) }
        if !apps.contains(where: { $0.bundleID == app }) { app = apps.first?.bundleID ?? "" }
        guard !isScanning else { return }
        isScanning = true
        Thread.detachNewThread {
            let found = SpeakerDiscovery.discover(timeout: 4)
            DispatchQueue.main.async {
                self.speakers = found
                if !found.contains(where: { $0.name == self.speaker }) { self.speaker = found.first?.name ?? "" }
                self.isScanning = false
            }
        }
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
                    self.status = "Idle"
                }
            }
            return
        }
        let session = StreamSession(app: app, speaker: speaker, volume: volume)
        session.onState = { state in
            DispatchQueue.main.async { self.show(state) }
        }
        do {
            try session.start()
            self.session = session
            status = "Connecting to \(speaker)…"
        } catch {
            status = "\(error)"
        }
    }

    private func show(_ state: StreamSession.State) {
        guard session != nil else { return }
        switch state {
        case .connecting: status = "Connecting to \(speaker)…"
        case .streaming(let name): status = "Streaming to \(name)"
        case .reconnecting(let reason): status = "Reconnecting: \(reason)"
        }
    }
}

struct MenuView: View {
    @StateObject private var model = Model()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("App", selection: $model.app) {
                ForEach(model.apps) { Text(($0.isPlaying ? "▶ " : "") + $0.bundleID).tag($0.bundleID) }
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
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(3)
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

@main
struct AirtapApp: App {
    var body: some Scene {
        MenuBarExtra("airtap", systemImage: "airplayaudio") { MenuView() }
            .menuBarExtraStyle(.window)
    }
}
