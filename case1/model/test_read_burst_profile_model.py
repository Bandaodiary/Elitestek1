"""Focused checks for long-burst 4-KiB geometry."""

from read_burst_profile_model import row_profile


def main() -> None:
    profile = row_profile(row_words64=1280, burst_beats=16)
    profile32 = row_profile(row_words64=1280, burst_beats=32)
    assert profile["beats"] == 640
    assert profile["bursts"] == 40
    assert profile["lengths"] == [16] * 40
    # The 32-beat candidate halves the AR descriptor count for a steady row;
    # payload beats remain identical.  Keep this as a boardless geometry
    # contract so the RTL A/B profile and the model cannot silently diverge.
    assert profile32["beats"] == 640
    assert profile32["bursts"] == 20
    assert profile32["lengths"] == [32] * 20

    # Base at 0xff0 leaves a single beat in the current page.  The next
    # descriptor must start a new page even though the configured profile is
    # 16 beats long.
    crossing = row_profile(row_words64=34, burst_beats=16, base_addr=0x00000FF0)
    assert crossing["lengths"] == [1, 16]
    print(
        "READ_BURST_PROFILE_TEST_PASS "
        f"steady_bursts_16_32={profile['bursts']}/{profile32['bursts']} "
        f"crossing_lengths={crossing['lengths']}"
    )


if __name__ == "__main__":
    main()
