"""R2-C3: two real SRAM pools, one compute6, four operator types.

Independent OIHW DW reference and same-scale residual reference, plus the
retained PW/RGB golden suites. Test-only vectors/executables are disposable.
Spatial loads are ordinary C8 HWC groups, never pre-expanded MAC operands.
"""
from __future__ import annotations
import json, random, subprocess, tempfile
from pathlib import Path
import numpy as np
from run_r2_array_probe import ROOT, packed, wrap
from run_r2_pw_tile_probe import vectors as pw_vectors, affine_scalar
from run_r2_rgb_row_probe import vectors as rgb_vectors
from generate_microstyle_engine_bitexact_vectors import _image, _stage_sources, STAGE_NAMES, integer_infer_rgb
from microstyle_quant import _read_layer_arrays

SOURCES = ['rtl/common/c1_ram_sdp_read_first.sv', 'rtl/cnn/c1_requant_bank8.sv',
           'rtl/r2/c1_r2_dot16_array.sv', 'rtl/r2/c1_r2_compute6.sv',
           'rtl/r2/c1_r2_group_window_store.sv', 'rtl/r2/c1_r2_spatial_feeder.sv',
           'rtl/r2/c1_r2_pw_linear_feeder.sv', 'rtl/r2/c1_r2_cnn_row_engine.sv']


def command(mode, kind, address, value):
    assert 0 <= address < 16384
    return (kind << 48) | (mode << 46) | (address << 32) | (int(value) & 0xffffffff)


