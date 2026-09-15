"""Emit simulator-friendly views of the trained MicroStyle artifact.

This generator deliberately uses only the Python standard library so it can
run in the Vivado/Windows environment without numpy or torch.
"""
from pathlib import Path
import argparse, json

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--artifact', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((a.artifact/'manifest.json').read_text(encoding='utf-8'))
    desc = (a.artifact/'descriptors.bin').read_bytes()
    param = (a.artifact/'parameter_arena.bin').read_bytes()
    n = manifest['descriptor_count']
    assert len(desc) == n*64 and len(param) == manifest['parameter_arena_bytes']
    (a.out/'descriptors.mem').write_text('\n'.join(desc[i*64:(i+1)*64][::-1].hex() for i in range(n))+'\n')
    (a.out/'parameter_arena.mem').write_text('\n'.join(param[i:i+16][::-1].hex() for i in range(0,len(param),16))+'\n')
    payload_bytes = 0
    read_words = 0
    for i in range(n):
        word = int.from_bytes(desc[i*64:(i+1)*64], 'little')
        opcode = word & 0xff
        cin = (word >> 96) & 0xffff
        cout = (word >> 112) & 0xffff
        regions = []
        if opcode == 1:
            regions = [cin * cout * 9, cout * 4, cout * 4, cout]
        elif opcode == 2:
            regions = [cin * cout, cout * 4, cout * 4, cout]
        elif opcode == 3:
            regions = [cin * 9, cout * 4, cout * 4, cout]
        payload_bytes += sum(regions)
        read_words += sum((size + 15) // 16 for size in regions)
    summary = {'artifact': str(a.artifact), 'trained': manifest.get('trained', False),
               'descriptor_count': n, 'parameter_bytes': len(param),
               'parameter_payload_bytes': payload_bytes, 'parameter_read_words': read_words,
               'native_frame': [manifest['width'], manifest['height']],
               'small_size_status': 'NOT_SUPPORTED_BY_NATIVE_DESCRIPTOR_CONTINUITY',
               'evidence_boundary': '22-stage descriptor/parameter-scheduler ABI only; arithmetic frame remains native 640x480'}
    (a.out/'artifact_vector_manifest.json').write_text(json.dumps(summary, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(summary))
if __name__ == '__main__': main()
