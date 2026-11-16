#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyatv==0.18.0", "srptools<2"]
# ///
"""End-to-end check of the Swift AirPlay sender against a fake AirPlay 2 receiver.

The fake receiver reuses pyatv's crypto for the speaker side, so a pass means the Swift sender speaks the
same protocol pyatv does: transient pairing, HAP-encrypted RTSP, event channel, timing, sync and encrypted audio.
"""

import array
import binascii
import hashlib
import os
import plistlib
import re
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from itertools import pairwise

from pyatv.auth import hap_tlv8
from pyatv.auth.hap_session import HAPSession
from pyatv.auth.hap_srp import hkdf_expand
from pyatv.support.chacha20 import Chacha20Cipher8byteNonce
from srptools import SRPContext, SRPServerSession, constants

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TLV = hap_tlv8.TlvValue


def new_listener():
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(4)
    return listener


class FakeReceiver:
    """One speaker-side connection. After RECORD, `drop_after` closes it and `stall_after` stops answering
    while keeping the connection open, which is what a speaker that fell asleep looks like."""

    def __init__(
        self,
        listener,
        drop_after=None,
        stall_after=None,
        request_retransmit=False,
        feedback_status=200,
    ):
        self.listener = listener
        self.port = listener.getsockname()[1]
        self.drop_after = drop_after
        self.dropped = False
        self.stall_after = stall_after
        self.stalled = False
        self.request_retransmit = request_retransmit
        self.feedback_status = feedback_status
        self.control_sock = None
        self.raw_packets = {}
        self.retransmit_request = None
        self.retransmitted = []
        self.session = None
        self.shared = b""
        self.client_timing_port = 0
        self.client_control_port = 0
        self.stream_key = None
        self.events = []
        self.requests = []
        self.audio = []  # (seqno, timestamp, ssrc, first_flag, pcm)
        self.sync_packets = []
        self.timing_reply = None
        self.timing_before_stream_setup = False
        self.feedback_count = 0
        self.volume = None
        self.torn_down = threading.Event()
        self.event_bytes = 0
        self.errors = []

    # --- transport helpers
    def _read_request(self, conn, buffer):
        while True:
            if b"\r\n\r\n" in buffer:
                head, rest = buffer.split(b"\r\n\r\n", 1)
                lines = head.decode().split("\r\n")
                headers = {
                    l.split(": ", 1)[0].lower(): l.split(": ", 1)[1]
                    for l in lines[1:]
                    if ": " in l
                }
                length = int(headers.get("content-length", 0))
                if len(rest) >= length:
                    return lines[0], headers, rest[:length], rest[length:]
            chunk = conn.recv(65536)
            if not chunk:
                return None
            if self.session:
                chunk = self.session.decrypt(chunk)
            buffer += chunk

    def _respond(self, conn, protocol, cseq, body=b"", content_type=None, code=200):
        head = f"{protocol} {code} OK\r\nServer: AirTunes/fake\r\n"
        if cseq is not None:
            head += f"CSeq: {cseq}\r\n"
        if content_type:
            head += f"Content-Type: {content_type}\r\n"
        head += f"Content-Length: {len(body)}\r\n\r\n"
        data = head.encode() + body
        conn.sendall(self.session.encrypt(data) if self.session else data)

    # --- pairing
    def _pair_setup(self, conn, body, state):
        tlv = hap_tlv8.read_tlv(body)
        seq = tlv[TLV.SeqNo][0]
        if seq == 1:
            ctx = SRPContext(
                "Pair-Setup",
                "3939",
                prime=constants.PRIME_3072,
                generator=constants.PRIME_3072_GEN,
                hash_func=hashlib.sha512,
            )
            salt = int.from_bytes(os.urandom(16), "big") | (1 << 127)
            verifier = ctx.get_common_password_verifier(
                ctx.get_common_password_hash(salt)
            )
            server = SRPServerSession(ctx, f"{verifier:x}")
            state.update(server=server, salt=salt)
            public = binascii.unhexlify(server.public)
            reply = hap_tlv8.write_tlv(
                {
                    TLV.SeqNo: b"\x02",
                    TLV.Salt: salt.to_bytes(16, "big"),
                    TLV.PublicKey: public,
                }
            )
        else:
            server = state["server"]
            server.process(
                binascii.hexlify(tlv[TLV.PublicKey]).decode(), f"{state['salt']:x}"
            )
            if not server.verify_proof(
                binascii.hexlify(tlv[TLV.Proof])
            ):  # srptools compares hex as bytes
                self.errors.append("client SRP proof rejected")
                reply = hap_tlv8.write_tlv({TLV.SeqNo: b"\x04", TLV.Error: b"\x02"})
            else:
                self.shared = binascii.unhexlify(server.key)
                reply = hap_tlv8.write_tlv(
                    {
                        TLV.SeqNo: b"\x04",
                        TLV.Proof: binascii.unhexlify(server.key_proof_hash),
                    }
                )
                state["paired"] = True
        return reply

    def _enable_encryption(self):
        read_key = hkdf_expand(
            "Control-Salt", "Control-Write-Encryption-Key", self.shared
        )  # client's write = our read
        write_key = hkdf_expand(
            "Control-Salt", "Control-Read-Encryption-Key", self.shared
        )
        self.session = HAPSession()
        self.session.enable(write_key, read_key)

    # --- sockets for streaming
    def _start_event_listener(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)

        def run():
            conn, _ = listener.accept()
            session = HAPSession()
            session.enable(
                hkdf_expand("Events-Salt", "Events-Write-Encryption-Key", self.shared),
                hkdf_expand("Events-Salt", "Events-Read-Encryption-Key", self.shared),
            )
            self.events.append("connected")
            conn.settimeout(0.5)
            while not self.torn_down.is_set():
                try:
                    data = conn.recv(4096)
                    if not data:
                        break
                    self.event_bytes += len(data)
                except TimeoutError:
                    pass
            conn.close()

        threading.Thread(target=run, daemon=True).start()
        return listener.getsockname()[1]

    def _start_udp(self, handler):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("127.0.0.1", 0))
        sock.settimeout(0.25)

        def run():
            while not self.torn_down.is_set():
                try:
                    data, addr = sock.recvfrom(4096)
                except TimeoutError:
                    continue
                handler(sock, data, addr)

        threading.Thread(target=run, daemon=True).start()
        return sock

    def _on_audio(self, sock, data, addr):
        header, rest = data[:12], data[12:]
        nonce8, sealed = rest[-8:], rest[:-8]
        assert self.stream_key is not None
        cipher = Chacha20Cipher8byteNonce(self.stream_key, self.stream_key)
        pcm = cipher.decrypt(sealed, nonce=b"\x00" * 4 + nonce8, aad=header[4:12])
        seq, ts, ssrc = struct.unpack(">HII", header[2:12])
        self.audio.append((seq, ts, ssrc, header[1], pcm))
        self.raw_packets[seq] = data
        if (
            self.request_retransmit
            and self.retransmit_request is None
            and len(self.audio) == 200
        ):
            # Ask for two packets again, the way a speaker does after losing them.
            lost = self.audio[150][0]
            self.retransmit_request = lost
            assert self.control_sock is not None
            self.control_sock.sendto(
                struct.pack(">BBHHH", 0x80, 0xD5, 1, lost, 2),
                ("127.0.0.1", self.client_control_port),
            )

    def _on_control(self, sock, data, addr):
        if len(data) >= 2 and data[1] & 0x7F == 0x54:
            self.sync_packets.append(data)
        elif len(data) >= 4 and data[1] & 0x7F == 0x56:
            self.retransmitted.append(data[4:])

    def _probe_timing(self):
        if not self.client_timing_port:
            return
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.settimeout(3)
        send_sec, send_frac = 3900000000, 4242
        request = struct.pack(
            ">BBHIIIIIII", 0x80, 0xD2, 7, 0, 0, 0, 0, 0, send_sec, send_frac
        )
        probe.sendto(request, ("127.0.0.1", self.client_timing_port))
        try:
            self.timing_reply = struct.unpack(">BBHIIIIIII", probe.recvfrom(64)[0])
        except (TimeoutError, struct.error) as ex:
            self.errors.append(f"no timing reply: {ex}")

    def _drop(self, conn):
        self.dropped = True
        self.torn_down.set()
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def _stall(self):
        self.stalled = True

    # --- main loop
    def serve(self):
        conn, _ = self.listener.accept()
        conn.settimeout(15)
        buffer = b""
        state = {}
        try:
            while True:
                parsed = self._read_request(conn, buffer)
                if parsed is None:
                    break
                line, headers, body, buffer = parsed
                method, uri, protocol = line.split(" ", 2)
                self.requests.append((method, uri))
                if self.stalled:
                    continue
                cseq = headers.get("cseq")
                if uri == "/pair-pin-start":
                    self._respond(conn, protocol, None)
                elif uri == "/pair-setup":
                    reply = self._pair_setup(conn, body, state)
                    self._respond(
                        conn, protocol, None, reply, "application/octet-stream"
                    )
                    if state.get("paired"):
                        self._enable_encryption()
                elif method == "GET" and uri == "/info":
                    self._respond(
                        conn,
                        protocol,
                        cseq,
                        plistlib.dumps({}, fmt=plistlib.FMT_BINARY),
                        "application/x-apple-binary-plist",
                    )
                elif method == "SETUP":
                    request = plistlib.loads(body)
                    if "streams" in request:
                        self._probe_timing()  # a HomePod waits for this answer before replying to the stream SETUP
                        self.timing_before_stream_setup = self.timing_reply is not None
                        stream = request["streams"][0]
                        self.client_control_port = stream["controlPort"]
                        self.stream_key = stream["shk"]
                        data_sock = self._start_udp(self._on_audio)
                        control_sock = self._start_udp(self._on_control)
                        self.control_sock = control_sock
                        reply = {
                            "streams": [
                                {
                                    "controlPort": control_sock.getsockname()[1],
                                    "dataPort": data_sock.getsockname()[1],
                                    "type": 96,
                                }
                            ]
                        }
                    else:
                        self.client_timing_port = request["timingPort"]
                        reply = {
                            "eventPort": self._start_event_listener(),
                            "timingPort": 0,
                        }
                    self._respond(
                        conn,
                        protocol,
                        cseq,
                        plistlib.dumps(reply, fmt=plistlib.FMT_BINARY),
                        "application/x-apple-binary-plist",
                    )
                elif method == "SET_PARAMETER":
                    self.volume = body.decode().strip()
                    self._respond(conn, protocol, cseq)
                elif method == "POST" and uri == "/feedback":
                    self.feedback_count += 1
                    self._respond(conn, protocol, cseq, code=self.feedback_status)
                elif method == "RECORD":
                    self._respond(conn, protocol, cseq)
                    if self.drop_after:
                        threading.Timer(self.drop_after, self._drop, [conn]).start()
                    if self.stall_after:
                        threading.Timer(self.stall_after, self._stall).start()
                elif method == "TEARDOWN":
                    self._respond(conn, protocol, cseq)
                    self.torn_down.set()
                    break
                else:
                    self._respond(conn, protocol, cseq)
        except Exception as ex:  # noqa: BLE001 - any server-side failure is surfaced in the report below
            if not self.dropped and not self.stalled:
                self.errors.append(f"server error: {type(ex).__name__}: {ex}")
        finally:
            self.torn_down.set()
            conn.close()


