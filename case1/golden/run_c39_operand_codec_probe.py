"""Short independent compression test plus three actual RTL corruption controls."""
import tempfile
from pathlib import Path
from run_c37_leaf_probe import budget, compile_test, execute, ROOT


def main():
    budget()
    source = (ROOT / 'rtl/c39/c39_operand_codec.sv').read_text(encoding='utf-8-sig')
    cases = [('positive', source)]
    for name, old, new in (
        ('pw_wrap', 'channels[lane*6+:6]<channels[0+:6]', 'channels[lane*6+:6]>channels[0+:6]'),
        ('rgb_boundary', '(lane>=3)', '(lane>=4)'),
        ('dw_top_byte', "{56'd0,packed_a[lane*72+:72]}", "{64'd0,packed_a[lane*72+:64]}"),
    ):
        if source.count(old) != 1:
            raise ValueError('missing mutation anchor ' + name)
        cases.append((name, source.replace(old, new)))
    with tempfile.TemporaryDirectory(prefix='c39_codec_', dir=ROOT / 'sim') as private:
        folder = Path(private)
        for name, candidate in cases:
            test_source = folder / (name + '.sv')
            test_source.write_text(candidate, encoding='utf-8')
            exe = compile_test(folder, 'tb_c39_operand_codec',
                               [test_source, ROOT / 'tb/tb_c39_operand_codec.sv'])
            code, output = execute(['D:/iverilog/bin/vvp.exe', exe], folder, timeout=30)
            if name == 'positive':
                if code or output.count('C39_OPERAND_CODEC_PASS ') != 1:
                    raise RuntimeError(output[-2000:])
                print(output.strip(), flush=True)
            else:
                if not code or 'C39 codec roundtrip mismatch' not in output or 'C39_OPERAND_CODEC_PASS' in output:
                    raise RuntimeError('corruption was not correctly detected: ' + name + '\n' + output[-2000:])
                print('C39_OPERAND_CODEC_ACTUAL_NEGATIVE_PASS mutation=' + name, flush=True)
    print('C39_OPERAND_CODEC_CLEAN private_removed=1 waves=0', flush=True)


if __name__ == '__main__':
    main()
