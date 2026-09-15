"""Actual public platform audit plus in-memory rejection tests; no CPU execution."""
import json
from pathlib import Path
from unittest.mock import patch
from c39_sapphire_platform_contract import ROOT, audit


def main():
    cpu = ROOT / 'efinity/c39_cpu_s2_generate_20260915a'
    hosts = ('c37', 'c39', 'native', 'onehot', 'onehot_cdc')
    actual = audit(cpu, hosts)
    top = ROOT / 'efinity/c1_ti60_c39_joint_s2_onehot_cdc.sv'
    sdc = top.with_suffix('.sdc')
    bsp = cpu / 'ip/c39_soc_s2/Ti60F225_devkit/embedded_sw/c39_soc_s2/bsp/efinix/EfxSapphireSoc/include/soc.h'
    cases = (
        ('cpu_clock', top, '.io_systemClk(core_clk)', '.io_systemClk(cam_clk)'),
        ('ddr_user_clock', top, '.axi_clk(core_clk)', '.axi_clk(cam_clk)'),
        ('calibration_bypass', top, 'assign cpu_arvalid=soc_arvalid && cal_ready;', 'assign cpu_arvalid=soc_arvalid;'),
        ('unrecorded_150MHz', sdc, 'core_clk -period 10', 'core_clk -period 6.666'),
        ('incompatible_compressed_ISA', bsp, '#define SYSTEM_RISCV_ISA_EXT_C 0', '#define SYSTEM_RISCV_ISA_EXT_C 1'),
    )
    original_read = Path.read_text
    rejected = []
    for name, target, old, new in cases:
        original = original_read(target, encoding='utf-8-sig')
        if original.count(old) != 1:
            raise ValueError('platform mutation anchor changed: ' + name)
        def altered(path, *args, **kwargs):
            return original.replace(old, new) if path == target else original_read(path, *args, **kwargs)
        with patch.object(Path, 'read_text', altered):
            try:
                audit(cpu, hosts)
            except ValueError:
                rejected.append(name)
            else:
                raise AssertionError('platform mismatch accepted: ' + name)
    print('C39_JOINT_PLATFORM_SELFTEST_PASS ' + json.dumps(dict(
        actual_public_platform_pass=True, joint_projects=actual['joint_projects'],
        rejected_evidence_mutations=rejected, actual_CPU_execution=False,
        protected_payload_read=False, source_files_modified=False), separators=(',', ':')))


if __name__ == '__main__':
    main()
