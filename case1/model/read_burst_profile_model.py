"""Small geometry model for boardless AXI read-burst profiles.

It counts AR descriptors after 64-bit-to-128-bit packing and mandatory 4-KiB
splitting.  It deliberately does not model DDR turnaround, arbitration or MAC
time; the result is only the address-channel pressure removed by a longer
burst parameter.
"""

from __future__ import annotations


def row_profile(*, row_words64: int, burst_beats: int, base_addr: int = 0) -> dict:
    if row_words64 <= 0 or burst_beats <= 0 or burst_beats > 256:
        raise ValueError("row_words64 must be positive and burst_beats in 1..256")
    if base_addr & 0x7:
        raise ValueError("base_addr must be 64-bit aligned")

    beats = (row_words64 + 1) // 2
    beat_addr = base_addr & ~0xF
    remaining = beats
    bursts = 0
    lengths: list[int] = []
    while remaining:
        page_beats = (4096 - (beat_addr & 0xFFF)) // 16
        take = min(remaining, burst_beats, page_beats)
        if take <= 0:
            raise AssertionError("4-KiB splitter made no forward progress")
        lengths.append(take)
        bursts += 1
        remaining -= take
        beat_addr += take * 16
    return {"beats": beats, "bursts": bursts, "lengths": lengths}


def main() -> None:
    # MAX_ROW_WORDS=1280 is the cache shell's default envelope.  Three rows
    # are the resident C8 window-cache footprint and exercise 4-KiB crossing.
    rows = 3
    row_words64 = 1280
    values = {b: row_profile(row_words64=row_words64, burst_beats=b) for b in (4, 16, 32)}
    assert values[4]["beats"] == 640
    assert values[16]["bursts"] == 40
    assert values[32]["bursts"] == 20
    assert all(length <= 256 for value in values.values() for length in value["lengths"])

    # A deliberately simple lower-bound cost: one cycle per R beat plus one
    # address issue opportunity per burst.  Real DDR may hide some/all AR
    # cost through outstanding descriptors; the model is a sizing comparison.
    c4 = rows * (values[4]["beats"] + values[4]["bursts"])
    c16 = rows * (values[16]["beats"] + values[16]["bursts"])
    c32 = rows * (values[32]["beats"] + values[32]["bursts"])
    print(
        "READ_BURST_PROFILE_MODEL_PASS "
        f"rows={rows} row_words={row_words64} beats_per_row={values[4]['beats']} "
        f"bursts_4_16_32={values[4]['bursts']}/{values[16]['bursts']}/{values[32]['bursts']} "
        f"proxy_cycles_4_16_32={c4}/{c16}/{c32}"
    )


if __name__ == "__main__":
    main()