def spatial_address(row, x, group, groups, word):
    assert (x // 2) * groups + group < 1024, 'parity bank capacity exceeded'
    return (row << 12) | ((x & 1) << 11) | (((x // 2) * groups + group) << 1) | word


def vectors(directory):
    queues = [[], [], [], []]
    for mode, build in enumerate((pw_vectors, rgb_vectors)):
        part = directory / ('pw' if mode == 0 else 'rgb'); part.mkdir()
        meta = build(part)
        commands = [int(s, 16) for s in (part / 'input.mem').read_text().splitlines()]
        expected = [int(s, 16) for s in (part / 'output.mem').read_text().splitlines()]
        ci = oi = 0
        for job in meta['jobs']:
            translated = []
            size = job.get('pixels', job.get('width'))
            for cmd in commands[ci:ci + job['loads'] + 1]:
                kind = cmd >> (44 if mode == 0 else 45)
                addr = (cmd >> 32) & (0xfff if mode == 0 else 0x1fff)
                value = cmd & 0xffffffff
                if mode == 1 and kind == 0:
                    pixel, word = divmod(addr, 2); row, x = divmod(pixel, 1024)
                    addr = spatial_address(row, x, 0, 1, word)
                if kind == 4:
                    value = size | ((16 if mode == 0 else 8) << 14)
                    if mode == 1: value |= (int(job['top']) << 20) | (int(job['bottom']) << 21)
                translated.append(command(mode, kind, addr, value))
            queues[mode].append((translated, [(mode << 70) | v for v in expected[oi:oi + job['vectors']]],
                                 dict(mode=mode, size=size, channels=16 if mode == 0 else 8,
                                      vectors=job['vectors'], scalars=job['scalars'], loads=job['loads'],
                                      label=job['label'], trained=job['label'].startswith('qat_'))))
            ci += job['loads'] + 1; oi += job['vectors']
        assert ci == len(commands) and oi == len(expected)

    def dw_job(label, source, weight, bias, mult, shift, relu, top, bottom, target=None):
        _, width, channels = source.shape; groups = channels // 8
        assert channels in (16, 24, 48) and weight.shape == (channels, 1, 3, 3)
        loads = [(0, spatial_address(r, x, g, groups, w), packed(source[r, x, g*8+w*4:g*8+w*4+4], 8))
                 for r in range(3) for x in range(width) for g in range(groups) for w in range(2)]
        for c in range(channels):
            coefficients = list(weight[c, 0].reshape(-1)) + [113, -117, 99]
            loads += [(1, c*3+w, packed(coefficients[w*4:w*4+4], 8)) for w in range(3)]
            loads += [(2, c, bias[c]), (3, c, (int(relu[c]) << 24) | (int(shift[c]) << 18) | (int(mult[c]) & 0x3ffff))]
        random.Random(301 + len(queues[2])).shuffle(loads)
        values = np.empty((width, channels), dtype=np.int16)
        # Reference is scalar OIHW convolution, with no C8 batching or K padding.
        for x in range(width):
            for c in range(channels):
                acc = int(bias[c])
                for ky in range(3):
                    row = 1 if (ky == 0 and top) or (ky == 2 and bottom) else ky
                    for kx in range(3):
                        sx = min(width-1, max(0, x+kx-1))
                        acc += int(source[row, sx, c]) * int(weight[c, 0, ky, kx])
                values[x, c] = affine_scalar(wrap(acc), int(mult[c]), int(shift[c]), bool(relu[c]))
        if target is not None: np.testing.assert_array_equal(values, target, err_msg=label)
        expected = []
        for x in range(0, width, 2):
            for g in range(groups):
                for batch in range(3):
                    chunk = []; mask = 0
                    for lane in range(6):
                        local = batch*6 + lane; pixel = x + local//8; channel = g*8 + local%8
                        valid = local < 16 and pixel < width
                        chunk.append(int(values[pixel, channel]) if valid else 0)
                        if valid: mask |= 1 << lane
                    tag = (x << 5) | (g << 2) | batch
                    expected.append((2 << 70) | (tag << 54) | (mask << 48) | packed(chunk, 8))
        commands = [command(2, *load) for load in loads]
        commands.append(command(2, 4, 0, width | (channels << 14) | (int(top) << 20) | (int(bottom) << 21)))
        queues[2].append((commands, expected, dict(mode=2, size=width, channels=channels, vectors=len(expected),
                          scalars=width*channels, loads=len(loads), label=label, trained=target is not None)))

    def residual_job(label, aa, bb, target=None):
        aa = np.asarray(aa).reshape(-1); bb = np.asarray(bb).reshape(-1); size = len(aa)
        assert aa.shape == bb.shape and 0 < size <= 8192
        values = np.maximum(0, np.clip(aa.astype(np.int16)+bb.astype(np.int16), -128, 127))
        if target is not None: np.testing.assert_array_equal(values, target.reshape(-1), err_msg=label)
        # Pad with poison, not zeros: the scalar tail mask must suppress it.
        records = np.full(((size+7)//8, 16), -119, dtype=np.int16)
        for i in range(size): records[i//8, i%8] = aa[i]; records[i//8, 8+i%8] = bb[i]
        loads = [(0, r*4+w, packed(records[r, w*4:w*4+4], 8)) for r in range(len(records)) for w in range(4)]
        random.Random(403 + len(queues[3])).shuffle(loads)
        commands = [command(3, *load) for load in loads] + [command(3, 4, 0, size)]
        expected = []
        for base in range(0, size, 6):
            chunk = values[base:base+6]
            expected.append((3 << 70) | (base << 54) | (((1 << len(chunk))-1) << 48) | packed(chunk, 8))
        queues[3].append((commands, expected, dict(mode=3, size=size, channels=0, vectors=len(expected),
                          scalars=size, loads=len(loads), label=label, trained=target is not None)))

    artifact = ROOT / 'model/microstyle24_starry_functional'
    manifest = json.loads((artifact/'manifest.json').read_text()); assert manifest['trained'] is True
    arena = (artifact/manifest['parameter_file']).read_bytes()
    lookup = {r['name']: r for r in manifest['quantized_layers']}
    image = _image(640, 4); _, layers = integer_infer_rgb(image, artifact, collect=True)
    for stage in (3, 7, 11, 15, 18):
        row = lookup[STAGE_NAMES[stage]]; weight, bias, mult, shift = _read_layer_arrays(arena, row)
        source, _ = _stage_sources(image, layers, stage)
        for y in range(len(source)):
            stripe = np.stack([source[max(0, y-1)], source[y], source[min(len(source)-1, y+1)]])
            if y == 0: stripe[0] = 113
            if y == len(source)-1: stripe[2] = -109
            dw_job(f'qat_stage{stage}_row{y}', stripe, weight, bias, mult, shift, [row['activation']]*len(bias),
                   y == 0, y == len(source)-1, layers[row['name']][y])
    for stage in (5, 9, 13):
        source, skip = _stage_sources(image, layers, stage)
        residual_job(f'qat_stage{stage}', source, skip, layers[STAGE_NAMES[stage]])
    rng = np.random.default_rng(20260913)
    for channels, widths in ((16, (1, 2, 3, 639, 1024)), (24, (1, 3, 31, 681, 682)), (48, (1, 3, 31, 339, 340))):
        for trial, width in enumerate(widths):
            source = rng.integers(-128, 128, (3, width, channels), dtype=np.int16)
            weight = rng.integers(-128, 128, (channels, 1, 3, 3), dtype=np.int16)
            bias = [[-2**31, 2**31-1, -1, 1, 777, -777][c%6] for c in range(channels)]
            mult = [[-131072, 131071, -3, 0, 1, 65537][c%6] for c in range(channels)]
            shift = [[0, 1, 2, 15, 31, 46, 47][(c+trial)%7] for c in range(channels)]
            dw_job(f'random_c{channels}_w{width}', source, weight, bias, mult, shift,
                   [(c+trial)%2 for c in range(channels)], bool(trial&1), bool(trial&2))
    dw_job('ties_away', np.zeros((3, 3, 16), dtype=np.int16), np.zeros((16, 1, 3, 3), dtype=np.int16),
           [1, -1, 3, -3, 255, -257, 7, -7]*2, [1]*16, [1]*16, [0]*8+[1]*8, True, True)
    for size in (1, 2, 5, 6, 7, 8, 9, 31, 8191, 8192):
        residual_job(f'random_n{size}', rng.integers(-128, 128, size, dtype=np.int16), rng.integers(-128, 128, size, dtype=np.int16))
    residual_job('saturation', [127, -128, 127, -128, -1, 1, 63, 64], [127, -128, -128, 127, 1, -1, 64, 64])
    ordered = [queue[j] for j in range(max(map(len, queues))) for queue in queues if j < len(queue)]
    commands = [c for cs, _, _ in ordered for c in cs]; expected = [v for _, vs, _ in ordered for v in vs]
    (directory/'input.mem').write_text(''.join(f'{v:013x}\n' for v in commands), encoding='ascii')
    (directory/'output.mem').write_text(''.join(f'{v:018x}\n' for v in expected), encoding='ascii')
    return dict(commands=len(commands), vectors=len(expected), jobs=[j for _, _, j in ordered],
                trained_scalars=sum(j['scalars'] for _, _, j in ordered if j['trained']),
                scalars=sum(j['scalars'] for _, _, j in ordered))


def main():
    with tempfile.TemporaryDirectory(prefix='c1_r2_cnn_', dir=ROOT/'sim') as temporary:
        directory = Path(temporary); meta = vectors(directory)
        print('C1_R2_CNN_VECTORS '+json.dumps(meta), flush=True)
        top = 'tb_c1_r2_cnn_row_engine'
        for stalls in (0, 1):
            executable = directory/f'cnn_{stalls}.vvp'
            commands = [['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', top, f'-P{top}.STALLS={stalls}',
                         '-o', str(executable), *[str(ROOT/s) for s in SOURCES], str(ROOT/f'sim/{top}.sv')],
                        ['D:/iverilog/bin/vvp.exe', str(executable), f'+INPUTS={directory.as_posix()}/input.mem',
                         f'+OUTPUTS={directory.as_posix()}/output.mem', f'+N={meta["commands"]}',
                         f'+M={meta["vectors"]}', f'+J={len(meta["jobs"])}']]
            for cmd in commands:
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=240)
                if result.returncode: raise RuntimeError('\n'.join((result.stdout+result.stderr).splitlines()[-25:]))
            lines = result.stdout.splitlines()
            if sum(s.startswith('C1_R2_CNN_PASS ') for s in lines) != 1 or any('ERROR' in s or 'FATAL' in s for s in lines):
                raise RuntimeError(result.stdout[-4000:])
            for line in lines:
                if line.startswith('C1_R2_CNN_'): print(line, flush=True)
    print('C1_R2_CNN_CLEAN temporary_vectors_and_simulator_removed=1', flush=True)


if __name__ == '__main__': main()