def tone_frequency(pcm: bytes) -> tuple[float, int]:
    samples = array.array("h", pcm)
    samples.byteswap()  # big-endian on the wire
    left = samples[0::2]
    crossings = sum(1 for a, b in pairwise(left) if a < 0 <= b)
    return crossings / (len(left) / 44100), max(abs(s) for s in left)


BINARY = os.path.join(ROOT, ".build", "debug", "airtap")


class Report:
    def __init__(self):
        self.results = []

    def check(self, name, ok, detail=""):
        self.results.append(ok)
        print(
            f"  {'PASS' if ok else 'FAIL'}  {name}"
            + (f"  ({detail})" if detail else "")
        )


def run_sender(port, seconds, timeout):
    env = {**os.environ, "AIRTAP_DEBUG": "1"}
    return subprocess.run(
        [
            BINARY,
            "tone",
            "127.0.0.1",
            str(port),
            "--seconds",
            str(seconds),
            "--volume",
            "25",
        ],
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
        check=False,
    )


def print_log_tail(process, lines=10):
    print("Swift sender log (tail):")
    for line in process.stderr.strip().splitlines()[-lines:]:
        print("   ", line)


def check_stream(report, receiver, seconds):
    audio = sorted(receiver.audio, key=lambda p: p[1])
    request_order = [m for m, _ in receiver.requests]
    report.check("no receiver errors", not receiver.errors, "; ".join(receiver.errors))
    report.check(
        "RTSP sequence SETUP, SETUP, RECORD, FLUSH",
        [m for m in request_order if m in ("SETUP", "RECORD", "FLUSH")][:4]
        == ["SETUP", "SETUP", "RECORD", "FLUSH"],
        str(request_order),
    )
    report.check("event channel connected", "connected" in receiver.events)
    report.check(
        "volume set",
        receiver.volume is not None and receiver.volume.startswith("volume: -22.5"),
        str(receiver.volume),
    )
    report.check(
        "timing answered before the stream SETUP completed",
        receiver.timing_before_stream_setup,
    )
    report.check(
        "timing request answered",
        receiver.timing_reply is not None
        and receiver.timing_reply[1] == 0xD3
        and receiver.timing_reply[4:6] == (3900000000, 4242),
        str(receiver.timing_reply),
    )
    report.check(
        "sync packets received",
        len(receiver.sync_packets) >= seconds - 2,
        f"{len(receiver.sync_packets)} packets",
    )
    report.check(
        "first sync packet flagged",
        bool(receiver.sync_packets) and receiver.sync_packets[0][0] == 0x90,
    )
    expected = int(seconds * 44100 / 352)
    report.check(
        "audio packets arrived at real-time rate",
        abs(len(audio) - expected) <= expected * 0.15,
        f"{len(audio)} vs ~{expected}",
    )
    report.check("first audio packet flagged 0xE0", bool(audio) and audio[0][3] == 0xE0)
    sequences = [p[0] for p in audio]
    gaps = [(a, b) for a, b in pairwise(sequences) if (b - a) % 65536 != 1]
    report.check("sequence numbers contiguous", not gaps, str(gaps[:3]))
    steps = {b[1] - a[1] for a, b in pairwise(audio)}
    report.check(
        "timestamps advance 352 per packet", steps == {352}, str(sorted(steps)[:4])
    )
    if audio:
        frequency, peak = tone_frequency(b"".join(p[4] for p in audio[10:]))
        report.check(
            "decrypted audio is the 440 Hz tone",
            abs(frequency - 440) < 10,
            f"{frequency:.1f} Hz",
        )
        report.check(
            "amplitude preserved",
            abs(peak - 0.3 * 32767) < 0.02 * 32767,
            f"peak {peak}",
        )
    report.check(
        "feedback keep-alive sent",
        receiver.feedback_count >= 1,
        f"{receiver.feedback_count}",
    )
    report.check("clean TEARDOWN", "TEARDOWN" in request_order)


