#!/usr/bin/env python3
"""Check protocol fixtures independently with the Python standard library.

This validates stored examples, not hardware. RTL behavior is checked separately
by run_comm.py. Accept arbitrary host read() fragmentation/coalescing here.
"""
from __future__ import annotations
import binascii
import json
from pathlib import Path
import random
import struct

ROOT = Path(__file__).resolve().parents[1]


def slip_encode(body: bytes) -> bytes:
    return b"\xc0" + body.replace(b"\xdb", b"\xdb\xdd").replace(b"\xc0", b"\xdb\xdc") + b"\xc0"


class SlipReader:
    def __init__(self) -> None:
        self.started = False
        self.escape = False
        self.bad = False
        self.body = bytearray()

    def feed(self, data: bytes) -> list[bytes]:
        frames = []
        for byte in data:
            if byte == 0xc0:
                if self.started and self.body and not self.bad and not self.escape:
                    frames.append(bytes(self.body))
                self.started = True
                self.body.clear()
                self.escape = self.bad = False
            elif self.started and not self.bad:
                if self.escape:
                    if byte not in (0xdc, 0xdd):
                        self.bad = True
                    else:
                        self.body.append(0xc0 if byte == 0xdc else 0xdb)
                    self.escape = False
                elif byte == 0xdb:
                    self.escape = True
                else:
                    self.body.append(byte)
                if len(self.body) > 40:
                    self.bad = True
        return frames


def check_frame(body: bytes) -> tuple[int, int, bytes]:
    assert 9 <= len(body) <= 40
    version, kind, seq, size = struct.unpack("<BBHH", body[:6])
    assert version == 1 and kind in (1, 2, 0x80)
    assert len(body) == size + 8
    assert 1 <= size <= {1: 32, 2: 16, 0x80: 3}[kind]
    if kind == 0x80:
        assert size == 3
    assert binascii.crc_hqx(body[:-2], 0xffff) == int.from_bytes(body[-2:], "little")
    return kind, seq, body[6:-2]


def main() -> None:
    assert binascii.crc_hqx(b"123456789", 0xffff) == 0x29b1
    vectors = json.loads((ROOT / "rtl/drivers/analyzer/frame_vectors.json").read_text())["vectors"]
    bodies, wires = [], []
    for v in vectors:
        body, wire = bytes.fromhex(v["body_hex"]), bytes.fromhex(v["wire_hex"])
        kind, seq, payload = check_frame(body)
        assert (kind, seq, payload) == (v["type"], v["seq"], bytes.fromhex(v["payload_hex"]))
        assert slip_encode(body) == wire
        assert binascii.crc_hqx(body[:-2], 0xffff) == int(v["crc_hex"], 16)
        if v["name"] == "eq_band0":
            assert struct.unpack("<BBBBHhH", payload) == (1, 0, 1, 0, 1000, -1536, 256)
        bodies.append(body)
        wires.append(wire)
    rng = random.Random(20261026)
    for _ in range(100):
        reader = SlipReader()
        stream = b"garbage prefix" + b"".join(wires)
        decoded = []
        pos = 0
        while pos < len(stream):
            size = rng.randrange(1, 17)
            decoded.extend(reader.feed(stream[pos:pos + size]))
            pos += size
        assert decoded == bodies
    # A shared delimiter is valid, invalid escapes cannot publish partial data.
    assert SlipReader().feed(wires[0] + wires[1][1:]) == bodies[:2]
    assert SlipReader().feed(b"\xc0\x01\xdb\x00\x11\xc0" + wires[0]) == bodies[:1]
    assert SlipReader().feed(b"\xc0\x01\xdb\xc0" + wires[0]) == bodies[:1]
    flipped = bytearray(bodies[0]); flipped[6] ^= 1
    try:
        check_frame(flipped)
    except AssertionError:
        pass
    else:
        raise AssertionError("corrupted fixture passed CRC")
    print(f"PASS {len(vectors)} fixtures, CRC29B1, EQ encoding, 100 fragmented streams, shared delimiter/error recovery")


if __name__ == "__main__":
    main()
