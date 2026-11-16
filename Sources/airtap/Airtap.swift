import AirtapCore
import ArgumentParser
import Foundation

@main
struct Airtap: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send one Mac app's audio to an AirPlay speaker.",
        subcommands: [Send.self, Tone.self, Speakers.self, Apps.self]
    )
}

struct Send: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stream an app to a speaker until you press Ctrl-C.")

    @Argument(help: "The app: its bundle id or part of it, such as pocket-casts (see `airtap apps`).")
    var app: String

    @Argument(help: "The speaker: its name or part of it, such as Kitchen (see `airtap speakers`), or an address like 192.168.1.20:7000.")
    var speaker: String

    @Option(help: "Volume from 0 to 100.")
    var volume = 30.0

    @Flag(help: "Log every protocol step and a health line every few seconds.")
    var debug = false

    func validate() throws {
        guard (0...100).contains(volume) else { throw ValidationError("Volume must be between 0 and 100.") }
    }

    func run() throws {
        Log.isDebugEnabled = Log.isDebugEnabled || debug
        let session = StreamSession(app: app, speaker: speaker, volume: volume)
        session.onState = { Log.info("state", "\($0)") }
        try session.start()
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler {
            session.stop()
            Log.flush()
            Foundation.exit(0)
        }
        interrupt.resume()
        RunLoop.main.run()
    }
}

struct Tone: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stream a 440 Hz test tone to an address, with no app involved.")

    @Argument(help: "The speaker's IPv4 address.")
    var host: String

    @Argument(help: "The speaker's AirPlay port, usually 7000.")
    var port: UInt16

    @Option(help: "How long to play once the stream is up.")
    var seconds = 5.0

    @Option(help: "Volume from 0 to 100.")
    var volume = 20.0

    @Option(help: "Loudness of the tone from 0 to 1; 0 streams silence.")
    var amplitude = 0.3

    @Flag(help: "Log every protocol step and a health line every few seconds.")
    var debug = false

    func validate() throws {
        guard (0...100).contains(volume) else { throw ValidationError("Volume must be between 0 and 100.") }
        guard (0...1).contains(amplitude) else { throw ValidationError("Amplitude must be between 0 and 1.") }
    }

    func run() throws {
        Log.isDebugEnabled = Log.isDebugEnabled || debug
        let speaker = Speaker(name: "tone", host: host, port: port)
        let stream = ReconnectingStream(source: ToneSource(amplitude: amplitude), volume: volume) { _ in speaker }
        let streaming = DispatchSemaphore(value: 0)
        stream.onState = { state in
            Log.info("state", "\(state)")
            if case .streaming = state { streaming.signal() }
        }
        stream.start()
        let connected = streaming.wait(timeout: .now() + 30) == .success
        if connected { Thread.sleep(forTimeInterval: seconds) }
        stream.stop()
        Log.flush()
        if !connected { throw ExitCode.failure }
    }
}

struct Speakers: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the AirPlay speakers on the network.")

    func run() {
        for speaker in SpeakerDiscovery.discover(timeout: 12) { print("\(speaker.name)\t\(speaker.host):\(speaker.port)") }
    }
}

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the apps and processes with audio, playing ones marked.")

    func run() {
        for app in audioApps() { print("\(app.isPlaying ? "[playing]" : "[idle]   ") \(app.bundleID)") }
    }
}

/// A sine wave, for trying a speaker without any app.
final class ToneSource: PCMSource {
    private let amplitude: Double
    private var frame = 0

    init(amplitude: Double) { self.amplitude = amplitude }

    func readPacket(frames: Int) -> Data {
        var packet = Data(capacity: frames * 4)
        for _ in 0..<frames {
            let sample = Int16(amplitude * 32767 * sin(2 * Double.pi * 440 * Double(frame) / 44100))
            frame += 1
            for _ in 0..<2 { packet += [UInt8(truncatingIfNeeded: sample >> 8), UInt8(truncatingIfNeeded: sample)] }
        }
        return packet
    }
}