def scenario_basic(report):
    print("\n== Scenario 1: one clean session")
    seconds = 6
    receiver = FakeReceiver(new_listener(), request_retransmit=True)
    threading.Thread(target=receiver.serve, daemon=True).start()
    process = run_sender(receiver.port, seconds, timeout=60)
    time.sleep(0.5)
    print_log_tail(process)
    report.check(
        "sender exited cleanly", process.returncode == 0, f"exit {process.returncode}"
    )
    check_stream(report, receiver, seconds)
    lost = receiver.retransmit_request
    expected = (
        [receiver.raw_packets.get((lost + i) % 65536) for i in range(2)]
        if lost is not None
        else []
    )
    report.check(
        "lost packets are retransmitted byte for byte",
        len(receiver.retransmitted) == 2 and receiver.retransmitted == expected,
        f"{len(receiver.retransmitted)} resent",
    )


def scenario_reconnect(report):
    print(
        "\n== Scenario 2: speaker drops the connection mid-stream, sender must recover"
    )
    listener = new_listener()
    first = FakeReceiver(listener, drop_after=3)
    second = FakeReceiver(listener)

    def serve_both():
        first.serve()
        second.serve()

    threading.Thread(target=serve_both, daemon=True).start()
    seconds = 14
    process = run_sender(listener.getsockname()[1], seconds, timeout=90)
    time.sleep(0.5)
    print_log_tail(process, 14)
    log = process.stderr
    report.check(
        "sender exited cleanly", process.returncode == 0, f"exit {process.returncode}"
    )
    report.check(
        "first session streamed before the drop",
        len(first.audio) > 100,
        f"{len(first.audio)} packets",
    )
    report.check(
        "drop was noticed and logged", "restarting:" in log and "failed in" in log, ""
    )
    report.check(
        "sender paired again on a new connection",
        ("POST", "/pair-setup") in second.requests,
    )
    report.check(
        "audio resumed after reconnect",
        len(second.audio) > 250,
        f"{len(second.audio)} packets",
    )
    resumed = sorted(second.audio, key=lambda p: p[1])
    if resumed:
        frequency, _ = tone_frequency(b"".join(p[4] for p in resumed[10:]))
        report.check(
            "resumed audio is still the 440 Hz tone",
            abs(frequency - 440) < 10,
            f"{frequency:.1f} Hz",
        )
    report.check(
        "second session ended with TEARDOWN",
        ("TEARDOWN") in [m for m, _ in second.requests],
    )
    report.check(
        "no receiver errors after reconnect",
        not second.errors,
        "; ".join(second.errors),
    )


