"""Synthetic metadata tests only; no HDL compilation or simulation."""
from pathlib import Path
from run_c39_onehot_datapath_probe import window_metadata


def main():
    root = Path(__file__).resolve().parents[1]
    paths = [root / 'rtl/c39/c1_r2_partitioned_window_store.sv',
             root / 'sim/tb_c37_window_capacity.sv']
    table = ':file_names 3;\n' + ''.join(
        '    "' + name + '";\n' for name in ['N/A'] + [p.as_posix() for p in paths])
    rejected = 0
    for rows in (512, 1024):
        head = f'P_test .param/l "ROW_WORDS" 0 3 12, +C4<{rows:032b}>;\n'
        options = [f'-Ptb_c37_window_capacity.ROW_WORDS={rows}']
        assert window_metadata(head, table, paths, options)['row_words'] == rows
        bad_cases = (
            ('', table, options),
            (head.replace(f'{rows:032b}', f'{rows // 2:032b}'), table, options),
            (head, table.replace(':file_names 3;', ':file_names 4;'), options),
            (head, table.replace(paths[0].as_posix(), paths[1].as_posix()), options),
            (head, table + table, options),
            (head, table, options + options),
        )
        for bad_head, bad_table, bad_options in bad_cases:
            try:
                window_metadata(bad_head, bad_table, paths, bad_options)
            except ValueError:
                rejected += 1
            else:
                raise AssertionError('bad window metadata accepted')
    print(f'C39_WINDOW_METADATA_SELFTEST_PASS synthetic_positive=2 rejected={rejected} RTL_simulated=0')


if __name__ == '__main__':
    main()
