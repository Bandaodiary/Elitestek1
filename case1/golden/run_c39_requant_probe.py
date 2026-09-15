"""Short serial Icarus test; candidates and waveform-free artifacts are private."""
from pathlib import Path
import json
import re
import tempfile
from run_c37_leaf_probe import budget, compile_test, execute
from c39_seam_admission import check as admission

ROOT = Path(__file__).resolve().parents[1]


def compiled_sources(tail, expected):
    tables = list(re.finditer(r'^:file_names (\d+);\s*$', tail, re.M))
    if len(tables) != 1:
        raise ValueError('actual requant compiler source table missing/ambiguous')
    table = tables[0]
    actual = re.findall(r'^\s*"([^"]+)";\s*$', tail[table.end():], re.M)
    if len(actual) != int(table[1]):
        raise ValueError('actual requant source table incomplete')
    paths = [Path(p.replace('\\\\', '\\')).resolve().as_posix() for p in actual if p.endswith('.sv')]
    if sorted(paths) != sorted(expected):
        raise ValueError('requant snapshot compiled different/duplicate RTL sources')
    return len(actual)


def main():
    budget()
    admission()
    top = 'tb_c39_requant_narrow'
    original = ROOT / 'rtl/cnn/c1_requant_bank8_compact.sv'
    candidate = ROOT / 'rtl/c39/c39_requant_bank8_narrow.sv'
    bench = ROOT / 'tb/tb_c39_requant_narrow.sv'
    mutations = {
        'drop_guard': ('+{8\'d0,quotient_q[8]}', "+9'd0"),
        'drop_carry': ('quotient_q[9] | low_sum[8]', 'quotient_q[9]'),
        'break_elastic_hold': ('!valid_q[4] || out_ready', "1'b1"),
    }
    with tempfile.TemporaryDirectory(prefix='c39_requant_', dir=ROOT / 'sim') as private:
        folder = Path(private)
        source = candidate.read_text(encoding='utf-8')
        for label in ('positive', *mutations):
            selected = candidate
            if label != 'positive':
                old, new = mutations[label]
                assert source.count(old) == 1, (label, 'mutation anchor')
                selected = folder / (label + '.sv')
                selected.write_text(source.replace(old, new), encoding='utf-8')
            exe = compile_test(folder, top, [original, selected, bench])
            # Bounded actual compiler source table, not just requested filenames.
            with exe.open('rb') as stream:
                stream.seek(max(0, exe.stat().st_size - 16384))
                compiled_tail = stream.read(16384).decode('utf-8', errors='strict')
            expected = [p.resolve().as_posix() for p in (original, selected, bench)]
            entries = compiled_sources(compiled_tail, expected)
            print('C39_REQUANT_COMPILED_SOURCES ' + json.dumps(dict(case=label,
                snapshot=exe.name, source_files=expected, actual_source_entries=entries), separators=(',', ':')), flush=True)
            code, output = execute(['D:/iverilog/bin/vvp.exe', exe], folder, timeout=90)
            if label == 'positive':
                if code or 'C39_REQUANT_RTL_PASS' not in output:
                    raise RuntimeError(output[-3500:])
                print(output.strip(), flush=True)
            else:
                expected = 'C39 requant handshake mismatch' if label == 'break_elastic_hold' else 'C39 requant value mismatch'
                if code == 0 or expected not in output or 'C39_REQUANT_RTL_PASS' in output:
                    raise RuntimeError(f'{label}: wrong negative result: {output[-3500:]}')
                print('C39_ACTUAL_RTL_NEGATIVE_PASS ' + label, flush=True)
    print('C39_REQUANT_CLEAN temporary_removed=1 waves=0 production_baseline_modified=0', flush=True)


if __name__ == '__main__':
    main()
