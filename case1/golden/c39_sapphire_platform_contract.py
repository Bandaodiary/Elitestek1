"""Bounded public-source/BSP audit. Does not execute or decrypt the CPU."""
import argparse
import json
import re
from pathlib import Path
from c39_sapphire_port_audit import ROOT, public_ports


def require(condition, message):
    if not condition:
        raise ValueError(message)


def audit(directory, hosts=('c37', 'c39')):
    require(hosts and len(set(hosts)) == len(hosts) and
            all(host in ('c37', 'c39', 'native', 'onehot', 'onehot_cdc') for host in hosts),
            'unknown or duplicate explicit S2 host profile')
    directory = directory.resolve()
    require(directory.is_relative_to((ROOT / 'efinity').resolve()), 'CPU outside workspace')
    report = json.loads((directory / 'validated_config.json').read_text(encoding='utf-8'))
    require(report['profile'] == 's2' and report['generation_complete'] and
            report['official_validation_pass'], 'expected officially generated S2')
    params = report['parameters']
    expected = dict(SOC_MODE='1', DDRCLK_DOMAIN='1', Frequency='100',
                    AXISlave="1'b0", AXIMaster="1'b0", MULDIV_EXT="1'b1",
                    BARREL_SHIFTER="1'b1", REDUCED_CSR="1'b0", FPU="1'b0",
                    DDRWidth='128', DDR_IdWidth='8', OCRSize='4096',
                    ICacheSize='4096', DCacheSize='4096')
    for key, value in expected.items():
        require(params[key] == value, 'configuration changed: ' + key)
    ip = directory / 'ip/c39_soc_s2'
    ports = public_ports(ip / 'c39_soc_s2.v', 'c39_soc_s2')
    require(ports.get('io_systemClk') == ('input', 1), 'system clock input changed')
    require(ports.get('io_asyncReset') == ('input', 1), 'asynchronous reset input changed')
    require('io_memoryClk' not in ports and 'io_memoryReset' not in ports,
            'Lite still exposes a separate DDR CPU clock')
    config = (ip / 'source/soc_config').read_text(encoding='utf-8-sig').splitlines()
    for line in ('--noDdrAClock', '--lowArea 10', '--systemFrequency 100000000',
                 '--ddrADataWidth 128', '--ddrAIdWidth 8', '--onChipRamSize 0x1000',
                 '--onChipRamAddress 0xf9000000', '--Fpu false', '--Atomic false'):
        require(line in config, 'actual generation argument missing: ' + line)
    bsp = ip / 'Ti60F225_devkit/embedded_sw/c39_soc_s2/bsp/efinix/EfxSapphireSoc'
    header = (bsp / 'include/soc.h').read_text(encoding='utf-8-sig')
    defines = dict(re.findall(r'^#define\s+(\w+)\s+(\S+)\s*$', header, re.M))
    for key, value in dict(SYSTEM_CLINT_HZ=100000000, SYSTEM_RAM_A_SIZE=4096,
                           SYSTEM_RAM_A_CTRL=0xf9000000, IO_APB_SLAVE_0_INPUT=0xf8100000,
                           IO_APB_SLAVE_0_INPUT_SIZE=65536,
                           SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT=16,
                           SYSTEM_RISCV_ISA_RV32I=1, SYSTEM_RISCV_ISA_EXT_M=1,
                           SYSTEM_RISCV_ISA_EXT_A=0, SYSTEM_RISCV_ISA_EXT_C=0,
                           SYSTEM_RISCV_ISA_EXT_F=0, SYSTEM_RISCV_ISA_EXT_D=0,
                           SYSTEM_RISCV_ISA_EXT_ZICSR=1, SYSTEM_RISCV_ISA_EXT_ZIFENCE=1).items():
        require(int(defines[key], 0) == value, 'BSP definition changed: ' + key)
    boot = (bsp / 'linker/bootloader.ld').read_text(encoding='utf-8-sig')
    app = (bsp / 'linker/default.ld').read_text(encoding='utf-8-sig')
    require(re.search(r'ORIGIN\s*=\s*0xF9000000,\s*LENGTH\s*=\s*4K', boot),
            'bootloader must fit actual 4 KiB on-chip RAM')
    require(re.search(r'ORIGIN\s*=\s*0x00001000,\s*LENGTH\s*=\s*124K', app),
            'default application DDR layout changed')
    checked = []
    for host in hosts:
        name = 'c1_ti60_c39_joint_s2_' + host
        top = (ROOT / 'efinity' / (name + '.sv')).read_text(encoding='utf-8-sig')
        for anchor in ('.io_systemClk(core_clk)', '.io_asyncReset(!reset_n)',
                       '.axi_clk(core_clk)', '.core_clk(core_clk)',
                       'assign cpu_arvalid=soc_arvalid && cal_ready;'):
            require(top.count(anchor) == 1, 'joint clock/calibration seam changed: ' + anchor)
        require('.io_memoryClk(' not in top and '.io_memoryReset(' not in top,
                'unexpected dedicated memory clock connection')
        sdc = (ROOT / 'efinity' / (name + '.sdc')).read_text(encoding='utf-8-sig')
        require('create_clock -name core_clk -period 10 [get_ports core_clk]' in sdc,
                'resource core clock differs from BSP 100 MHz')
        checked.append(name)
    return dict(marker='C39_S2_STATIC_PLATFORM_CONTRACT_PASS', cpu_ip=report['vlnv']['version'],
                joint_projects=checked, cpu_ddr_user_clock_mhz=100, isa='RV32IM + CSR/fence',
                boot_ram_bytes=4096, application_region='DDR 0x1000, 124 KiB',
                bsp_ddr_aperture_bytes=int(defines['SYSTEM_DDR_BMB_SIZE'], 0),
                physical_ddr_bytes=268435456,
                limitations=['BSP DDR aperture is larger than physical DDR; retain adapter range checks',
                             'CPU debug/warm-reset during active accelerator jobs is not validated',
                             'Boot execution, cache maintenance and real PHY/board CDC remain unverified'],
                protected_payload_read=False, cpu_execution_verified=False, board_signoff=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--host', action='append', choices=('c37', 'c39', 'native', 'onehot', 'onehot_cdc'))
    args = parser.parse_args()
    print(json.dumps(audit(args.directory, tuple(args.host) if args.host else ('c37', 'c39')), ensure_ascii=False), flush=True)