def scenario_silent_speaker(report):
    print(
        "\n== Scenario 3: speaker goes silent but keeps the connection open, sender must time out and recover"
    )
    listener = new_listener()
    first = FakeReceiver(listener, stall_after=2)
    second = FakeReceiver(listener)

    def serve_both():
        first.serve()
        second.serve()

    threading.Thread(target=serve_both, daemon=True).start()
    started = time.time()
    process = run_sender(listener.getsockname()[1], 32, timeout=120)
    time.sleep(0.5)
    print_log_tail(process, 6)
    log = process.stderr
    report.check(
        "sender exited cleanly", process.returncode == 0, f"exit {process.returncode}"
    )
    report.check(
        "keep-alive timeouts counted to three strikes", "keep-alive failed (3/3)" in log
    )
    gave_up = re.search(
        r"^\s*([\d.]+) \[stream\] failed in feedback loop", log, re.MULTILINE
    )
    reconnecting = re.findall(
        r"^\s*([\d.]+) \[session\] connecting to", log, re.MULTILINE
    )
    gap = (
        float(reconnecting[1]) - float(gave_up.group(1))
        if gave_up and len(reconnecting) > 1
        else None
    )
    report.check(
        "reconnect starts within 3 s of giving up",
        gap is not None and gap < 3,
        f"{gap:.1f} s" if gap is not None else "not found in log",
    )
    feedback = [
        int(m) for m in re.findall(r"POST /feedback failed after (\d+) ms", log)
    ]
    report.check(
        "each keep-alive gives up within 4 s",
        bool(feedback) and max(feedback) < 4000,
        str(feedback),
    )
    report.check(
        "sender paired again on a new connection",
        ("POST", "/pair-setup") in second.requests,
    )
    report.check(
        "audio resumed after the silent speaker",
        len(second.audio) > 250,
        f"{len(second.audio)} packets",
    )
    report.check(
        "no receiver errors after reconnect",
        not second.errors,
        "; ".join(second.errors),
    )
    print(f"   (scenario took {time.time() - started:.0f} s)")


