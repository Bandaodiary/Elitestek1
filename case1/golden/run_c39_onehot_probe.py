"""Real isolated RTL equivalence, existing legal-vector test and fault controls."""
import tempfile
from pathlib import Path
from run_c37_leaf_probe import budget, compile_test, execute, ROOT
from c39_onehot_sources import verify
from c39_seam_admission import check as admission


def main():
    verify()
    budget()
    admission()
    source = (ROOT / 'rtl/c39_onehot/c39_operand_codec.sv').read_text(encoding='utf-8-sig')
    reference = (ROOT / 'rtl/c39/c39_operand_codec.sv').read_text(encoding='utf-8-sig')
    reference = reference.replace('module c39_operand_unpack (', 'module c39_operand_unpack_reference (')
    reference = reference.replace('module c39_operand_pack (', 'module c39_operand_pack_reference (')
    cases = [('positive', source)]
    for name, old, new in (
        ('pw_wrap', 'channels[lane*6+:6]<channels[0+:6]', 'channels[lane*6+:6]>channels[0+:6]'),
        ('rgb_boundary', '(lane>=3)', '(lane>=4)'),
        ('dw_top_byte', "{56'd0,packed_a[lane*72+:72]}", "{64'd0,packed_a[lane*72+:64]}"),
    ):
        if source.count(old) != 1:
            raise ValueError('mutation anchor changed: ' + name)
        cases.append((name, source.replace(old, new)))
    with tempfile.TemporaryDirectory(prefix='c39_onehot_', dir=ROOT / 'sim') as private:
        folder = Path(private)
        ref_file = folder / 'reference.sv'
        ref_file.write_text(reference, encoding='utf-8')  # generated simulation fixture
        for name, text in cases:
            candidate = folder / (name + '.sv')
            candidate.write_text(text, encoding='utf-8')  # isolated actual RTL mutation
            exe = compile_test(folder, 'tb_c39_unpack_miter',
                               [candidate, ref_file, ROOT / 'tb/tb_c39_unpack_miter.sv'])
            code, output = execute(['D:/iverilog/bin/vvp.exe', exe], folder, timeout=30)
            if name == 'positive':
                if code or 'C39_UNPACK_MITER_PASS checks=11016 modes=8 output_bits=768' not in output:
                    raise RuntimeError(output[-2000:])
                print(output.strip(), flush=True)
                exe = compile_test(folder, 'tb_c39_operand_codec', [candidate, ROOT / 'tb/tb_c39_operand_codec.sv'])
                code, output = execute(['D:/iverilog/bin/vvp.exe', exe], folder, timeout=30)
                if code or 'C39_OPERAND_CODEC_PASS checks=5632' not in output:
                    raise RuntimeError(output[-2000:])
                print(output.strip(), flush=True)
            elif not code or 'C39 unpack miter mismatch' not in output or 'C39_UNPACK_MITER_PASS' in output:
                raise RuntimeError('actual mutation not detected: ' + name)
            else:
                print('C39_ONEHOT_ACTUAL_NEGATIVE_PASS mutation=' + name, flush=True)
    print('C39_ONEHOT_PROBE_PASS private_removed=1 waves=0 full_host_verified=0', flush=True)


if __name__ == '__main__':
    main()
