"""Synthetic parser tests only; this does not run or certify the RTL."""
from run_c39_requant_probe import ROOT, compiled_sources


def main():
    paths = [(ROOT / path).resolve().as_posix() for path in (
        'rtl/cnn/c1_requant_bank8_compact.sv', 'rtl/c39/c39_requant_bank8_narrow.sv',
        'tb/tb_c39_requant_narrow.sv')]
    good = ':file_names 4;\n' + ''.join('    "' + p + '";\n' for p in ['N/A'] + paths)
    if compiled_sources(good, paths) != 4:
        raise AssertionError('valid source table rejected')
    rejected = 0
    for bad in (good.replace(':file_names 4;', ':file_names 5;'), good + good,
                good.replace(paths[1], paths[0]), good.replace(paths[1], paths[1] + '.wrong.sv'),
                good.rsplit('    "', 1)[0]):
        try:
            compiled_sources(bad, paths)
        except ValueError:
            rejected += 1
        else:
            raise AssertionError('malformed compiler evidence accepted')
    print(f'C39_REQUANT_SOURCE_TABLE_SELFTEST_PASS synthetic_positive=1 rejected={rejected} RTL_simulated=0')


if __name__ == '__main__':
    main()
