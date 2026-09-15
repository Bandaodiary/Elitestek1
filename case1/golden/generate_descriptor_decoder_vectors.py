"""Generate independent R1 descriptor-decoder validation vectors.

The first vectors cover every legal opcode and every RTL error code.  The
remaining vectors flip one reproducibly random bit in a legal descriptor and
are classified by this Python reference validator.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import random

from descriptor_format import (
    ACT_NONE,
    ACT_RELU,
    FLAG_RESIDUAL_VALID,
    FLAG_SAME_REPLICATE,
    LayerDescriptor,
    OP_CONV1X1,
    OP_CONV3X3,
    OP_DWCONV3X3,
    OP_OUTPUT_RGB,
    OP_RESIDUAL_ADD,
    OP_UPSAMPLE2,
)


ERR_NONE = 0
ERR_VERSION = 1
ERR_WORDS = 2
ERR_OPCODE = 3
ERR_ACTIVATION = 4
ERR_RESERVED_FLAGS = 5
ERR_ZERO_SIZE = 6
ERR_ZERO_CHANNELS = 7
ERR_ZERO_GEOMETRY = 8
ERR_ZERO_SCHEDULE = 9
ERR_ADDRESS_ALIGNMENT = 10
ERR_RESIDUAL_OFFSET = 11
ERR_ROW_ALIGNMENT = 12
ERR_ROW_STRIDE_RANGE = 13
ERR_CONV3_GEOMETRY = 14
ERR_CONV3_FLAGS = 15
ERR_CONV1_GEOMETRY = 16
ERR_DWCONV_GEOMETRY = 17
ERR_DWCONV_FLAGS = 18
ERR_UPSAMPLE_GEOMETRY = 19
ERR_RESIDUAL_GEOMETRY = 20
ERR_RESIDUAL_FLAGS = 21
ERR_OUTPUT_GEOMETRY = 22
ERR_OUTPUT_ACTIVATION = 23

VERSION = 1
WORDS = 16
LEGAL_OPCODES = tuple(range(OP_CONV3X3, OP_OUTPUT_RGB + 1))


def field(descriptor: int, lsb: int, width: int) -> int:
    return (descriptor >> lsb) & ((1 << width) - 1)


def replace_field(descriptor: int, lsb: int, width: int, value: int) -> int:
    mask = ((1 << width) - 1) << lsb
    return (descriptor & ~mask) | ((value << lsb) & mask)


def aligned_row_bytes(width: int, channels: int) -> int:
    return (width * channels + 15) & ~15


def legal_descriptor(opcode: int) -> int:
    input_width, input_height = 13, 9
    output_width, output_height = input_width, input_height
    input_channels, output_channels = 5, 7
    kernel_width = kernel_height = stride_x = stride_y = 1
    activation = ACT_RELU
    flags = 0
    residual_offset = 0

    if opcode == OP_CONV3X3:
        kernel_width = kernel_height = 3
        stride_x = stride_y = 2
        output_width = (input_width + 1) // 2
        output_height = (input_height + 1) // 2
        flags = FLAG_SAME_REPLICATE
    elif opcode == OP_CONV1X1:
        pass
    elif opcode == OP_DWCONV3X3:
        kernel_width = kernel_height = 3
        input_channels = output_channels = 5
        flags = FLAG_SAME_REPLICATE
    elif opcode == OP_UPSAMPLE2:
        stride_x = stride_y = 2
        output_width = input_width * 2
        output_height = input_height * 2
        input_channels = output_channels = 5
        activation = ACT_NONE
    elif opcode == OP_RESIDUAL_ADD:
        input_channels = output_channels = 5
        flags = FLAG_RESIDUAL_VALID
        residual_offset = 0x300
    elif opcode == OP_OUTPUT_RGB:
        input_channels = output_channels = 3
        activation = ACT_NONE
    else:
        raise ValueError(f"unsupported legal opcode {opcode}")

    instance = LayerDescriptor(
        opcode=opcode,
        activation=activation,
        flags=flags,
        input_width=input_width,
        input_height=input_height,
        output_width=output_width,
        output_height=output_height,
        input_channels=input_channels,
        output_channels=output_channels,
        input_offset=0x100,
        output_offset=0x200,
        residual_offset=residual_offset,
        weight_offset=0x400,
        bias_offset=0x500,
        multiplier_offset=0x600,
        shift_offset=0x700,
        input_row_stride=aligned_row_bytes(input_width, input_channels),
        output_row_stride=aligned_row_bytes(output_width, output_channels),
        kernel_width=kernel_width,
        kernel_height=kernel_height,
        stride_x=stride_x,
        stride_y=stride_y,
        channel_block=8,
        mac_lanes=8,
        tile_width=7,
        tile_height=5,
        cycle_budget=0x1234_0000 | opcode,
    )
    return int.from_bytes(instance.pack(), byteorder="little", signed=False)


def validate_descriptor(descriptor: int) -> int:
    opcode = field(descriptor, 0, 8)
    activation = field(descriptor, 8, 2)
    flags = field(descriptor, 10, 6)
    version = field(descriptor, 16, 8)
    words = field(descriptor, 24, 8)
    input_width = field(descriptor, 32, 16)
    input_height = field(descriptor, 48, 16)
    output_width = field(descriptor, 64, 16)
    output_height = field(descriptor, 80, 16)
    input_channels = field(descriptor, 96, 16)
    output_channels = field(descriptor, 112, 16)
    offsets = [field(descriptor, bit, 32) for bit in range(128, 352, 32)]
    residual_offset = offsets[2]
    input_row_stride = field(descriptor, 352, 32)
    output_row_stride = field(descriptor, 384, 32)
    kernel_width = field(descriptor, 416, 8)
    kernel_height = field(descriptor, 424, 8)
    stride_x = field(descriptor, 432, 8)
    stride_y = field(descriptor, 440, 8)
    channel_block = field(descriptor, 448, 8)
    mac_lanes = field(descriptor, 456, 8)
    tile_width = field(descriptor, 464, 8)
    tile_height = field(descriptor, 472, 8)

    if version != VERSION:
        return ERR_VERSION
    if words != WORDS:
        return ERR_WORDS
    if opcode not in LEGAL_OPCODES:
        return ERR_OPCODE
    if activation not in (ACT_NONE, ACT_RELU):
        return ERR_ACTIVATION
    if flags & 0x20:
        return ERR_RESERVED_FLAGS
    if not all((input_width, input_height, output_width, output_height)):
        return ERR_ZERO_SIZE
    if not input_channels or not output_channels:
        return ERR_ZERO_CHANNELS
    if not all((kernel_width, kernel_height, stride_x, stride_y)):
        return ERR_ZERO_GEOMETRY
    if not all((channel_block, mac_lanes, tile_width, tile_height)):
        return ERR_ZERO_SCHEDULE
    if any(offset & 0xF for offset in offsets):
        return ERR_ADDRESS_ALIGNMENT
    if not (flags & FLAG_RESIDUAL_VALID) and residual_offset:
        return ERR_RESIDUAL_OFFSET
    if ((input_row_stride and input_row_stride & 0xF) or
            (output_row_stride and output_row_stride & 0xF)):
        return ERR_ROW_ALIGNMENT
    if ((input_row_stride and input_row_stride < input_width * input_channels) or
            (output_row_stride and
             output_row_stride < output_width * output_channels)):
        return ERR_ROW_STRIDE_RANGE

    same_width = output_width == input_width
    same_height = output_height == input_height
    same_channels = output_channels == input_channels
    if opcode == OP_CONV3X3:
        expected_width = (input_width + stride_x - 1) // stride_x
        expected_height = (input_height + stride_y - 1) // stride_y
        if ((kernel_width, kernel_height) != (3, 3) or
                stride_x != stride_y or stride_x not in (1, 2) or
                (output_width, output_height) !=
                (expected_width, expected_height)):
            return ERR_CONV3_GEOMETRY
        if not (flags & FLAG_SAME_REPLICATE):
            return ERR_CONV3_FLAGS
    elif opcode == OP_CONV1X1:
        if ((kernel_width, kernel_height, stride_x, stride_y) != (1, 1, 1, 1)
                or not (same_width and same_height)):
            return ERR_CONV1_GEOMETRY
    elif opcode == OP_DWCONV3X3:
        if ((kernel_width, kernel_height, stride_x, stride_y) != (3, 3, 1, 1)
                or not (same_width and same_height and same_channels)):
            return ERR_DWCONV_GEOMETRY
        if not (flags & FLAG_SAME_REPLICATE):
            return ERR_DWCONV_FLAGS
    elif opcode == OP_UPSAMPLE2:
        if ((kernel_width, kernel_height, stride_x, stride_y) != (1, 1, 2, 2)
                or output_width != input_width * 2
                or output_height != input_height * 2 or not same_channels):
            return ERR_UPSAMPLE_GEOMETRY
    elif opcode == OP_RESIDUAL_ADD:
        if ((kernel_width, kernel_height, stride_x, stride_y) != (1, 1, 1, 1)
                or not (same_width and same_height and same_channels)):
            return ERR_RESIDUAL_GEOMETRY
        if not (flags & FLAG_RESIDUAL_VALID):
            return ERR_RESIDUAL_FLAGS
    elif opcode == OP_OUTPUT_RGB:
        if ((kernel_width, kernel_height, stride_x, stride_y) != (1, 1, 1, 1)
                or not (same_width and same_height)
                or input_channels != 3 or output_channels != 3):
            return ERR_OUTPUT_GEOMETRY
        if activation != ACT_NONE:
            return ERR_OUTPUT_ACTIVATION
    return ERR_NONE


def directed_invalid_vectors() -> list[tuple[int, int]]:
    vectors: list[tuple[int, int]] = []

    def add(descriptor: int, expected: int) -> None:
        actual = validate_descriptor(descriptor)
        if actual != expected:
            raise AssertionError(
                f"directed vector expected error {expected}, reference returned {actual}"
            )
        vectors.append((expected, descriptor))

    base = legal_descriptor(OP_CONV1X1)
    add(replace_field(base, 16, 8, 2), ERR_VERSION)
    add(replace_field(base, 24, 8, 15), ERR_WORDS)
    add(replace_field(base, 0, 8, 0), ERR_OPCODE)
    add(replace_field(base, 8, 2, 2), ERR_ACTIVATION)
    add(base | (1 << 15), ERR_RESERVED_FLAGS)
    add(replace_field(base, 32, 16, 0), ERR_ZERO_SIZE)
    add(replace_field(base, 96, 16, 0), ERR_ZERO_CHANNELS)
    add(replace_field(base, 416, 8, 0), ERR_ZERO_GEOMETRY)
    add(replace_field(base, 448, 8, 0), ERR_ZERO_SCHEDULE)
    add(replace_field(base, 320, 32, 0x701), ERR_ADDRESS_ALIGNMENT)
    add(replace_field(base, 192, 32, 0x300), ERR_RESIDUAL_OFFSET)
    add(replace_field(base, 352, 32, 81), ERR_ROW_ALIGNMENT)
    add(replace_field(base, 352, 32, 16), ERR_ROW_STRIDE_RANGE)

    conv3 = legal_descriptor(OP_CONV3X3)
    add(replace_field(conv3, 416, 8, 1), ERR_CONV3_GEOMETRY)
    add(conv3 & ~(1 << 10), ERR_CONV3_FLAGS)
    add(replace_field(base, 432, 8, 2), ERR_CONV1_GEOMETRY)

    depthwise = legal_descriptor(OP_DWCONV3X3)
    add(replace_field(depthwise, 112, 16, 6), ERR_DWCONV_GEOMETRY)
    add(depthwise & ~(1 << 10), ERR_DWCONV_FLAGS)

    upsample = legal_descriptor(OP_UPSAMPLE2)
    add(replace_field(upsample, 64, 16, 27), ERR_UPSAMPLE_GEOMETRY)

    residual = legal_descriptor(OP_RESIDUAL_ADD)
    add(replace_field(residual, 64, 16, 14), ERR_RESIDUAL_GEOMETRY)
    residual_without_flag = residual & ~(1 << 11)
    residual_without_flag = replace_field(residual_without_flag, 192, 32, 0)
    add(residual_without_flag, ERR_RESIDUAL_FLAGS)

    output = legal_descriptor(OP_OUTPUT_RGB)
    add(replace_field(output, 64, 16, 12), ERR_OUTPUT_GEOMETRY)
    add(replace_field(output, 8, 2, ACT_RELU), ERR_OUTPUT_ACTIVATION)
    return vectors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--random-count", type=int, default=400)
    parser.add_argument("--seed", type=int, default=20260824)
    args = parser.parse_args()
    if args.random_count < 1:
        raise ValueError("random-count must be positive")

    legal = [(ERR_NONE, legal_descriptor(opcode)) for opcode in LEGAL_OPCODES]
    for expected, descriptor in legal:
        assert validate_descriptor(descriptor) == expected
    directed = directed_invalid_vectors()

    rng = random.Random(args.seed)
    random_vectors: list[tuple[int, int]] = []
    random_valid = 0
    random_invalid = 0
    for _ in range(args.random_count):
        descriptor = legal_descriptor(rng.choice(LEGAL_OPCODES))
        descriptor ^= 1 << rng.randrange(512)
        error = validate_descriptor(descriptor)
        random_vectors.append((error, descriptor))
        if error == ERR_NONE:
            random_valid += 1
        else:
            random_invalid += 1

    vectors = legal + directed + random_vectors
    args.output_dir.mkdir(parents=True, exist_ok=True)
    memory_path = args.output_dir / "descriptor_decoder_vectors.mem"
    with memory_path.open("w", encoding="ascii", newline="\n") as stream:
        for error, descriptor in vectors:
            stream.write(f"{error:02x}{descriptor:0128x}\n")

    manifest = {
        "schema_version": 1,
        "seed": args.seed,
        "legal_opcode_vectors": len(legal),
        "directed_invalid_vectors": len(directed),
        "random_bitflip_vectors": len(random_vectors),
        "random_valid": random_valid,
        "random_invalid": random_invalid,
        "total_vectors": len(vectors),
        "memory_file": memory_path.name,
    }
    (args.output_dir / "descriptor_decoder_vectors.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    print(
        "C1_DESCRIPTOR_DECODER_VECTOR_GEN_PASS "
        f"total={len(vectors)} random_valid={random_valid} "
        f"random_invalid={random_invalid}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

