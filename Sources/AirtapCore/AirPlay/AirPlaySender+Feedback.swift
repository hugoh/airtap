import Foundation

extension AirPlaySender {
    /// Keeps the session alive. Any reply, whatever its status, shows the speaker is there: some receivers do not
    /// implement `/feedback` and answer with an error. Only a dead or silent connection ends the session.
    func feedbackLoop(_ rtsp: RTSPSession) {
        var failures = 0
        var reportedStatus = false
        while isRunning {
            Thread.sleep(forTimeInterval: 2)
            guard isRunning else { return }
            do {
                let started = Clock.now()
                let response = try rtsp.exchange("POST", uri: "/feedback", allowError: true, timeout: Self.feedbackTimeout)
                let roundTrip = Int((Clock.now() - started) * 1000)
                if !(200..<300).contains(response.code), !reportedStatus {
                    reportedStatus = true
                    Log.debug("feedback") { "speaker answers keep-alives with status \(response.code); treating any answer as alive" }
                }
                failures = 0
                statsStore.update {
                    $0.feedbackSucceeded += 1
                    $0.keepAliveMilliseconds = roundTrip
                }
            } catch {
                failures += 1
                statsStore.update { $0.feedbackFailed += 1 }
                guard isRunning else { return }
                Log.info("feedback", "keep-alive failed (\(failures)/3): \(error)")
                let isTimeout = (error as? NetworkError)?.description.hasPrefix("timed out") ?? false
                if !isTimeout || failures >= 3 { return fail(AirPlayError(description: "speaker stopped responding (\(error))"), from: "feedback") }
            }
        }
    }
}
