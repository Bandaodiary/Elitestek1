"""Audit the native MicroStyle-24 artifact against the RTL ABI.

This is a small, dependency-free guard for the exported 640x480 artifact.  It
does not run the CNN and it never allocates a frame-sized simulation image.  A
passing result means that the descriptor bytes, parameter arena regions and
the simulator ``.mem`` views obey the contracts consumed by
``c1_layer_command_decoder``, ``c1_r1_c8_parameter_scheduler`` and
``c1_r1_microstyle_engine``.  It is deliberately separate from the native
data-plane/15-fps claim.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
sys.path.insert(0, str(ROOT / "golden"))

from descriptor_format import unpack_words  # noqa: E402
from microstyle_layout import build_layout  # noqa: E402


DESCRIPTOR_BYTES = 64
DESCRIPTOR_WORDS = 16
PARAM_ARENA_BYTES = 16896
PARAM_ADDR_W = 11
MAX_CHANNELS = 48
MAX_WEIGHT_BYTES = 2592
MAX_SHIFT = 47

OP_CONV3X3 = 1
OP_CONV1X1 = 2
OP_DWCONV3X3 = 3
OP_UPSAMPLE2 = 4
OP_RESIDUAL_ADD = 5
OP_OUTPUT_RGB = 6

PARAMETER_OPCODES = {OP_CONV3X3, OP_CONV1X1, OP_DWCONV3X3}


def _pair16(word: int) -> tuple[int, int]:
    return word & 0xFFFF, (word >> 16) & 0xFFFF


def _geometry(word: int) -> tuple[int, int, int, int]:
    return tuple((word >> shift) & 0xFF for shift in (0, 8, 16, 24))  # type: ignore[return-value]


def _schedule(word: int) -> tuple[int, int, int, int]:
    return tuple((word >> shift) & 0xFF for shift in (0, 8, 16, 24))  # type: ignore[return-value]


def _decode(payload: bytes) -> dict[str, object]:
    """Decode the little-endian 16-word descriptor into ABI field names."""
    words = unpack_words(payload)
    control = words[0]
    in_w, in_h = _pair16(words[1])
    out_w, out_h = _pair16(words[2])
    in_c, out_c = _pair16(words[3])
    kernel_w, kernel_h, stride_x, stride_y = _geometry(words[13])
    channel_block, mac_lanes, tile_w, tile_h = _schedule(words[14])
    return {
        "words": words,
        "opcode": control & 0xFF,
        "activation": (control >> 8) & 0x3,
        # The RTL decoder calls this a six-bit field, with bit 5 reserved.
        "flags": (control >> 10) & 0x3F,
        "version": (control >> 16) & 0xFF,
        "word_count": (control >> 24) & 0xFF,
        "input_width": in_w,
        "input_height": in_h,
        "output_width": out_w,
        "output_height": out_h,
        "input_channels": in_c,
        "output_channels": out_c,
        "input_offset": words[4],
        "output_offset": words[5],
        "residual_offset": words[6],
        "weight_offset": words[7],
        "bias_offset": words[8],
        "multiplier_offset": words[9],
        "shift_offset": words[10],
        "input_row_stride": words[11],
        "output_row_stride": words[12],
        "kernel_width": kernel_w,
        "kernel_height": kernel_h,
        "stride_x": stride_x,
        "stride_y": stride_y,
        "channel_block": channel_block,
        "mac_lanes": mac_lanes,
        "tile_width": tile_w,
        "tile_height": tile_h,
        "cycle_budget": words[15],
    }


def _region_sizes(opcode: int, input_channels: int, output_channels: int) -> dict[str, int]:
    if opcode == OP_CONV3X3:
        weight_bytes = input_channels * output_channels * 9
    elif opcode == OP_CONV1X1:
        weight_bytes = input_channels * output_channels
    elif opcode == OP_DWCONV3X3:
        weight_bytes = input_channels * 9
    else:
        weight_bytes = 0
    if not weight_bytes:
        return {"weight": 0, "bias": 0, "multiplier": 0, "shift": 0}
    return {
        "weight": weight_bytes,
        "bias": output_channels * 4,
        "multiplier": output_channels * 4,
        "shift": output_channels,
    }


def _region_intervals(desc: dict[str, object]) -> dict[str, tuple[int, int]]:
    sizes = _region_sizes(
        int(desc["opcode"]), int(desc["input_channels"]), int(desc["output_channels"])
    )
    return {
        name: (int(desc[f"{name}_offset"]), size)
        for name, size in sizes.items()
        if size
    }


def _check_rtl_descriptor(desc: dict[str, object], index: int) -> None:
    """Mirror the decoder and parameter-scheduler checks relevant to a leaf."""
    fail = lambda message: (_ for _ in ()).throw(  # noqa: E731
        ValueError(f"descriptor[{index}] {message}")
    )
    opcode = int(desc["opcode"])
    activation = int(desc["activation"])
    flags = int(desc["flags"])
    if int(desc["version"]) != 1:
        fail("version is not 1")
    if int(desc["word_count"]) != DESCRIPTOR_WORDS:
        fail("word count is not 16")
    if not OP_CONV3X3 <= opcode <= OP_OUTPUT_RGB:
        fail(f"unsupported opcode {opcode}")
    if activation > 1:
        fail(f"unsupported activation {activation}")
    if flags & ~0x1F:
        fail(f"reserved flags set 0x{flags:x}")

    dims = [
        int(desc["input_width"]), int(desc["input_height"]),
        int(desc["output_width"]), int(desc["output_height"]),
    ]
    channels = [int(desc["input_channels"]), int(desc["output_channels"])]
    if any(value <= 0 or value > 0xFFFF for value in dims):
        fail("zero/out-of-range spatial dimension")
    if any(value <= 0 or value > 0xFFFF for value in channels):
        fail("zero/out-of-range channel count")
    geometry = [
        int(desc["kernel_width"]), int(desc["kernel_height"]),
        int(desc["stride_x"]), int(desc["stride_y"]),
    ]
    schedule = [
        int(desc["channel_block"]), int(desc["mac_lanes"]),
        int(desc["tile_width"]), int(desc["tile_height"]),
    ]
    if any(value == 0 for value in geometry):
        fail("zero geometry field")
    if any(value == 0 for value in schedule):
        fail("zero schedule field")

    offsets = [
        int(desc[name])
        for name in (
            "input_offset", "output_offset", "residual_offset", "weight_offset",
            "bias_offset", "multiplier_offset", "shift_offset",
        )
    ]
    if any(value & 0xF for value in offsets):
        fail("unaligned byte offset")
    if not (flags & (1 << 1)) and int(desc["residual_offset"]) != 0:
        fail("residual offset is nonzero without RESIDUAL_VALID")
    for stride_name, width_name, channel_name in (
        ("input_row_stride", "input_width", "input_channels"),
        ("output_row_stride", "output_width", "output_channels"),
    ):
        stride = int(desc[stride_name])
        if stride and (stride & 0xF):
            fail(f"{stride_name} is not 16-byte aligned")
        if stride and stride < int(desc[width_name]) * int(desc[channel_name]):
            fail(f"{stride_name} is shorter than one row")

    iw, ih = int(desc["input_width"]), int(desc["input_height"])
    ow, oh = int(desc["output_width"]), int(desc["output_height"])
    ic, oc = int(desc["input_channels"]), int(desc["output_channels"])
    kw, kh = int(desc["kernel_width"]), int(desc["kernel_height"])
    sx, sy = int(desc["stride_x"]), int(desc["stride_y"])
    if opcode == OP_CONV3X3:
        if (kw, kh) != (3, 3) or sx != sy or sx not in (1, 2):
            fail("CONV3X3 geometry mismatch")
        if (ow, oh) != ((iw + sx - 1) // sx, (ih + sy - 1) // sy):
            fail("CONV3X3 output geometry mismatch")
        if not (flags & 1):
            fail("CONV3X3 lacks SAME_REPLICATE")
    elif opcode == OP_CONV1X1:
        if (kw, kh, sx, sy) != (1, 1, 1, 1) or (ow, oh) != (iw, ih):
            fail("CONV1X1 geometry mismatch")
    elif opcode == OP_DWCONV3X3:
        if (kw, kh, sx, sy) != (3, 3, 1, 1) or (ow, oh, oc) != (iw, ih, ic):
            fail("DWCONV3X3 geometry mismatch")
        if not (flags & 1):
            fail("DWCONV3X3 lacks SAME_REPLICATE")
    elif opcode == OP_UPSAMPLE2:
        if (kw, kh, sx, sy) != (1, 1, 2, 2) or (ow, oh, oc) != (iw * 2, ih * 2, ic):
            fail("UPSAMPLE2 geometry mismatch")
    elif opcode == OP_RESIDUAL_ADD:
        if (kw, kh, sx, sy) != (1, 1, 1, 1) or (ow, oh, oc) != (iw, ih, ic):
            fail("RESIDUAL_ADD geometry mismatch")
        if not (flags & (1 << 1)):
            fail("RESIDUAL_ADD lacks RESIDUAL_VALID")
    elif opcode == OP_OUTPUT_RGB:
        if (kw, kh, sx, sy) != (1, 1, 1, 1) or (ow, oh) != (iw, ih) or (ic, oc) != (3, 3):
            fail("OUTPUT_RGB geometry mismatch")
        if activation != 0:
            fail("OUTPUT_RGB has activation")

    if opcode in PARAMETER_OPCODES:
        if ic > MAX_CHANNELS or oc > MAX_CHANNELS:
            fail("channel count exceeds scheduler MAX_CHANNELS")
        if opcode == OP_DWCONV3X3 and ic != oc:
            fail("depthwise channel mismatch")
        sizes = _region_sizes(opcode, ic, oc)
        if sizes["weight"] > MAX_WEIGHT_BYTES:
            fail("weight region exceeds scheduler MAX_WEIGHT_BYTES")
        for name, (offset, size) in _region_intervals(desc).items():
            if offset + size > PARAM_ARENA_BYTES:
                fail(f"{name} region exceeds parameter arena")
            # PARAM_ADDR_W=11 is the concrete native engine setting.  This
            # also catches an accidental truncation before the bank sees it.
            last_word = (offset + size - 1) >> 4
            if last_word >= (1 << PARAM_ADDR_W):
                fail(f"{name} address does not fit PARAM_ADDR_W={PARAM_ADDR_W}")


def _read_mem_lines(path: Path, width_bytes: int) -> bytes:
    lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines()]
    lines = [line for line in lines if line and not line.startswith("//")]
    result = bytearray()
    for line_no, line in enumerate(lines, 1):
        if len(line) != width_bytes * 2:
            raise ValueError(f"{path.name} line {line_no} has {len(line)} hex chars")
        try:
            textual = bytes.fromhex(line)
        except ValueError as exc:
            raise ValueError(f"{path.name} line {line_no} is not hexadecimal") from exc
        # The generators reverse each little-endian payload before writing a
        # line because $readmemh assigns the first textual nibble to the MSB.
        result.extend(textual[::-1])
    return bytes(result)


def _check_mem_views(
    descriptor_bytes: bytes, arena: bytes, vectors: Path
) -> tuple[int, int]:
    desc_mem = vectors / "descriptors.mem"
    param_mem = vectors / "parameter_arena.mem"
    if not desc_mem.is_file() or not param_mem.is_file():
        raise ValueError(f"missing simulator views under {vectors}")
    decoded_desc = _read_mem_lines(desc_mem, DESCRIPTOR_BYTES)
    decoded_param = _read_mem_lines(param_mem, 16)
    if decoded_desc != descriptor_bytes:
        raise ValueError("descriptors.mem does not reconstruct descriptors.bin")
    if decoded_param != arena:
        raise ValueError("parameter_arena.mem does not reconstruct parameter_arena.bin")
    return len(decoded_desc) // DESCRIPTOR_BYTES, len(decoded_param) // 16


def _check_arena(
    arena: bytes, manifest: dict[str, object], descriptors: list[dict[str, object]]
) -> tuple[int, int, int]:
    rows = manifest.get("parameter_layout")
    if not isinstance(rows, list):
        raise ValueError("manifest parameter_layout is missing")
    intervals: list[tuple[int, int, str]] = []
    payload_bytes = 0
    read_words = 0
    for desc in descriptors:
        for name, (offset, size) in _region_intervals(desc).items():
            if offset & 0xF:
                raise ValueError(f"{name} offset is not 16-byte aligned")
            if offset < 0 or offset + size > len(arena):
                raise ValueError(f"{name} payload is outside arena")
            intervals.append((offset, offset + size, name))
            payload_bytes += size
            read_words += (size + 15) // 16
    intervals.sort()
    for previous, current in zip(intervals, intervals[1:]):
        if current[0] < previous[1]:
            raise ValueError(f"parameter regions overlap: {previous[2]} and {current[2]}")

    # The exported arena is zero-filled between payload regions and in the
    # final alignment tail.  This is not needed for correctness of the valid
    # bytes, but catches accidental endian/offset writes in the artifact.
    covered = bytearray(len(arena))
    for start, end, _ in intervals:
        covered[start:end] = b"\x01" * (end - start)
    nonzero_padding = sum(
        1 for index, value in enumerate(arena) if not covered[index] and value != 0
    )
    if nonzero_padding:
        raise ValueError(f"arena has {nonzero_padding} nonzero padding bytes")

    # Compare every manifest row to the descriptor-derived regions.  This
    # verifies that software metadata and what RTL actually receives agree.
    manifest_by_name = {str(row["name"]): row for row in rows}
    if len(manifest_by_name) != len(rows):
        raise ValueError("manifest parameter_layout contains duplicate names")
    descriptor_parameter_names = {
        str(manifest["layers"][index]["name"])
        for index, desc in enumerate(descriptors)
        if int(desc["opcode"]) in PARAMETER_OPCODES
    }
    if set(manifest_by_name) != descriptor_parameter_names:
        raise ValueError("manifest parameter_layout names do not match parameter descriptors")
    for index, desc in enumerate(descriptors):
        if int(desc["opcode"]) not in PARAMETER_OPCODES:
            continue
        expected_name = str(manifest["layers"][index]["name"])
        row = manifest_by_name.get(expected_name)
        if row is None:
            raise ValueError(f"parameter_layout has no row for {expected_name}")
        for name, (offset, size) in _region_intervals(desc).items():
            if int(row[f"{name}_offset"]) != offset or int(row[f"{name}_bytes"]) != size:
                raise ValueError(f"metadata/descriptor region mismatch for {expected_name}.{name}")

    # Check the signed affine encoding exactly as consumed by the RTL cache.
    affine_values = 0
    for row in rows:
        name = str(row["name"])
        mult_offset = int(row["multiplier_offset"])
        mult_bytes = int(row["multiplier_bytes"])
        shift_offset = int(row["shift_offset"])
        shift_bytes = int(row["shift_bytes"])
        multipliers = [
            struct.unpack_from("<i", arena, mult_offset + 4 * i)[0]
            for i in range(mult_bytes // 4)
        ]
        shifts = arena[shift_offset : shift_offset + shift_bytes]
        if any(value < -(1 << 17) or value > (1 << 17) - 1 for value in multipliers):
            raise ValueError(f"{name} has a multiplier outside signed18")
        if any(value > MAX_SHIFT for value in shifts):
            raise ValueError(f"{name} has a shift above {MAX_SHIFT}")
        affine_values += len(multipliers) + len(shifts)

        # Quantized metadata carries the same extrema; checking them catches
        # a wrong little-endian interpretation without dumping the arena.
        qrows = manifest.get("quantized_layers")
        if isinstance(qrows, list):
            qrow = next((item for item in qrows if str(item.get("name")) == name), None)
            if qrow is None:
                raise ValueError(f"quantized_layers has no row for {name}")
            if multipliers and (
                min(multipliers) != int(qrow["multiplier_min"])
                or max(multipliers) != int(qrow["multiplier_max"])
            ):
                raise ValueError(f"{name} multiplier extrema disagree with manifest")
            if shifts and (
                min(shifts) != int(qrow["shift_min"])
                or max(shifts) != int(qrow["shift_max"])
            ):
                raise ValueError(f"{name} shift extrema disagree with manifest")
    return payload_bytes, read_words, affine_values


def audit(artifact: Path, vectors: Path) -> dict[str, object]:
    manifest_path = artifact / "manifest.json"
    if not manifest_path.is_file():
        raise ValueError(f"missing {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    descriptor_name = str(manifest.get("descriptor_file", "descriptors.bin"))
    parameter_name = str(manifest.get("parameter_file", "parameter_arena.bin"))
    descriptor_bytes = (artifact / descriptor_name).read_bytes()
    arena = (artifact / parameter_name).read_bytes()

    descriptor_count = int(manifest.get("descriptor_count", 0))
    if len(descriptor_bytes) != descriptor_count * DESCRIPTOR_BYTES:
        raise ValueError("descriptor file length disagrees with manifest")
    if len(arena) != int(manifest.get("parameter_arena_bytes", -1)):
        raise ValueError("parameter arena length disagrees with manifest")
    if len(arena) != PARAM_ARENA_BYTES:
        raise ValueError(f"native arena must be {PARAM_ARENA_BYTES} bytes")
    if [int(manifest.get("width", 0)), int(manifest.get("height", 0))] != [640, 480]:
        raise ValueError("this native guard expects a 640x480 artifact")

    descriptors = []
    for index in range(descriptor_count):
        payload = descriptor_bytes[index * DESCRIPTOR_BYTES : (index + 1) * DESCRIPTOR_BYTES]
        desc = _decode(payload)
        _check_rtl_descriptor(desc, index)
        descriptors.append(desc)

    expected_descriptors, expected_manifest = build_layout(640, 480)
    expected_bytes = b"".join(item.pack() for item in expected_descriptors)
    if descriptor_bytes != expected_bytes:
        raise ValueError("native descriptors.bin differs from frozen RTL layout")
    if descriptor_count != len(expected_descriptors):
        raise ValueError("descriptor count differs from frozen 22-stage layout")

    layers = manifest.get("layers")
    if not isinstance(layers, list) or len(layers) != descriptor_count:
        raise ValueError("manifest layers do not cover every descriptor")
    for index, (desc, expected) in enumerate(zip(descriptors, expected_descriptors)):
        if tuple(desc["words"]) != expected.words():
            raise ValueError(f"descriptor[{index}] does not match expected words")
        layer = layers[index]
        if str(layer.get("name")) != str(expected_manifest["layers"][index]["name"]):
            raise ValueError(f"manifest layer name mismatch at index {index}")
        for field in (
            "opcode", "activation", "input_width", "input_height", "output_width",
            "output_height", "input_channels", "output_channels", "mac_lanes",
        ):
            if int(layer[field]) != int(desc[field]):
                raise ValueError(f"manifest/descriptor mismatch at {index}.{field}")

    payload_bytes, read_words, affine_values = _check_arena(arena, manifest, descriptors)
    mem_desc, mem_words = _check_mem_views(descriptor_bytes, arena, vectors)
    if payload_bytes != 16379 or read_words != 1030:
        raise ValueError("native scheduler payload/read-word count changed unexpectedly")
    return {
        "native_geometry": "640x480",
        "descriptor_count": descriptor_count,
        "descriptor_bytes": len(descriptor_bytes),
        "arena_bytes": len(arena),
        "payload_bytes": payload_bytes,
        "scheduler_read_words": read_words,
        "scheduler_last_word": max(
            (int(desc[f"{name}_offset"]) + size - 1) >> 4
            for desc in descriptors
            for name, (_, size) in _region_intervals(desc).items()
        ),
        "affine_values_checked": affine_values,
        "descriptor_mem_records": mem_desc,
        "parameter_mem_words": mem_words,
        "status": "PASS",
        "boundary": "descriptor/parameter ABI only; native data-plane CNN remains unrun",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--artifact",
        type=Path,
        default=ROOT / "model" / "microstyle24_starry_functional",
    )
    parser.add_argument(
        "--vectors",
        type=Path,
        default=ROOT / "vectors" / "microstyle_artifact",
    )
    args = parser.parse_args()
    try:
        result = audit(args.artifact, args.vectors)
    except Exception as exc:  # keep CI output compact and actionable
        print(f"C1_NATIVE_ARTIFACT_ABI_FAIL reason={exc}", file=sys.stderr)
        return 1
    print(
        "C1_NATIVE_ARTIFACT_ABI_PASS",
        " ".join(f"{key}={value}" for key, value in result.items() if key != "status"),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
