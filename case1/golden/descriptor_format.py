"""Pack, unpack and validate the C1 64-byte R1 layer descriptor ABI."""

from __future__ import annotations

from dataclasses import dataclass
import struct


VERSION = 1
WORDS = 16
BYTES = 64

OP_CONV3X3 = 1
OP_CONV1X1 = 2
OP_DWCONV3X3 = 3
OP_UPSAMPLE2 = 4
OP_RESIDUAL_ADD = 5
OP_OUTPUT_RGB = 6
ACT_NONE = 0
ACT_RELU = 1
FLAG_SAME_REPLICATE = 1 << 0
FLAG_RESIDUAL_VALID = 1 << 1
FLAG_INPUT_FRAME = 1 << 2
FLAG_OUTPUT_FRAME = 1 << 3
FLAG_PARAM_BANK_1 = 1 << 4


@dataclass(frozen=True)
class LayerDescriptor:
    opcode: int
    activation: int
    flags: int
    input_width: int
    input_height: int
    output_width: int
    output_height: int
    input_channels: int
    output_channels: int
    input_offset: int = 0
    output_offset: int = 0
    residual_offset: int = 0
    weight_offset: int = 0
    bias_offset: int = 0
    multiplier_offset: int = 0
    shift_offset: int = 0
    input_row_stride: int = 0
    output_row_stride: int = 0
    kernel_width: int = 1
    kernel_height: int = 1
    stride_x: int = 1
    stride_y: int = 1
    channel_block: int = 1
    mac_lanes: int = 1
    tile_width: int = 1
    tile_height: int = 1
    cycle_budget: int = 0

    def validate(self) -> None:
        if self.opcode not in range(OP_CONV3X3, OP_OUTPUT_RGB + 1):
            raise ValueError("unsupported opcode")
        if self.activation not in (ACT_NONE, ACT_RELU):
            raise ValueError("unsupported activation")
        if self.flags & ~0x1F:
            raise ValueError("reserved descriptor flag set")
        u16_fields = (
            self.input_width, self.input_height, self.output_width,
            self.output_height, self.input_channels, self.output_channels,
        )
        if any(value <= 0 or value > 0xFFFF for value in u16_fields):
            raise ValueError("dimensions/channels must be nonzero uint16")
        u8_fields = (
            self.kernel_width, self.kernel_height, self.stride_x, self.stride_y,
            self.channel_block, self.mac_lanes, self.tile_width, self.tile_height,
        )
        if any(value <= 0 or value > 0xFF for value in u8_fields):
            raise ValueError("geometry/schedule fields must be nonzero uint8")
        u32_fields = (
            self.input_offset, self.output_offset, self.residual_offset,
            self.weight_offset, self.bias_offset, self.multiplier_offset,
            self.shift_offset, self.input_row_stride, self.output_row_stride,
            self.cycle_budget,
        )
        if any(value < 0 or value > 0xFFFFFFFF for value in u32_fields):
            raise ValueError("offset/stride/budget must be uint32")

        same_width = self.output_width == self.input_width
        same_height = self.output_height == self.input_height
        same_channels = self.output_channels == self.input_channels
        if self.opcode == OP_CONV3X3:
            if (self.kernel_width, self.kernel_height) != (3, 3):
                raise ValueError("CONV3X3 requires a 3x3 kernel")
            if self.stride_x != self.stride_y or self.stride_x not in (1, 2):
                raise ValueError("CONV3X3 requires equal stride 1 or 2")
            expected_width = (self.input_width + self.stride_x - 1) // self.stride_x
            expected_height = (self.input_height + self.stride_y - 1) // self.stride_y
            if (self.output_width, self.output_height) != (expected_width, expected_height):
                raise ValueError("CONV3X3 output dimensions disagree with SAME stride")
            if not (self.flags & FLAG_SAME_REPLICATE):
                raise ValueError("CONV3X3 requires SAME_REPLICATE")
        elif self.opcode == OP_CONV1X1:
            if (self.kernel_width, self.kernel_height, self.stride_x, self.stride_y) != (
                1, 1, 1, 1
            ) or not (same_width and same_height):
                raise ValueError("CONV1X1 requires 1x1, stride1 and unchanged geometry")
        elif self.opcode == OP_DWCONV3X3:
            if (self.kernel_width, self.kernel_height, self.stride_x, self.stride_y) != (
                3, 3, 1, 1
            ) or not (same_width and same_height and same_channels):
                raise ValueError("DWCONV3X3 requires 3x3 stride1 and unchanged H/W/C")
            if not (self.flags & FLAG_SAME_REPLICATE):
                raise ValueError("DWCONV3X3 requires SAME_REPLICATE")
        elif self.opcode == OP_UPSAMPLE2:
            if (self.kernel_width, self.kernel_height, self.stride_x, self.stride_y) != (
                1, 1, 2, 2
            ) or self.output_width != self.input_width * 2 or \
                    self.output_height != self.input_height * 2 or not same_channels:
                raise ValueError("UPSAMPLE2 requires exact 2x H/W and unchanged channels")
        elif self.opcode == OP_RESIDUAL_ADD:
            if (self.kernel_width, self.kernel_height, self.stride_x, self.stride_y) != (
                1, 1, 1, 1
            ) or not (same_width and same_height and same_channels):
                raise ValueError("RESIDUAL_ADD requires unchanged H/W/C")
            if not (self.flags & FLAG_RESIDUAL_VALID):
                raise ValueError("RESIDUAL_ADD requires RESIDUAL_VALID")
        elif self.opcode == OP_OUTPUT_RGB:
            if (self.kernel_width, self.kernel_height, self.stride_x, self.stride_y) != (
                1, 1, 1, 1
            ) or not (same_width and same_height) or \
                    self.input_channels != 3 or self.output_channels != 3:
                raise ValueError("OUTPUT_RGB requires unchanged 3-channel RGB geometry")
            if self.activation != ACT_NONE:
                raise ValueError("OUTPUT_RGB does not accept an activation")

    def words(self) -> tuple[int, ...]:
        self.validate()
        control = (
            self.opcode | (self.activation << 8) | (self.flags << 10)
            | (VERSION << 16) | (WORDS << 24)
        )
        pair16 = lambda low, high: low | (high << 16)
        geometry = (
            self.kernel_width | (self.kernel_height << 8)
            | (self.stride_x << 16) | (self.stride_y << 24)
        )
        schedule = (
            self.channel_block | (self.mac_lanes << 8)
            | (self.tile_width << 16) | (self.tile_height << 24)
        )
        return (
            control,
            pair16(self.input_width, self.input_height),
            pair16(self.output_width, self.output_height),
            pair16(self.input_channels, self.output_channels),
            self.input_offset, self.output_offset, self.residual_offset,
            self.weight_offset, self.bias_offset, self.multiplier_offset,
            self.shift_offset, self.input_row_stride, self.output_row_stride,
            geometry, schedule, self.cycle_budget,
        )

    def pack(self) -> bytes:
        return struct.pack("<16I", *self.words())


def unpack_words(payload: bytes) -> tuple[int, ...]:
    if len(payload) != BYTES:
        raise ValueError(f"descriptor must be {BYTES} bytes")
    words = struct.unpack("<16I", payload)
    control = words[0]
    if ((control >> 16) & 0xFF) != VERSION or ((control >> 24) & 0xFF) != WORDS:
        raise ValueError("descriptor version/length mismatch")
    return words
