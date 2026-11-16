import AVFoundation

// Plays a quiet sine so the end-to-end test has a real app, with its own bundle id, for airtap to tap.
let amplitude = CommandLine.arguments.dropFirst().first.flatMap(Float.init) ?? 0.02
let frequency = 440.0

let engine = AVAudioEngine()
let format = engine.outputNode.inputFormat(forBus: 0)
var phase = 0.0
let step = 2 * Double.pi * frequency / format.sampleRate
let source = AVAudioSourceNode { _, _, frameCount, audioBufferList in
    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    for frame in 0..<Int(frameCount) {
        let sample = amplitude * Float(sin(phase))
        phase += step
        for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample }
    }
    return noErr
}
engine.attach(source)
engine.connect(source, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2))
do { try engine.start() } catch {
    FileHandle.standardError.write(Data("testtone: \(error)\n".utf8))
    exit(1)
}
RunLoop.main.run()
