import Foundation

/// The two SETUP request bodies of an AirPlay 2 audio session, as pyatv sends them. The identity fields are
/// placeholders every receiver tested accepts.
enum AirPlayRequests {
    static let sampleRate = 44100
    static let framesPerPacket = 352

    static func session(timingPort: UInt16) -> [String: Any] {
        [
            "deviceID": "AA:BB:CC:DD:EE:FF",
            "sessionUUID": UUID().uuidString,
            "timingPort": Int(timingPort),
            "timingProtocol": "NTP",
            "isMultiSelectAirPlay": true,
            "groupContainsGroupLeader": false,
            "macAddress": "AA:BB:CC:DD:EE:FF",
            "model": "iPhone14,3",
            "name": "airtap",
            "osBuildVersion": "20F66",
            "osName": "iPhone OS",
            "osVersion": "16.5",
            "senderSupportsRelay": false,
            "sourceVersion": "690.7.1",
            "statsCollectionEnabled": false,
        ]
    }

    /// Raw PCM (`ct` 1) over an encrypted real-time stream; `key` is the ChaCha20-Poly1305 key for the audio packets.
    static func stream(controlPort: UInt16, key: Data, connectionID: UInt32) -> [String: Any] {
        [
            "audioFormat": 0x800,
            "audioMode": "default",
            "controlPort": Int(controlPort),
            "ct": 1,
            "isMedia": true,
            "latencyMax": 88200,
            "latencyMin": 11025,
            "shk": key,
            "spf": framesPerPacket,
            "sr": sampleRate,
            "type": 0x60,
            "supportsDynamicStreamID": false,
            "streamConnectionID": Int(connectionID),
        ]
    }
}
