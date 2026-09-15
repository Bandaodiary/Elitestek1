"""Short real window equivalence tests. Refuses overlap with active EDA jobs."""
from pathlib import Path
import tempfile
from c39_window_factor_sources import ROOT, NEW, verify
from run_c37_leaf_probe import budget, compile_test, run_test
from c39_seam_admission import check as admission


def main():
    verify()
    budget()
    admission()
    top = 'tb_c37_window_capacity'
    names = ['rtl/common/c1_ram_sdp_read_first.sv', 'rtl/r2/c1_r2_feature_overlay_ram.sv',
             'rtl/r2/c1_r2_overlay_window_store.sv', 'rtl/r2/c1_r2_partitioned_feature_ram.sv',
             NEW, 'sim/' + top + '.sv']
    with tempfile.TemporaryDirectory(prefix='c39_window_factor_', dir=ROOT / 'sim') as private:
        folder = Path(private)
        for depth in (512, 1024):
            print('C39_WINDOW_FACTOR_CASE row_words=' + str(depth), flush=True)
            exe = compile_test(folder, top, [ROOT / name for name in names],
                               [f'-P{top}.ROW_WORDS={depth}'])
            run_test(folder, exe, [], 'C37_WINDOW_CAPACITY_PASS ')
        original = (ROOT / NEW).read_text(encoding='utf-8-sig')
        for name, old, new in (
            ('parity_reverse', 'pending_parity[col] ?', '!pending_parity[col] ?'),
            ('row2_omitted', '({64{row_id==2}}', '({64{row_id==3}}'),
        ):
            if original.count(old) != 1:
                raise ValueError('window mutation anchor changed: ' + name)
            candidate = folder / (name + '.sv')
            candidate.write_text(original.replace(old, new), encoding='utf-8')  # generated fault fixture
            mutated = [candidate if relative == NEW else ROOT / relative for relative in names]
            exe = compile_test(folder, top, mutated, [f'-P{top}.ROW_WORDS=512'])
            run_test(folder, exe, [], 'C37_WINDOW_CAPACITY_PASS ', 'C37 window cycle-equivalence mismatch')
    print('C39_WINDOW_FACTOR_PROBE_PASS private_removed=1 whole_host_verified=0 resource_gain_measured=0', flush=True)


if __name__ == '__main__':
    main()
