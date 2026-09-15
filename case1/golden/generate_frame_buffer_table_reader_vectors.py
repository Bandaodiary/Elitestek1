"""Generate AXI128 memory images from the framebuffer-table software ABI."""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

from frame_buffer_format import FrameBufferEntry


def _raw(entry: FrameBufferEntry) -> int:
    return int.from_bytes(entry.pack(address_bits=32), "little")


def generate(output_dir: Path) -> dict[str, object]:
    input_entries = [
        FrameBufferEntry(0x0100_0000, 2560, 640, 480),
        FrameBufferEntry(0x0120_0000, 5120, 1280, 720),
        FrameBufferEntry(0x0180_0000, 7680, 1920, 1080),
    ]
    output_entries = [
        FrameBufferEntry(0x0200_0000, 2560, 640, 480),
        FrameBufferEntry(0x0220_0000, 5120, 1280, 720),
    ]
    auxiliary_entries = [
        FrameBufferEntry(0x0300_0000, 1024, 256, 64),
        FrameBufferEntry(0x0310_0000, 2048, 512, 128),
        FrameBufferEntry(0x0320_0000, 4096, 1024, 256),
        FrameBufferEntry(0x0340_0000, 640, 160, 120),
        FrameBufferEntry(0x0350_0000, 1280, 320, 240),
    ]

    image: list[tuple[int, int, str]] = []
    for index, entry in enumerate(input_entries):
        image.append((0x0000_1000 + index * 16, _raw(entry), f"input[{index}]"))
    for index, entry in enumerate(output_entries):
        image.append((0x0000_2000 + index * 16, _raw(entry), f"output[{index}]"))

    image.append((0xFFFF_FFF0, _raw(auxiliary_entries[0]), "last_axi128_window"))

    # Deliberately outside the supported 32-bit framebuffer address space.
    high_base_payload = struct.pack(
        "<QIHH", 0x0000_0001_0400_0000, 2560, 640, 480
    )
    image.append((0x0000_3000, int.from_bytes(high_base_payload, "little"),
                  "entry_base_high_nonzero"))

    for address, entry, label in zip(
        (0x0000_4000, 0x0000_5000, 0x0000_6000,
         0x0000_7000, 0x0000_8000),
        auxiliary_entries,
        ("rresp_error", "missing_rlast", "abort_after_ar",
         "abort_response", "restart"),
    ):
        image.append((address, _raw(entry), label))

    if len(image) != 12:
        raise AssertionError("unexpected framebuffer table image size")

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "frame_buffer_table_reader_entries.txt").write_text(
        str(len(image)) + "\n" +
        "".join(f"{address:08x} {raw:032x}\n" for address, raw, _ in image),
        encoding="ascii",
    )
    manifest: dict[str, object] = {
        "entries": len(image),
        "input_entries": len(input_entries),
        "output_entries": len(output_entries),
        "entry_bytes": 16,
        "records": [
            {"address": address, "label": label}
            for address, _, label in image
        ],
    }
    (output_dir / "frame_buffer_table_reader_manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    print(
        "FRAME_BUFFER_TABLE_READER_VECTORS_PASS "
        f"entries={manifest['entries']} input={manifest['input_entries']} "
        f"output={manifest['output_entries']}"
    )
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    generate(args.output_dir)


if __name__ == "__main__":
    main()
