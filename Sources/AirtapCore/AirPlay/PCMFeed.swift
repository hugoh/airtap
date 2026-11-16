import AVFoundation
import Foundation
import os

public struct FeedStats: Equatable {
    public var bufferedMilliseconds: Int
    public var targetMilliseconds: Int
    public var underruns: Int
    public var overflows: Int
    public var driftCorrections: Int
}

/// Bridges the process tap (float32 stereo at the device rate) to the sender (16-bit big-endian stereo at 44.1 kHz).
///
/// It keeps a small cushion so chunked delivery never starves the sender, and nudges the buffer level by one
/// frame per packet to absorb drift between the Mac's audio clock and the pace the speaker is fed at.
public final class PCMFeed: PCMSource {
    private static let maxInputRate = 192_000.0

    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 2, interleaved: true)!
    private let prebufferSeconds: Double
    private let maxBufferedSeconds: Double

    /// Guards the converter and input format, which only the reader and `reconfigure` touch.
    private let converterLock = NSLock()
    private var inputFormat: AVAudioFormat
    private var converter: AVAudioConverter
    /// Reused across packets; the converter only needs the input to stay valid until it asks for more.
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?

    /// Guards the ring. Unfair locks are safe to take on the audio thread: no allocation, and they donate priority.
    private let ringLock: UnsafeMutablePointer<os_unfair_lock>
    private let ring: UnsafeMutablePointer<Float>
    private let ringFrames: Int
    private var readFrame = 0
    private var count = 0
    private var maxFrames: Int
    private var targetFrames: Int
    private var primed = false
    private var consumedAny = false

    private var underruns = 0
    private var overflows = 0
    private var corrections = 0
    private var packetsRead = 0

    public init(inputRate: Double, prebufferSeconds: Double = 0.15, maxBufferedSeconds: Double = 0.5) {
        self.maxBufferedSeconds = maxBufferedSeconds
        self.prebufferSeconds = min(prebufferSeconds, maxBufferedSeconds / 2)
        inputFormat = Self.format(rate: inputRate)
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)!
        ringFrames = Int(Self.maxInputRate * maxBufferedSeconds)
        ring = .allocate(capacity: ringFrames * 2)
        ring.initialize(repeating: 0, count: ringFrames * 2)
        ringLock = .allocate(capacity: 1)
        ringLock.initialize(to: os_unfair_lock())
        maxFrames = min(ringFrames, Int(inputRate * maxBufferedSeconds))
        targetFrames = Int(inputRate * self.prebufferSeconds)
    }

    deinit {
        ring.deallocate()
        ringLock.deallocate()
    }

    private static func format(rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: min(rate, maxInputRate), channels: 2, interleaved: true)!
    }

    // MARK: Writing (audio thread)

    /// Interleaved stereo samples.
    public func push(_ samples: UnsafePointer<Float>, frames: Int) {
        write(frames: frames) { destination, offset, length in
            destination.update(from: samples + offset * 2, count: length * 2)
        }
    }

    /// One buffer per channel.
    public func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        write(frames: frames) { destination, offset, length in
            for frame in 0..<length {
                destination[frame * 2] = left[offset + frame]
                destination[frame * 2 + 1] = right[offset + frame]
            }
        }
    }

    private func write(frames: Int, copy: (_ destination: UnsafeMutablePointer<Float>, _ offset: Int, _ length: Int) -> Void) {
        os_unfair_lock_lock(ringLock)
        defer { os_unfair_lock_unlock(ringLock) }
        // Only the newest `maxFrames` can be kept, so skip the start of an oversized delivery.
        let skipped = max(0, frames - maxFrames)
        let incoming = frames - skipped
        let excess = count + incoming - maxFrames
        if excess > 0 {
            readFrame = (readFrame + excess) % ringFrames
            count -= excess
            // Before playback starts nobody reads, so dropping old audio is expected rather than a problem.
            if primed { overflows += 1 }
        }
        var written = 0
        while written < incoming {
            let position = (readFrame + count) % ringFrames
            let length = min(incoming - written, ringFrames - position)
            copy(ring + position * 2, skipped + written, length)
            count += length
            written += length
        }
    }

    // MARK: Reading (sender thread)

    public func readPacket(frames: Int) -> Data {
        var packet = Data(repeating: 0, count: frames * 4)
        converterLock.lock()
        defer { converterLock.unlock() }

        os_unfair_lock_lock(ringLock)
        packetsRead += 1
        if !primed, count >= targetFrames, targetFrames > 0 || count > 0 {
            // Start from a known cushion so latency does not depend on how long connecting took.
            let surplus = count - max(targetFrames, 1)
            if surplus > 0 {
                readFrame = (readFrame + surplus) % ringFrames
                count -= surplus
            }
            primed = true
        }
        let ready = primed
        os_unfair_lock_unlock(ringLock)
        guard ready else { return packet }

        let output: AVAudioPCMBuffer
        if let reusable = outputBuffer, reusable.frameCapacity == AVAudioFrameCount(frames) {
            output = reusable
        } else {
            output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames))!
            outputBuffer = output
        }
        var error: NSError?
        converter.convert(to: output, error: &error) { [self] requested, status in
            // The converter discards whatever it did not ask for, so hand over exactly what it requested.
            guard let buffer = take(upTo: Int(requested)) else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }

        os_unfair_lock_lock(ringLock)
        if output.frameLength < frames {
            underruns += 1
            primed = false
        } else {
            correctDrift()
        }
        os_unfair_lock_unlock(ringLock)

        guard error == nil, output.frameLength > 0, let converted = output.int16ChannelData?[0] else { return packet }
        packet.withUnsafeMutableBytes { bytes in
            let target = bytes.bindMemory(to: UInt16.self)
            for index in 0..<Int(output.frameLength) * 2 { target[index] = UInt16(bitPattern: converted[index]).bigEndian }
        }
        return packet
    }

    private func take(upTo requested: Int) -> AVAudioPCMBuffer? {
        os_unfair_lock_lock(ringLock)
        defer { os_unfair_lock_unlock(ringLock) }
        let length = min(requested, count)
        guard length > 0 else { return nil }
        if inputBuffer.map({ Int($0.frameCapacity) < length }) ?? true {
            inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(max(length, 1024)))
        }
        guard let buffer = inputBuffer else { return nil }
        buffer.frameLength = AVAudioFrameCount(length)
        let destination = buffer.floatChannelData![0]
        let firstRun = min(length, ringFrames - readFrame)
        destination.update(from: ring + readFrame * 2, count: firstRun * 2)
        if firstRun < length { (destination + firstRun * 2).update(from: ring, count: (length - firstRun) * 2) }
        readFrame = (readFrame + length) % ringFrames
        count -= length
        consumedAny = true
        return buffer
    }

    /// Called with the ring lock held. Skips or replays a single frame when the level leaves the band around the
    /// target, which is inaudible and corrects far more drift than two crystal clocks can produce.
    private func correctDrift() {
        let band = max(targetFrames / 2, 1)
        if count > targetFrames + band {
            readFrame = (readFrame + 1) % ringFrames
            count -= 1
            corrections += 1
        } else if count < targetFrames - band, consumedAny, count < maxFrames {
            readFrame = (readFrame + ringFrames - 1) % ringFrames
            count += 1
            corrections += 1
        }
    }

    /// Switches the source sample rate, e.g. after the output device changed. Buffered audio at the old rate is dropped.
    public func reconfigure(inputRate: Double) {
        converterLock.lock()
        defer { converterLock.unlock() }
        inputFormat = Self.format(rate: inputRate)
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)!
        inputBuffer = nil
        os_unfair_lock_lock(ringLock)
        readFrame = 0
        count = 0
        primed = false
        consumedAny = false
        maxFrames = min(ringFrames, Int(inputRate * maxBufferedSeconds))
        targetFrames = Int(inputRate * prebufferSeconds)
        os_unfair_lock_unlock(ringLock)
    }

    // MARK: Diagnostics

    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(ringLock)
        defer { os_unfair_lock_unlock(ringLock) }
        return body()
    }

    public var bufferedFrames: Int { locked { count } }
    var underrunCount: Int { locked { underruns } }
    var overflowCount: Int { locked { overflows } }
    var driftCorrections: Int { locked { corrections } }

    public var stats: FeedStats {
        converterLock.lock()
        let rate = inputFormat.sampleRate
        converterLock.unlock()
        return locked {
            FeedStats(
                bufferedMilliseconds: Int(Double(count) / rate * 1000), targetMilliseconds: Int(Double(targetFrames) / rate * 1000),
                underruns: underruns, overflows: overflows, driftCorrections: corrections
            )
        }
    }

    public var debugSummary: String {
        converterLock.lock()
        let rate = inputFormat.sampleRate
        converterLock.unlock()
        return locked {
            "feed buffered=\(Int(Double(count) / rate * 1000))ms underruns=\(underruns)/\(packetsRead) overflows=\(overflows) drift=\(corrections)"
        }
    }
}
