"""Unit tests for the shared C1 framebuffer table ABI."""

from __future__ import annotations

from frame_buffer_format import (
    ENTRY_BYTES,
    FrameBufferEntry,
    INPUT_ENTRIES,
    OUTPUT_ENTRIES,
    pack_table,
    unpack_entry,
)


def main() -> int:
    frame_bytes = 640 * 480 * 4
    inputs = [
        FrameBufferEntry(0x0100_0000 + index * 0x0020_0000, 2560, 640, 480)
        for index in range(INPUT_ENTRIES)
    ]
    outputs = [
        FrameBufferEntry(0x0200_0000 + index * 0x0020_0000, 2560, 640, 480)
        for index in range(OUTPUT_ENTRIES)
    ]
    packed_inputs = pack_table(inputs, INPUT_ENTRIES)
    packed_outputs = pack_table(outputs, OUTPUT_ENTRIES)
    assert len(packed_inputs) == INPUT_ENTRIES * ENTRY_BYTES
    assert len(packed_outputs) == OUTPUT_ENTRIES * ENTRY_BYTES
    assert unpack_entry(packed_inputs[:ENTRY_BYTES]) == inputs[0]
    assert frame_bytes == 1_228_800

    bad_entries = (
        FrameBufferEntry(0x1003, 2560, 640, 480),
        FrameBufferEntry(0x1000, 1920, 640, 480),
        FrameBufferEntry(0xFFFF_FFF0, 16, 4, 2),
    )
    for bad in bad_entries:
        try:
            bad.pack()
        except ValueError:
            pass
        else:
            raise AssertionError(f"invalid framebuffer entry accepted: {bad}")

    try:
        pack_table([inputs[0], inputs[0], inputs[2]], INPUT_ENTRIES)
    except ValueError:
        pass
    else:
        raise AssertionError("overlapping framebuffer regions were accepted")

    print("C1_FRAME_BUFFER_FORMAT_PASS entry_bytes=16 input=3 output=2")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