TESTTONE = os.path.join(ROOT, ".build", "debug", "TestTone")
TONE_BUNDLE = "net.hugoh.airtap.testtone"


def peak_of(packets):
    samples = array.array("h", b"".join(p[4] for p in packets))
    samples.byteswap()
    return max((abs(s) for s in samples), default=0)


def start_tone():
    return subprocess.Popen(
        [TESTTONE, "0.02"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )


def start_capture_sender(port):
    return subprocess.Popen(
        [BINARY, "send", TONE_BUNDLE, f"127.0.0.1:{port}", "--volume", "25", "--debug"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def wait_for_packets(receiver, count, timeout):
    deadline = time.time() + timeout
    while len(receiver.audio) < count and time.time() < deadline:
        time.sleep(0.05)
    return len(receiver.audio) >= count


def finish(sender):
    sender.send_signal(signal.SIGINT)
    try:
        return sender.communicate(timeout=15)[1]
    except subprocess.TimeoutExpired:
        sender.kill()
        return sender.communicate()[1]


def scenario_feedback_unsupported(report):
    print(
        "\n== Scenario 4: speaker answers keep-alives with an error status; the stream must stay up"
    )
    seconds = 7
    receiver = FakeReceiver(new_listener(), feedback_status=501)
    threading.Thread(target=receiver.serve, daemon=True).start()
    process = run_sender(receiver.port, seconds, timeout=60)
    time.sleep(0.5)
    print_log_tail(process, 4)
    log = process.stderr
    expected = int(seconds * 44100 / 352)
    report.check(
        "sender exited cleanly", process.returncode == 0, f"exit {process.returncode}"
    )
    report.check(
        "keep-alives were sent and rejected",
        receiver.feedback_count >= 2,
        f"{receiver.feedback_count} sent",
    )
    report.check(
        "the session was never restarted",
        "restarting:" not in log and "failed in" not in log,
    )
    report.check(
        "audio kept flowing for the whole run",
        abs(len(receiver.audio) - expected) <= expected * 0.15,
        f"{len(receiver.audio)} vs ~{expected}",
    )
    report.check("clean TEARDOWN", "TEARDOWN" in [m for m, _ in receiver.requests])


def scenario_capture(report):
    print(
        "\n== Scenario 5: real tapped audio from an app, through the feed, to the speaker"
    )
    receiver = FakeReceiver(new_listener())
    threading.Thread(target=receiver.serve, daemon=True).start()
    tone = start_tone()
    time.sleep(1.5)
    sender = start_capture_sender(receiver.port)
    streamed = wait_for_packets(receiver, 1000, timeout=40)
    log = finish(sender)
    tone.terminate()
    time.sleep(0.5)
    for line in [l for l in log.splitlines() if "[stats]" in l or "[capture]" in l][
        -4:
    ]:
        print("   ", line.strip())

    report.check(
        "stream reached the speaker", streamed, f"{len(receiver.audio)} packets"
    )
    levels = [float(m) for m in re.findall(r"input level ([\d.]+)", log)]
    report.check(
        "the tap hears the app (not silence)",
        bool(levels) and max(levels) > 0.005,
        f"max level {max(levels, default=0):.3f}; 0.000 would mean no audio-capture permission",
    )
    audio = sorted(receiver.audio, key=lambda p: p[1])[200:]
    if audio:
        frequency, peak = tone_frequency(b"".join(p[4] for p in audio))
        report.check(
            "speaker receives the app's 440 Hz tone",
            abs(frequency - 440) < 10,
            f"{frequency:.1f} Hz",
        )
        report.check(
            "level survives capture and resampling",
            400 < peak < 1000,
            f"peak {peak} (expected ~655)",
        )
    underruns = re.findall(r"underruns=(\d+)/(\d+)", log)
    report.check(
        "no audio underruns once the cushion is built",
        bool(underruns) and int(underruns[-1][0]) == 0,
        f"{underruns[-1] if underruns else 'no stats'}",
    )
    summaries = re.findall(r"\[health\] (.*)", log)
    report.check(
        "health summary reported while streaming",
        bool(summaries),
        summaries[-1] if summaries else "no [health] lines in the log",
    )
    report.check(
        "a healthy stream is reported as healthy",
        bool(summaries) and all(not line.startswith("Unstable") for line in summaries),
        "; ".join(sorted({line for line in summaries if line.startswith("Unstable")})),
    )
    report.check(
        "summary names the speaker and the delay",
        bool(summaries) and "delay ≈" in summaries[-1],
        summaries[-1] if summaries else "",
    )
    report.check(
        "sender stopped cleanly on Ctrl-C",
        sender.returncode == 0,
        f"exit {sender.returncode}",
    )


def scenario_app_restart(report):
    print("\n== Scenario 6: the app quits and comes back; the tap must be rebuilt")
    receiver = FakeReceiver(new_listener())
    threading.Thread(target=receiver.serve, daemon=True).start()
    tone = start_tone()
    time.sleep(1.5)
    sender = start_capture_sender(receiver.port)
    streamed = wait_for_packets(receiver, 400, timeout=40)
    tone.terminate()
    tone.wait()
    quit_at = len(receiver.audio)
    time.sleep(2.5)
    tone = start_tone()
    back_at = len(receiver.audio)
    time.sleep(5)
    log = finish(sender)
    tone.terminate()
    time.sleep(0.5)
    for line in [
        l for l in log.splitlines() if "[capture]" in l and "input level" not in l
    ][-4:]:
        print("   ", line.strip())

    audio = receiver.audio
    report.check("stream was up before the app quit", streamed, f"{quit_at} packets")
    report.check(
        "speaker stays connected while the app is gone",
        back_at - quit_at > 200,
        f"{back_at - quit_at} packets during the gap",
    )
    report.check(
        "gap is silence, not stale audio",
        peak_of(audio[quit_at + 150 : back_at - 20]) < 50,
        f"peak {peak_of(audio[quit_at + 150 : back_at - 20])}",
    )
    report.check("loss of the app was logged", "waiting for it to return" in log)
    report.check("tap was rebuilt when the app returned", "tap rebuilt" in log)
    tail = audio[-250:]
    if tail:
        frequency, peak = tone_frequency(b"".join(p[4] for p in tail))
        report.check(
            "audio flows again after the app returns",
            peak > 400 and abs(frequency - 440) < 15,
            f"peak {peak}, {frequency:.1f} Hz",
        )
    report.check(
        "sender stopped cleanly on Ctrl-C",
        sender.returncode == 0,
        f"exit {sender.returncode}",
    )


def main() -> int:
    report = Report()
    scenario_basic(report)
    scenario_reconnect(report)
    scenario_silent_speaker(report)
    scenario_feedback_unsupported(report)
    if os.environ.get("AIRTAP_E2E_CAPTURE", "1") != "0":
        scenario_capture(report)
        scenario_app_restart(report)
    else:
        print("\n(capture scenarios skipped: AIRTAP_E2E_CAPTURE=0)")
    print(f"\n{sum(report.results)}/{len(report.results)} checks passed")
    return 0 if all(report.results) else 1


if __name__ == "__main__":
    sys.exit(main())
