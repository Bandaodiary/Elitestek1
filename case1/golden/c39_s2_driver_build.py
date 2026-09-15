"""Compile every current-host driver API for S2; never execute or program it."""
import argparse
import ctypes
import json
from pathlib import Path
import re
import shutil
import tempfile
from c39_s2_software_probe import TOOL, run
from c39_sapphire_platform_contract import ROOT, audit

SOURCES = ('c1_r2_rgbx_video.c', 'c1_r2_host_video.c', 'c1_r2_rgb2_camera.c')
APIS = ('c1_r2x_control', 'c1_r2x_result_read', 'c1_r2x_interrupts',
        'c1_r2h_status_read', 'c1_r2h_control', 'c1_r2c2_info_read')


def check_attributes(text):
    match = re.search(r'Tag_RISCV_arch:\s*"([^"]+)"', text)
    if not match:
        raise ValueError('missing actual ISA attributes')
    fields = match[1].split('_')
    if not re.fullmatch(r'rv32i\d+p\d+', fields[0]) or any(
            not re.fullmatch(r'(m|zicsr|zifencei|zmmul)\d+p\d+', f) for f in fields[1:]):
        raise ValueError('compiled ISA exceeds S2 non-C/non-F contract')
    return match[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--run-id', required=True)
    args = parser.parse_args()
    if not re.fullmatch('[A-Za-z0-9_-]+', args.run_id):
        raise ValueError('invalid run identifier')
    log = ROOT / 'logs/c39_s2_driver_runs' / args.run_id
    if log.exists():
        raise ValueError('refuse existing build evidence')
    api = ctypes.WinDLL('kernel32', use_last_error=True)
    api.GetCurrentProcess.restype = ctypes.c_void_p
    api.SetProcessAffinityMask.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    api.SetPriorityClass.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    handle = api.GetCurrentProcess()
    if not api.SetProcessAffinityMask(handle, 3) or not api.SetPriorityClass(handle, 0x4000):
        raise ctypes.WinError(ctypes.get_last_error())
    cpu = ROOT / 'efinity/c39_cpu_s2_generate_20260915a'
    platform = audit(cpu, ('onehot_cdc',))
    bsp = cpu / 'ip/c39_soc_s2/Ti60F225_devkit/embedded_sw/c39_soc_s2/bsp/efinix/EfxSapphireSoc/include'
    contract = ROOT / 'software/c39_s2_probe/driver_contract.h'
    flags = ['-march=rv32im_zicsr_zifencei', '-mabi=ilp32', '-mno-relax', '-msmall-data-limit=0',
             '-Os', '-std=c11', '-Wall', '-Wextra', '-Werror', '-ffreestanding', '-fno-builtin',
             '-ffunction-sections', '-fdata-sections', '-nostdlib',
             '-I' + str(bsp), '-I' + str(ROOT / 'software/include'), '-include', str(contract)]
    gcc = TOOL / 'riscv-none-elf-gcc.exe'
    compiler = run([gcc, '--version'], ROOT).splitlines()[0]
    records = []
    with tempfile.TemporaryDirectory(prefix='c39_s2_drivers_', dir=ROOT / 'tmp') as private:
        folder = Path(private)
        objects = []
        for source in SOURCES:
            target = folder / Path(source).with_suffix('.o')
            command = [gcc, *flags, '-c', ROOT / 'software/src' / source, '-o', target]
            run(command, folder)
            attrs = run([TOOL / 'riscv-none-elf-readelf.exe', '-A', target], folder)
            records.append(dict(source=source, isa=check_attributes(attrs), bytes=target.stat().st_size))
            objects.append(target)
        # Relocatable link WITHOUT --gc-sections: all six public APIs remain.
        linked = folder / 'c39_s2_current_host_drivers.o'
        run([gcc, '-march=rv32im_zicsr_zifencei', '-mabi=ilp32', '-mno-relax', '-nostdlib',
             '-r', '-Wl,--no-relax', *objects, '-o', linked], folder)
        isa = check_attributes(run([TOOL / 'riscv-none-elf-readelf.exe', '-A', linked], folder))
        header = run([TOOL / 'riscv-none-elf-readelf.exe', '-h', linked], folder)
        if 'ELF32' not in header or not re.search(r'Type:\s+REL\b', header):
            raise ValueError('not an RV32 relocatable driver library')
        symbols = run([TOOL / 'riscv-none-elf-nm.exe', '--defined-only', linked], folder)
        public = sorted(re.findall(r'^\S+\s+T\s+(c1_r2\w+)\s*$', symbols, re.M))
        if public != sorted(APIS):
            raise ValueError('missing or unexpected current-host API: ' + repr(public))
        unresolved = run([TOOL / 'riscv-none-elf-nm.exe', '-u', linked], folder).strip()
        if unresolved:
            raise ValueError('driver library has unresolved dependencies: ' + unresolved)
        assembly = run([TOOL / 'riscv-none-elf-objdump.exe', '-d', linked], folder)
        words = re.findall(r'^\s*[0-9a-f]+:\s+([0-9a-f]+)\s', assembly, re.M | re.I)
        if not words or any(len(w) != 8 for w in words):
            raise ValueError('non-32-bit instruction in driver object')
        if not re.search(r'\bfence\b', assembly):
            raise ValueError('MMIO ordering fence missing')
        size = run([TOOL / 'riscv-none-elf-size.exe', linked], folder).splitlines()[-1].split()
        # Actual compiler negative controls: accidental C/F targets must fail
        # the same source contract, not merely be rejected by a JSON validator.
        rejected = []
        for march in ('rv32imc_zicsr_zifencei', 'rv32imf_zicsr_zifencei'):
            wrong_flags = ['-march=' + march] + flags[1:]
            try:
                run([gcc, *wrong_flags, '-c', ROOT / 'software/src' / SOURCES[0],
                     '-o', folder / 'rejected.o'], folder)
            except RuntimeError as error:
                if 'neither compressed instructions nor floating point' not in str(error):
                    raise RuntimeError('wrong compiler negative failure') from error
                rejected.append(march)
            else:
                raise AssertionError('incompatible ISA compiled against S2 contract')
        log.mkdir(parents=True)
        shutil.copy2(linked, log / linked.name)
        report = dict(marker='C39_S2_CURRENT_DRIVER_BUILD_PASS', compiler=compiler, isa=isa,
            inputs=records, all_public_APIs=public, instructions_checked=len(words),
            text_bytes=int(size[0]), data_bytes=int(size[1]), bss_bytes=int(size[2]),
            relocatable_bytes=linked.stat().st_size, undefined_symbols=0,
            real_compiler_ISA_negatives=rejected, flags=flags, current_generated_BSP=str(bsp),
            cpu_ddr_clock_mhz=platform['cpu_ddr_user_clock_mhz'], old_C1_R2C1_R2V1_drivers_excluded=True,
            gc_sections_used=False, MMIO_runtime_tested=False, CPU_execution_verified=False,
            PLIC_cache_PHY_verified=False, board_programmed=False, private_build_removed=False)
    report['private_build_removed'] = not folder.exists()
    (log / 'summary.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, separators=(',', ':')))


if __name__ == '__main__':
    main()
