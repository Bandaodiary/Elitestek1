"""Pack and validate the C1 16-byte framebuffer-table entry ABI."""

from __future__ import annotations

from dataclasses import dataclass
import struct


ENTRY_BYTES = 16
INPUT_ENTRIES = 3
OUTPUT_ENTRIES = 2
PIXEL_BYTES = 4


@dataclass(frozen=True)
class FrameBufferEntry:
    base_address: int
    stride_bytes: int
    width_pixels: int
    height_lines: int

    def validate(self, address_bits: int = 32) -> None:
        if address_bits <= 0 or address_bits > 64:
            raise ValueError("address_bits must be in 1..64")
        limit = 1 << address_bits
        if self.base_address < 0 or self.base_address >= limit:
            raise ValueError("framebuffer base is outside the AXI address space")
        if self.base_address & 0xF:
            raise ValueError("framebuffer base must be 16-byte aligned")
        if not (1 <= self.width_pixels <= 0xFFFF):
            raise ValueError("width must be a nonzero uint16")
        if not (1 <= self.height_lines <= 0xFFFF):
            raise ValueError("height must be a nonzero uint16")
        minimum_stride = self.width_pixels * PIXEL_BYTES
        if (self.stride_bytes < minimum_stride) or (self.stride_bytes & 0xF):
            raise ValueError("stride must be 16-byte aligned and at least width*4")
        if self.stride_bytes > 0xFFFFFFFF:
            raise ValueError("stride must fit uint32")
        end_exclusive = (
            self.base_address
            + (self.height_lines - 1) * self.stride_bytes
            + minimum_stride
        )
        if end_exclusive > limit:
            raise ValueError("framebuffer extent overflows the AXI address space")

    def pack(self, address_bits: int = 32) -> bytes:
        self.validate(address_bits)
        return struct.pack(
            "<QIHH",
            self.base_address,
            self.stride_bytes,
            self.width_pixels,
            self.height_lines,
        )


def unpack_entry(payload: bytes, address_bits: int = 32) -> FrameBufferEntry:
    if len(payload) != ENTRY_BYTES:
        raise ValueError(f"framebuffer entry must be {ENTRY_BYTES} bytes")
    entry = FrameBufferEntry(*struct.unpack("<QIHH", payload))
    entry.validate(address_bits)
    return entry


def pack_table(entries: list[FrameBufferEntry], expected_entries: int) -> bytes:
    if len(entries) != expected_entries:
        raise ValueError(f"table requires exactly {expected_entries} entries")
    ranges: list[tuple[int, int]] = []
    payload = bytearray()
    for entry in entries:
        payload.extend(entry.pack())
        end = (
            entry.base_address
            + (entry.height_lines - 1) * entry.stride_bytes
            + entry.width_pixels * PIXEL_BYTES
        )
        ranges.append((entry.base_address, end))
    for index, first in enumerate(ranges):
        for second in ranges[index + 1 :]:
            if max(first[0], second[0]) < min(first[1], second[1]):
                raise ValueError("framebuffer regions overlap")
    return bytes(payload)


__all__ = [
    "ENTRY_BYTES",
    "FrameBufferEntry",
    "INPUT_ENTRIES",
    "OUTPUT_ENTRIES",
    "PIXEL_BYTES",
    "pack_table",
    "unpack_entry",
]

