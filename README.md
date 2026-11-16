# airtap

Send the audio of one Mac app (Music, Pocket Casts, …) to an AirPlay speaker, without routing the whole system.
A small replacement for Airfoil, written in Swift with no runtime dependencies.

How it works:

1. A Core Audio **process tap** captures one app's output and mutes it locally (macOS 14.2+). It is rebuilt when the
   app's audio processes or the Mac's output device change.
2. A small buffer resamples the audio to 44.1 kHz 16-bit stereo, keeps a 150 ms cushion, and absorbs clock drift.
3. A built-in **AirPlay 2 sender** (HAP transient pairing, encrypted RTSP, encrypted RTP) streams it to the speaker.
4. A supervisor reconnects with backoff when the session dies or the Mac wakes from sleep.

## Use

```sh
swift build -c release

.build/release/airtap speakers                                    # AirPlay speakers on the network
.build/release/airtap apps                                        # apps with audio, [playing] first
.build/release/airtap send pocket-casts Kitchen --volume 25       # stream; Ctrl-C stops and un-mutes the app
.build/release/airtap send pocket-casts Kitchen --debug           # same, with the detailed log
.build/release/airtap send pocket-casts 192.168.68.125:7000       # by address, when Bonjour cannot resolve the speaker
.build/release/airtap tone 192.168.68.27 7000 --seconds 5         # 440 Hz test tone, no app involved
```

App names and speaker names are case-insensitive substrings.

Menu bar app: `scripts/make-app.sh` (or `mise run app`) builds `build/Airtap.app`. On first run macOS asks for
System Audio Recording and Local Network access. Its log is `~/Library/Logs/airtap.log` (appended across runs, rotated
at 2 MB); the menu has a debug toggle.

The bundle is ad-hoc signed by default, so macOS asks for those permissions again after every rebuild. To keep them,
create a code-signing certificate (Keychain Access → Certificate Assistant → Create a Certificate → Code Signing) and
build with `AIRTAP_SIGN_IDENTITY="<certificate name>" scripts/make-app.sh`.

## What the menu shows

Under the Start button, a dot and one line say how the stream is doing:

| Dot | Meaning |
| --- | --- |
| green | `Streaming to Kitchen · delay ≈ 1.7 s` (or `· the app is silent`, which is not a fault) |
| yellow | `Unstable: …` the two most important problems from the last minute |
| orange | connecting, or reconnecting with the reason |
| red | it could not start, with the reason |

"Details" expands to three groups: **Connection** (speaker and address, how long pairing and setup took, uptime,
reconnects and the last reason), **Stream** (keep-alive round trip, packets per second, resends, slowest send) and
**Audio** (buffer against its 150 ms target, gaps, dropped packets, clock-drift fixes, input level and tap rate).

The stream counts as unstable when, in the last minute, audio ran dry, packets were dropped or the speaker was slow to
answer; when five or more packets had to be resent; or when the Mac sent a packet over 100 ms late in the last ten
seconds. The delay is an estimate (the 1.5 s the speaker is asked to buffer, plus the feed and the speaker's own
rendering), not a measurement. With `--debug` the same summary is logged as `[health]` every five seconds.

## Debugging a disconnect

Lifecycle events always print. `--debug` (or `AIRTAP_DEBUG=1`) adds everything below.

| Category | What it tells you |
| --- | --- |
| `[session]` | connect, pairing, ports, restart reasons, `could not stream: …` |
| `[rtsp]` | every request with status and latency; `… failed after N ms` shows where a hang happened |
| `[stats]` | once a second: `sent`, `dropped`, `maxLate`, `retransmit`, `timing`, `feedback ok/fail`, `feed buffered/underruns/overflows/drift` |
| `[events]` | the speaker's event channel; it closing ends the session immediately |
| `[feedback]` | keep-alive failures; timeouts get three strikes, a closed connection fails at once, any reply counts as alive |
| `[power]` | `system will sleep` / `system woke; reconnecting` |
| `[health]` | the menu's one-line summary, every five seconds |
| `[capture]` | tap level once a second (a flat `0.000` means the tap hears nothing), and every tap rebuild |
| `[stream]` | `failed in audio|control|feedback|events loop: …` names the thread that noticed |

Reading a failure:

- **`failed in events loop`** or **`connection closed by peer`**: the speaker ended the session (it slept, or another source took over).
- **`streaming stalled for N s (system sleep?)`**: the Mac was suspended; the session is stale and is restarted.
- **`SETUP … failed after 10002 ms`**: the speaker did not answer. HomePods wait for the NTP timing reply, so check `[stats] timing=`.
- **`'X' is announced on the network but not answering`**: Bonjour still has the speaker cached but it is off or asleep.
- **`'X' has no audio process right now; waiting for it to return`**: the app quit or restarted its audio process. The
  speaker stays connected on silence and the tap is rebuilt when the app is back.
- **`feed … underruns` climbing**: the capture is not keeping up; each one costs a 150 ms gap while the cushion rebuilds.
  **`maxLate`** over a few hundred ms means the Mac is too busy to pace packets.
- **`feed … drift` climbing slowly** is normal: one frame is skipped or repeated at a time to track the audio clock.
  **`overflows`** mean audio arrived faster than it was sent and the oldest was dropped; **`dropped`** counts packets
  the network stack refused for a moment.

## Tests

```sh
mise run test              # both of the below
swift test                 # wire formats against golden vectors from pyatv/srptools, feed, pacer, supervisor, sockets
./scripts/e2e.py           # sender vs. a fake AirPlay 2 speaker (run from the repo root; needs uv)
hk check --all             # linters, including SwiftLint
./scripts/gen_vectors.py > Tests/AirtapCoreTests/Vectors.swift   # regenerate vectors
```

`e2e.py` runs six scenarios against a fake speaker built on pyatv's own crypto: a clean session with a retransmit
request, a dropped connection, a speaker that goes silent, a speaker that rejects keep-alives, real audio tapped from a
helper app (`TestTone`), and that app quitting and returning. The last two play a very quiet tone on the Mac for a moment and need an audio device, so
CI sets `AIRTAP_E2E_CAPTURE=0` to skip them.

The fake speaker is strict about what real HomePods require, such as answering NTP timing before the stream SETUP completes.

## Limits

- IPv4 only; pairing is transient (no PIN, no password-protected speakers).
- About 2 s latency, normal for AirPlay. Not suitable for video sync.
- Reconnection restarts the stream; the audio during the gap is lost.
- Volume is set when a session starts; changing it means restarting the stream.
