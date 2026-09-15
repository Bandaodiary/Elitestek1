"""C21: convert retained scalar-reference C5 jobs to actual C7 bulk loads."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import random
import subprocess
import tempfile

from run_r2_operator_probe import vectors as old_vectors
from run_r2_cnn_tile_probe import feature_address
from run_r2_cnn_row_probe import spatial_address
from run_r2_compact_host_probe import ROOT, SOURCES


def vectors(folder):
    old = folder/'reference'
    old.mkdir()
    meta = old_vectors(old)
    raw = [int(s, 16) for s in (old/'input.mem').read_text().splitlines()]
    records, cursor, bulk_count, boundary = [], 0, 0, 0
    for job_id, job in enumerate(meta['jobs']):
        cs = raw[cursor:cursor+job['loads']+1]
        cursor += len(cs)
        mode, size, ci = job['mode'], job['size'], job['channels']
        feature = {}
        for cmd in cs[:-1]:
            kind, address, value = cmd>>49, (cmd>>32)&0x3fff, cmd&0xffffffff
            if kind == 0:
                feature[address] = value
            else:
                records.append((kind<<164)|(mode<<161)|(address<<128)|value)
        groups = 3 if mode == 3 else 1 if mode in (1, 4) else 2 if mode == 5 else ci//8
        pixels = (size+23)//24 if mode == 3 else size
        chunks = (ci+15)//16
        narrow_records = (size+7)//8

        def word(row, x, group, word_id, b=0):
            if mode == 0:
                if x >= size:
                    return 0x77777777
                channel = group*8+word_id*4
                address = feature_address(x, channel//16, chunks, (channel%16)//4)
            elif mode == 3:
                record = x*3+group
                if record >= narrow_records:
                    return 0x77777777
                address = feature_address(record, 0, 1, b*2+word_id)
            else:
                if x >= size:
                    return 0x77777777
                address = spatial_address(row, x, group, groups, word_id)
            if address not in feature:
                raise ValueError(f'missing actual feature word {job_id} {mode} {address}')
            return feature[address]

        bulk = []
        for row in range(1 if mode in (0, 3) else 3):
            for pair in range((pixels+1)//2):
                for group in range(groups):
                    if mode == 3 and pair*6+group >= narrow_records:
                        continue
                    for b in range(2 if mode == 3 else 1):
                        data = sum(word(row, pair*2+p, group, w, b) << ((p*2+w)*32)
                                   for p in range(2) for w in range(2))
                        bulk.append((5<<164)|(mode<<161)|(b<<146)|(row<<144)|
                                    (groups<<141)|(group<<138)|(pair<<128)|data)
        random.Random(21003+job_id).shuffle(bulk)
        records.extend(bulk)
        bulk_count += len(bulk)
        records.append((4<<164)|(mode<<161)|(cs[-1]&0xffffffff))
        if mode == 3 and size > 8160:
            boundary += 1
    assert cursor == len(raw)
    (folder/'bulk.mem').write_text(''.join(f'{v:042x}\n' for v in records), encoding='ascii')
    return dict(commands=len(records), bulk=bulk_count, jobs=len(meta['jobs']), vectors=meta['vectors'],
                scalars=meta['scalars'], trained_scalars=meta['trained_scalars'], residual_capacity_jobs=boundary,
                pw_shapes=sorted({(j['channels'], j['outputs']) for j in meta['jobs'] if j['mode'] == 0}),
                mode_jobs={str(mode): sum(j['mode'] == mode for j in meta['jobs']) for mode in range(6)})


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--stalls', default='0,1')
    p.add_argument('--boundary-only', action='store_true')
    a = p.parse_args()
    if not set(a.stalls.split(',')) <= {'0', '1'}:
        p.error('stalls must be 0 or 1')
    with tempfile.TemporaryDirectory(prefix='c1_r2_compact_operator_', dir=ROOT/'sim') as td:
        folder = Path(td)
        m = dict(commands=0, vectors=0, jobs=0) if a.boundary_only else vectors(folder)
        print('C1_R2_COMPACT_OPERATOR_VECTORS '+json.dumps(m, separators=(',', ':')), flush=True)
        top = 'tb_c1_r2_cnn_compact_engine'
        for stalls in map(int, a.stalls.split(',')):
            exe = folder/f'operator{stalls}.vvp'
            c = subprocess.run(['D:/iverilog/bin/iverilog.exe', '-g2012', '-s', top, f'-P{top}.STALLS={stalls}',
                                f'-P{top}.BOUNDARY_ONLY={int(a.boundary_only)}',
                                '-o', str(exe), *[str(ROOT/s) for s in SOURCES], str(ROOT/f'sim/{top}.sv')],
                               capture_output=True, text=True, timeout=90)
            if c.returncode:
                raise RuntimeError(c.stderr[-3500:])
            r = subprocess.run(['D:/iverilog/bin/vvp.exe', str(exe), f'+INPUTS={folder.as_posix()}/bulk.mem',
                                f'+OUTPUTS={folder.as_posix()}/reference/output.mem', f'+N={m["commands"]}',
                                f'+M={m["vectors"]}', f'+J={m["jobs"]}'],
                               capture_output=True, text=True, timeout=600)
            for line in r.stdout.splitlines():
                if line.startswith('C1_R2_COMPACT_OPERATOR_'):
                    print(line, flush=True)
            marker = 'C1_R2_COMPACT_OPERATOR_BOUNDARY_PASS ' if a.boundary_only else 'C1_R2_COMPACT_OPERATOR_PASS '
            if r.returncode or r.stdout.count(marker) != 1 or 'FATAL' in r.stdout:
                raise RuntimeError((r.stdout+r.stderr)[-3500:])
    print('C1_R2_COMPACT_OPERATOR_CLEAN temporary_vectors_and_simulator_removed=1', flush=True)


if __name__ == '__main__':
    main()
