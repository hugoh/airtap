import AirtapCore
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("airtap: \(message)\n".utf8))
    exit(1)
}

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

/// Streams a 440 Hz tone to host:port for a few seconds, without capturing anything.
func tone(_ arguments: [String]) {
    var positional: [String] = []
    var seconds = 5.0
    var volume = 20.0
    var amplitude = 0.3
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--debug": Log.isDebugEnabled = true
        case "--seconds": seconds = iterator.next().flatMap(Double.init) ?? seconds
        case "--amplitude": amplitude = iterator.next().flatMap(Double.init) ?? amplitude
        case "--volume": volume = iterator.next().flatMap(Double.init) ?? volume
        default: positional.append(argument)
        }
    }
    guard positional.count == 2, let port = UInt16(positional[1]) else { fail("usage: airtap tone <host> <port> [--seconds N] [--volume 0-100] [--amplitude 0-1] [--debug]") }
    let speaker = Speaker(name: "tone", host: positional[0], port: port)
    let stream = ReconnectingStream(source: ToneSource(amplitude: min(max(amplitude, 0), 1)), volume: volume) { speaker }
    let streaming = DispatchSemaphore(value: 0)
    stream.onState = { state in
        Log.info("state", "\(state)")
        if case .streaming = state { streaming.signal() }
    }
    stream.start()
    streaming.wait()
    Thread.sleep(forTimeInterval: seconds)
    stream.stop()
    Log.flush()
    exit(0)
}

func send(_ arguments: [String]) {
    var positional: [String] = []
    var volume = 30.0
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--debug": Log.isDebugEnabled = true
        case "--volume": volume = iterator.next().flatMap(Double.init) ?? volume
        default: positional.append(argument)
        }
    }
    guard positional.count == 2 else { fail("usage: airtap send <app-bundle-id-substring> <speaker-name-substring> [--volume 0-100] [--debug]") }
    let session = StreamSession(app: positional[0], speaker: positional[1], volume: volume)
    session.onState = { Log.info("state", "\($0)") }
    do { try session.start() } catch { fail("\(error)") }
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        session.stop()
        Log.flush()
        exit(0)
    }
    interrupt.resume()
    RunLoop.main.run()
}

switch Array(CommandLine.arguments.dropFirst()) {
case let args where args.first == "send":
    send(Array(args.dropFirst()))
case let args where args.first == "tone":
    tone(Array(args.dropFirst()))
case ["speakers"]:
    for speaker in SpeakerDiscovery.discover(timeout: 12) { print("\(speaker.name)\t\(speaker.host):\(speaker.port)") }
case ["apps"]:
    for app in audioApps() { print("\(app.isPlaying ? "[playing]" : "[idle]   ") \(app.bundleID)") }
default:
    fail("usage: airtap send <app> <speaker> [--volume 0-100] [--debug] | tone <host> <port> | speakers | apps")
}
