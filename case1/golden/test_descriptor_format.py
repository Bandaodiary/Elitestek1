"""Unit tests for the shared C1 descriptor byte/word layout."""

from __future__ import annotations

from descriptor_format import (
    ACT_RELU,
    BYTES,
    OP_CONV3X3,
    LayerDescriptor,
    unpack_words,
)


def _fixed_case1_size_limit(pixel_count: int, bytes_per_group: int) -> bool:
    """Mirror the RTL fixed-limit shortcut for the 8 MiB Case-1 bank.

    The RTL uses this table only behind the strict, 22-stage, narrow-size
    pipeline fence.  Keeping the tiny reference here gives the optional
    synthesis optimization an executable boundary check without touching the
    default descriptor ABI or runtime path.
    """
    limits = {
        8: 1_048_576,
        16: 524_288,
        24: 349_525,
        32: 262_144,
        40: 209_715,
        48: 174_762,
    }
    return bytes_per_group in limits and pixel_count <= limits[bytes_per_group]


def _check_fixed_case1_size_limits() -> None:
    """Check threshold equality/overflow and deterministic interior points."""
    limits = (8, 16, 24, 32, 40, 48)
    for bytes_per_group in limits:
        limit = (8 * 1024 * 1024) // bytes_per_group
        assert _fixed_case1_size_limit(limit, bytes_per_group)
        assert not _fixed_case1_size_limit(limit + 1, bytes_per_group)
        # The table must agree with the generic byte-count inequality at a
        # handful of representative values on both sides of the boundary.
        for pixel_count in (0, 1, limit // 2, limit - 1, limit, limit + 1):
            expected = pixel_count * bytes_per_group <= 8 * 1024 * 1024
            assert _fixed_case1_size_limit(pixel_count, bytes_per_group) == expected
    for bytes_per_group in (0, 7, 56, 64):
        assert not _fixed_case1_size_limit(0, bytes_per_group)


def main() -> int:
    _check_fixed_case1_size_limits()
    descriptor = LayerDescriptor(
        opcode=OP_CONV3X3,
        activation=ACT_RELU,
        flags=0x0D,
        input_width=640,
        input_height=480,
        output_width=320,
        output_height=240,
        input_channels=3,
        output_channels=12,
        input_offset=0x1000,
        output_offset=0x2000,
        weight_offset=0x3000,
        bias_offset=0x4000,
        multiplier_offset=0x5000,
        shift_offset=0x6000,
        input_row_stride=640 * 3,
        output_row_stride=320 * 12,
        kernel_width=3,
        kernel_height=3,
        stride_x=2,
        stride_y=2,
        channel_block=8,
        mac_lanes=5,
        tile_width=16,
        tile_height=8,
        cycle_budget=6_000_000,
    )
    payload = descriptor.pack()
    assert len(payload) == BYTES
    words = unpack_words(payload)
    assert words == descriptor.words()
    assert words[0] == 0x10013501
    assert words[1] == (480 << 16) | 640
    assert words[2] == (240 << 16) | 320
    assert words[3] == (12 << 16) | 3
    assert words[13] == 0x02020303
    assert words[14] == 0x08100508

    try:
        LayerDescriptor(**{**descriptor.__dict__, "stride_x": 0}).pack()
    except ValueError:
        pass
    else:
        raise AssertionError("zero stride was not rejected")

    try:
        unpack_words(payload[:-1])
    except ValueError:
        pass
    else:
        raise AssertionError("short descriptor was not rejected")

    print("C1_DESCRIPTOR_SIZE_LIMITS_PASS groups=6 boundary_checks=36")
    print("C1_DESCRIPTOR_FORMAT_PASS words=16 bytes=64")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
