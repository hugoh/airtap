import Foundation

/// Counters for one streaming session, logged once a second.
struct StreamStats {
    var packetsSent = 0
    var packetsDropped = 0
    var maxLateMilliseconds = 0.0
    var retransmitRequests = 0
    var retransmitPacketsServed = 0
    var timingRequests = 0
    var feedbackSucceeded = 0
    var feedbackFailed = 0

    func summary(rtpTime: UInt32) -> String {
        "sent=\(packetsSent) dropped=\(packetsDropped) maxLate=\(Int(maxLateMilliseconds))ms rtp=\(rtpTime) "
            + "retransmit=\(retransmitRequests)req/\(retransmitPacketsServed)pkts timing=\(timingRequests) "
            + "feedback=\(feedbackSucceeded)ok/\(feedbackFailed)fail"
    }
}
