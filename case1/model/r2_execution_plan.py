"""Lower an explicit tensor DAG to the existing R2 row-engine contract.

This is a compile-time planner, not an arbitrary-CNN runtime or an R1
descriptor interpreter. Unsupported operators/shapes/fusions fail closed.
The MicroStyle adapter supplies graph edges; lowering never infers a
residual source, bank or kernel from a stage number or layer name.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from microstyle_layout import (  # also establishes the existing golden import path
    ACT_NONE, ACT_RELU, FLAG_INPUT_FRAME, FLAG_OUTPUT_FRAME,
    FLAG_RESIDUAL_VALID, FLAG_SAME_REPLICATE, LayerSpec, layer_specs,
    OP_CONV1X1, OP_CONV3X3, OP_DWCONV3X3, OP_OUTPUT_RGB, OP_RESIDUAL_ADD, OP_UPSAMPLE2,
)

FRAME = '$frame'
SLOT_BYTES = 1 << 23


@dataclass(frozen=True)
class Node:
    spec: LayerSpec
    inputs: tuple[str, ...]


@dataclass(frozen=True)
class Step:
    index: int
    name: str
    inputs: tuple[str, ...]
    physical_inputs: tuple[str, ...]
    mode: int
    cin: int
    cout: int
    src_width: int
    src_height: int
    dst_width: int
    dst_height: int
    src_slot: int
    dst_slot: int
    skip_slot: int
    parameter_beats: int
    parameter_block: int
    input_rgb: bool
    output_rgb: bool
    virtual_up2: bool
    view: bool
    last: bool


def microstyle_nodes(width=640, height=480):
    """Network-specific edge adapter, separate from backend lowering.

    LayerSpec does not contain residual edges. The network's named residual
    block explicitly retains its expansion input for its add node.
    """
    nodes, residuals = [], {}
    previous = FRAME
    for spec in layer_specs(width, height):
        prefix, role = spec.name.rsplit('.', 1)
        if role == 'expand1x1':
            residuals[prefix] = previous
        inputs = (previous, residuals[prefix]) if spec.opcode == OP_RESIDUAL_ADD else (previous,)
        nodes.append(Node(spec, inputs))
        previous = spec.name
    return nodes


def require(value, message):
    if not value:
        raise ValueError(message)


def output_shape(spec):
    return spec.output_width, spec.output_height, spec.output_channels


def row_beats(width, channels):
    return ((width+1)//2)*((channels+7)//8)


def backend_mode(spec, physical_width, virtual):
    """Mirror the *documented backend capability*, not the graph schedule."""
    ci, co, op, k, stride = spec.input_channels, spec.output_channels, spec.opcode, spec.kernel, spec.stride
    if op == OP_CONV1X1:
        require((k, stride) == (1, 1) and ci in (16, 24, 48) and co in (8, 16, 24, 48), 'unsupported pointwise kernel')
        require(physical_width <= {16: 1024, 24: 512, 48: 340}[ci], 'pointwise input SRAM capacity')
        return 0
    if op == OP_CONV3X3:
        require(k == 3 and physical_width <= 1024, 'unsupported spatial kernel/capacity')
        if stride == 2 and (ci, co) == (3, 12):
            return 4
        if stride == 2 and (ci, co) == (12, 24):
            return 5
        require(stride == 1 and (ci, co) == (8, 3), 'unsupported stride/spatial channel mapping')
        return 1
    if op == OP_DWCONV3X3:
        require((k, stride) == (3, 1) and ci == co and ci in (16, 24, 48), 'unsupported depthwise mapping')
        limit = {16: 512 if virtual else 1024, 24: 512 if virtual else 682, 48: 340}[ci]
        require(physical_width <= limit, 'depthwise input SRAM capacity')
        return 2
    if op == OP_RESIDUAL_ADD:
        require((k, stride, ci, co, spec.activation) == (1, 1, 24, 24, ACT_RELU), 'backend residual requires 24 channels/ReLU')
        require(spec.output_width*24 <= 8192 and row_beats(spec.output_width, 24) <= 512, 'residual input SRAM capacity')
        return 3
    raise ValueError('unsupported executable opcode')


def lower(nodes, width=640, height=480, banks=3):
    """Preserve source tensors through their last materialized consumer.

    A destination never overwrites a current input, even at its last use:
    later rows of a spatial operation can still need earlier source rows.
    Alias views extend the physical root's lifetime, rather than allocating
    a fake output tensor or freeing the root at the view's own index.
    """
    require(4 <= width <= 640 and 4 <= height <= 480 and width % 4 == height % 4 == 0, 'unsupported frame geometry')
    require(1 <= len(nodes) <= 32 and 1 <= banks <= 3, 'instruction/bank capacity')
    specs, index, users = {}, {}, {FRAME: []}
    for i, node in enumerate(nodes):
        spec = node.spec
        require(isinstance(spec.name, str) and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.-]*', spec.name), 'invalid tensor name')
        require(spec.name != FRAME and spec.name not in specs, 'duplicate/reserved tensor name')
        require(spec.activation in (ACT_NONE, ACT_RELU), 'unsupported activation')
        require(not (spec.flags & ~(FLAG_INPUT_FRAME | FLAG_OUTPUT_FRAME | FLAG_RESIDUAL_VALID | FLAG_SAME_REPLICATE)), 'unsupported flags')
        require(all(isinstance(v, int) and v > 0 for v in (spec.input_width, spec.input_height, spec.output_width,
                spec.output_height, spec.input_channels, spec.output_channels, spec.kernel, spec.stride)), 'invalid shape')
        require(len(node.inputs) == (2 if spec.opcode == OP_RESIDUAL_ADD else 1), 'wrong tensor arity')
        for source in node.inputs:
            require(source == FRAME or source in specs, 'forward/missing tensor edge')
            shape = (width, height, 3) if source == FRAME else output_shape(specs[source])
            require(shape == (spec.input_width, spec.input_height, spec.input_channels), 'tensor edge shape mismatch')
            users.setdefault(source, []).append(spec.name)
        require(bool(spec.flags & FLAG_INPUT_FRAME) == (node.inputs[0] == FRAME), 'input frame flag mismatch')
        require(bool(spec.flags & FLAG_OUTPUT_FRAME) == (spec.opcode == OP_OUTPUT_RGB), 'output frame flag mismatch')
        require(bool(spec.flags & FLAG_RESIDUAL_VALID) == (spec.opcode == OP_RESIDUAL_ADD), 'residual flag mismatch')
        specs[spec.name], index[spec.name] = spec, i
        users.setdefault(spec.name, [])
    require(nodes[-1].spec.opcode == OP_OUTPUT_RGB and len(users[FRAME]) == 1, 'one RGB input/output required')
    require([n.spec.name for n in nodes if n.spec.opcode == OP_OUTPUT_RGB] == [nodes[-1].spec.name], 'RGB conversion must be terminal')
    reachable = {nodes[-1].spec.name}
    for node in reversed(nodes):
        if node.spec.name in reachable:
            reachable.update(node.inputs)
    require(len(reachable) == len(nodes)+1, 'dead/unreachable operation')

    roots, fused_rgb = {FRAME: FRAME}, set()
    for node in nodes:
        s, source = node.spec, node.inputs[0]
        if s.opcode == OP_UPSAMPLE2:
            require((s.kernel, s.stride, s.activation, s.weight_count) == (1, 2, ACT_NONE, 0) and
                    output_shape(s) == (s.input_width*2, s.input_height*2, s.input_channels), 'invalid nearest-2x view')
            require(len(users[s.name]) == 1 and specs[users[s.name][0]].opcode == OP_DWCONV3X3 and
                    source != FRAME and specs[source].opcode != OP_UPSAMPLE2, 'virtual upsample needs one DW consumer')
            roots[s.name] = roots[source]
        elif s.opcode == OP_OUTPUT_RGB:
            p = specs[source]
            require((s.kernel, s.stride, s.activation, s.weight_count) == (1, 1, ACT_NONE, 0) and
                    output_shape(s) == (width, height, 3), 'invalid RGB output conversion')
            require(p.opcode == OP_CONV3X3 and (p.input_channels, p.output_channels, p.stride) == (8, 3, 1) and
                    users[source] == [s.name], 'RGB fusion requires an exclusive 8-to-3 spatial producer')
            fused_rgb.add(source)
            roots[s.name] = roots[source]
        else:
            expected_shape = (s.input_width//s.stride, s.input_height//s.stride, s.output_channels)
            require(output_shape(s) == expected_shape, 'kernel output shape mismatch')
            if s.opcode in (OP_CONV3X3, OP_DWCONV3X3):
                require(s.flags & FLAG_SAME_REPLICATE, 'only SAME replicate padding is supported')
            weights = s.input_channels*s.kernel*s.kernel*(1 if s.opcode == OP_DWCONV3X3 else s.output_channels)
            require(s.weight_count == (0 if s.opcode == OP_RESIDUAL_ADD else weights), 'weight count mismatch')
            roots[s.name] = s.name

    last_use = {name: index.get(name, -1) for name in roots.values()}
    for i, node in enumerate(nodes):
        if node.spec.opcode not in (OP_UPSAMPLE2, OP_OUTPUT_RGB):
            for source in node.inputs:
                last_use[roots[source]] = max(last_use[roots[source]], i)
    assigned, live, steps = {}, {}, []
    for i, node in enumerate(nodes):
        s, source = node.spec, node.inputs[0]
        physical = tuple(roots[x] for x in node.inputs)
        root = physical[0]
        sw, sh, _ = (width, height, 3) if root == FRAME else output_shape(specs[root])
        view = s.opcode in (OP_UPSAMPLE2, OP_OUTPUT_RGB)
        virtual = source != FRAME and specs[source].opcode == OP_UPSAMPLE2
        for name in list(live):
            if last_use[name] < i:
                del live[name]
        src_slot = assigned.get(root, 0)
        skip_slot = assigned.get(physical[-1], 0) if len(physical) == 2 else 0
        if view:
            dst_slot, mode, beats = src_slot, 0, 0
        else:
            require(not virtual or s.opcode == OP_DWCONV3X3, 'virtual input not supported by this kernel')
            mode = backend_mode(s, sw, virtual)
            beats = 0 if mode == 3 else s.output_channels*(2*((s.kernel*s.kernel*(1 if mode == 2 else s.input_channels)+15)//16)+1)
            require(beats <= 512, 'parameter block exceeds 8KiB')
            require(row_beats(s.output_width, s.output_channels) <= 1024, 'writer row SRAM capacity')
            require(row_beats(s.output_width, s.output_channels)*s.output_height*16 <= SLOT_BYTES, 'tensor exceeds 8MiB slot')
            if s.name in fused_rgb:
                dst_slot = 0  # ignored; uses the external output region
            else:
                free = [b for b in range(banks) if b not in live.values()]
                require(free, 'insufficient workspace banks for live inputs/skip')
                dst_slot = free[0]
                live[s.name] = dst_slot
                assigned[s.name] = dst_slot
            if len(physical) == 2:
                require(root != physical[1], 'aliased residual operands not supported')
        steps.append(Step(i, s.name, node.inputs, physical, mode, s.input_channels, s.output_channels,
                          sw, sh, s.output_width, s.output_height, src_slot, dst_slot, skip_slot, beats, i,
                          root == FRAME and not view, s.name in fused_rgb, virtual and not view, view, i == len(nodes)-1))
    return steps


def dimension_shift(frame, value):
    for shift in range(3):
        if frame >> shift == value:
            return shift
    raise ValueError('RTL plan supports only full/half/quarter frame geometry')


def render_sv(steps, width=640, height=480, module='c1_r2_microstyle_plan'):
    """Generate a combinational decode table; registers remain in the engine."""
    require((width, height) == (640, 480), 'RTL ROM must be validated at the maximum supported frame geometry')
    require(1 <= len(steps) <= 32 and [s.index for s in steps] == list(range(len(steps))) and
            [s.index for s in steps if s.last] == [len(steps)-1], 'invalid instruction sequence')
    require([(s.src_width, s.src_height) for s in steps if s.input_rgb] == [(width, height)] and
            [(s.dst_width, s.dst_height) for s in steps if s.output_rgb] == [(width, height)], 'plan profile does not match RTL frame envelope')
    require(module.replace('_', '').isalnum() and not module[0].isdigit(), 'invalid Verilog module name')
    header = f'''`timescale 1ns/1ps
// Generated by model/r2_execution_plan.py from explicit operator/tensor edges.
// Compile-time plan, not writable microcode. Regenerate and revalidate after
// graph changes; backend capability checks intentionally reject unsupported CNNs.
module {module} (
    input wire [4:0] index,
    input wire [10:0] frame_width,
    input wire [9:0] frame_height,
    output logic valid,last,input_rgb,output_rgb,virtual_up2,view,
    output logic [2:0] mode,
    output logic [5:0] cin,cout,
    output logic [10:0] src_width,dst_width,
    output logic [9:0] src_height,dst_height,
    output logic [1:0] src_slot,dst_slot,skip_slot,
    output logic [15:0] parameter_beats,
    output logic [4:0] parameter_block
);
    always_comb begin
        valid=0;last=0;input_rgb=0;output_rgb=0;virtual_up2=0;view=1;
        mode=0;cin=0;cout=0;src_width=0;dst_width=0;src_height=0;dst_height=0;
        src_slot=0;dst_slot=0;skip_slot=0;parameter_beats=0;parameter_block=0;
        case(index)
'''
    lines = [header]
    for s in steps:
        require(dimension_shift(width, s.src_width) == dimension_shift(height, s.src_height) and
                dimension_shift(width, s.dst_width) == dimension_shift(height, s.dst_height), 'anisotropic shape is unsupported')
        a, b = dimension_shift(width, s.src_width), dimension_shift(width, s.dst_width)
        lines += [f"            5'd{s.index}:begin // {s.name}",
                  f'                valid=1;last={int(s.last)};input_rgb={int(s.input_rgb)};output_rgb={int(s.output_rgb)};virtual_up2={int(s.virtual_up2)};view={int(s.view)};',
                  f"                mode=3'd{s.mode};cin=6'd{s.cin};cout=6'd{s.cout};",
                  f'                src_width=frame_width>>{a};src_height=frame_height>>{a};dst_width=frame_width>>{b};dst_height=frame_height>>{b};',
                  f"                src_slot=2'd{s.src_slot};dst_slot=2'd{s.dst_slot};skip_slot=2'd{s.skip_slot};parameter_beats=16'd{s.parameter_beats};parameter_block=5'd{s.parameter_block};",
                  '            end']
    lines += ['            default:begin end', '        endcase', '    end', 'endmodule', '']
    return '\n'.join(lines)


def microstyle_plan(width=640, height=480):
    return lower(microstyle_nodes(width, height), width, height)
