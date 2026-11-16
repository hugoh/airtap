#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyatv==0.18.0", "srptools<2"]
# ///
"""Print Swift golden vectors computed with pyatv/srptools, the reference the Swift AirPlay code must match."""

import binascii
import hashlib

from pyatv.auth import hap_tlv8
from pyatv.auth.hap_session import HAPSession
from pyatv.auth.hap_srp import hkdf_expand
from pyatv.protocols.raop import timing
from pyatv.protocols.raop.packets import AudioPacketHeader, SyncPacket, TimingPacket
from pyatv.support.chacha20 import Chacha20Cipher8byteNonce
from srptools import SRPClientSession, SRPContext, constants

hexs = lambda b: binascii.hexlify(b).decode()
out = []


def emit(name, value):
    if isinstance(value, bytes):
        value = value.decode()
    out.append(f'    static let {name} = "{value}"')


# SRP (client side as pyatv runs it, against a server built from the same password)
a = bytes(range(1, 33))
salt = bytes([0x5A]) + bytes(range(2, 17))
b = bytes(range(101, 133))
ctx = SRPContext(
    "Pair-Setup",
    "3939",
    prime=constants.PRIME_3072,
    generator=constants.PRIME_3072_GEN,
    hash_func=hashlib.sha512,
)
x = ctx.get_common_password_hash(int.from_bytes(salt, "big"))
verifier = ctx.get_common_password_verifier(x)
server_public = ctx.get_server_public(verifier, int.from_bytes(b, "big"))
server_public_bytes = server_public.to_bytes(
    (server_public.bit_length() + 7) // 8, "big"
)
session = SRPClientSession(ctx, hexs(a))
session.process(hexs(server_public_bytes), hexs(salt))
emit("srpPrivate", hexs(a))
emit("srpSalt", hexs(salt))
emit("srpServerPublic", hexs(server_public_bytes))
emit("srpClientPublic", session.public)
emit("srpProof", session.key_proof)
emit("srpSessionKey", session.key)
emit("srpServerProof", session.key_proof_hash)

# HKDF
shared = binascii.unhexlify(session.key)
emit(
    "hkdfControlWrite",
    hexs(hkdf_expand("Control-Salt", "Control-Write-Encryption-Key", shared)),
)
emit(
    "hkdfControlRead",
    hexs(hkdf_expand("Control-Salt", "Control-Read-Encryption-Key", shared)),
)
emit(
    "hkdfEventsWrite",
    hexs(hkdf_expand("Events-Salt", "Events-Write-Encryption-Key", shared)),
)

# HAP framing: 2500 bytes forces three frames
key_out = hkdf_expand("Control-Salt", "Control-Write-Encryption-Key", shared)
key_in = hkdf_expand("Control-Salt", "Control-Read-Encryption-Key", shared)
plain = bytes((i * 7) % 256 for i in range(2500))
sess = HAPSession()
sess.enable(key_out, key_in)
emit("hapPlain", hexs(plain))
emit(
    "hapFramesTwoMessages", hexs(sess.encrypt(plain) + sess.encrypt(b"second message"))
)

# TLV8, including a value over 255 bytes
tlv = {
    hap_tlv8.TlvValue.Method: b"\x00",
    hap_tlv8.TlvValue.SeqNo: b"\x01",
    hap_tlv8.TlvValue.PublicKey: bytes(range(256)) + b"\x01\x02",
}
emit("tlv", hexs(hap_tlv8.write_tlv(tlv)))

# RTP audio packets (two, so the nonce counter advances)
shk = bytes(range(32))
cipher = Chacha20Cipher8byteNonce(shk, shk)
audio = bytes((i * 3) % 256 for i in range(1408))
packets = []
for seq in (0xFFFE, 0xFFFF):
    header = AudioPacketHeader.encode(
        0x80, 0xE0 if seq == 0xFFFE else 0x60, seq, 123456789 + seq, 0xCAFEBABE
    )
    nonce = cipher.out_nonce
    encrypted = cipher.encrypt(audio, aad=header[4:12])
    packets.append(header + encrypted + nonce[-8:])
emit("audioKey", hexs(shk))
emit("audioPayload", hexs(audio))
emit("audioPacket0", hexs(packets[0]))
emit("audioPacket1", hexs(packets[1]))

# Sync + timing + NTP
emit(
    "syncFirst", hexs(SyncPacket.encode(0x90, 0xD4, 7, 1000, 3000000000, 123456, 67600))
)
emit(
    "syncLater", hexs(SyncPacket.encode(0x80, 0xD4, 7, 1000, 3000000001, 654321, 67600))
)
request = TimingPacket.encode(0x80, 0xD2, 7, 0, 0, 0, 0, 0, 3900000000, 4242)
emit("timingRequest", hexs(request))
emit(
    "timingResponse",
    hexs(
        TimingPacket.encode(
            0x80, 0x53 | 0x80, 7, 0, 3900000000, 4242, 3900000005, 99, 3900000005, 99
        )
    ),
)
ntp = (3900000000 << 32) | 0x80000000
emit("ntpSample", str(ntp))
emit("ntpToTs44100", str(timing.ntp2ts(ntp, 44100)))
emit("tsToNtp", str(timing.ts2ntp(172800000, 44100)))

# Request framing, exactly as pyatv writes it to the socket
from pyatv.support.http import _format_message

pair_headers = {
    "User-Agent": "AirPlay/320.20",
    "Connection": "keep-alive",
    "X-Apple-HKP": 4,
    "Content-Type": "application/octet-stream",
}
emit(
    "requestPairPinStart",
    hexs(_format_message("POST", "/pair-pin-start", headers=pair_headers)),
)
emit(
    "requestPairSetup",
    hexs(
        _format_message(
            "POST", "/pair-setup", headers=pair_headers, body=b"\x00\x01\x02"
        )
    ),
)
rtsp_headers = {
    "CSeq": 4,
    "DACP-ID": "ABCDEF0123456789",
    "Active-Remote": 12345,
    "Client-Instance": "ABCDEF0123456789",
}
emit(
    "requestRtspSetup",
    hexs(
        _format_message(
            "SETUP",
            "rtsp://192.168.1.2/99",
            protocol="RTSP/1.0",
            user_agent="AirPlay/550.10",
            content_type="application/x-apple-binary-plist",
            headers=rtsp_headers,
            body=b"bplist00",
        )
    ),
)
emit(
    "requestRtspFlush",
    hexs(
        _format_message(
            "FLUSH",
            "rtsp://192.168.1.2/99",
            protocol="RTSP/1.0",
            user_agent="AirPlay/550.10",
            headers={
                **rtsp_headers,
                "Range": "npt=0-",
                "Session": 0,
                "RTP-Info": "seq=5;rtptime=66150",
            },
        )
    ),
)

print(
    "// Generated by scripts/gen_vectors.py from pyatv 0.18.0 and srptools; do not edit.\nenum Vectors {"
)
print("\n".join(out))
print("}")
