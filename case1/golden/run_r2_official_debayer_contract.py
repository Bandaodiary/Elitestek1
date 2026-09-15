"""C30 active vendor XML -> direct portable RTL simulation; no PHY/board claims."""
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
VENDOR=Path('D:/contest/Ti60F225_DemoBoard_v4/10_Ti60f225_sc431hai2hdmi_demo/Ti60f225_sc431hai2hdmi_v1')
SOURCES=['rtl/true_dual_port_ram.v','rtl/debayer/rgb_gain.v','rtl/debayer/line_buffer.v',
         'rtl/debayer/raw_to_rgb.v','rtl/debayer/debayer_top_2to1.v']


def main():
    listed=[n.attrib['name'] for n in ET.parse(VENDOR/'ti60f225_oob.xml').getroot().iter()
            if n.tag.rsplit('}',1)[-1]=='design_file']
    if not all(listed.count(s)==1 and (VENDOR/s).is_file() for s in SOURCES):
        raise ValueError('vendor active source closure mismatch')
    with tempfile.TemporaryDirectory(prefix='c30_official_debayer_',dir=ROOT/'sim') as td:
        for bad in (0,1):
            exe=Path(td)/f'contract_{bad}.vvp'
            c=subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s','tb_c30_official_debayer_contract',
                              f'-Ptb_c30_official_debayer_contract.BAD_RAW_PACKING={bad}',
                              '-o',str(exe),*[str(VENDOR/s) for s in SOURCES],
                              str(ROOT/'sim/tb_c30_official_debayer_contract.sv')],capture_output=True,text=True,timeout=60)
            if c.returncode:raise RuntimeError(c.stderr[-3000:])
            r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],capture_output=True,text=True,timeout=60)
            if bad:
                if r.returncode==0 or 'official RGB golden mismatch' not in r.stdout:
                    raise RuntimeError('wrong actual RAW packing not detected')
                print('C30_OFFICIAL_RAW_PACKING_NEGATIVE_PASS actual_rtl_mutation=1',flush=True)
            else:
                if r.returncode:raise RuntimeError((r.stdout+r.stderr)[-4000:])
                if r.stdout.count('C30_OFFICIAL_CONTROL_PASS ')!=1 or r.stdout.count('C30_OFFICIAL_INTERIOR_GOLDEN_PASS ')!=1:
                    raise RuntimeError('no unique complete result')
                for line in r.stdout.splitlines():
                    if line.startswith('C30_'):print(line,flush=True)
    print('C30_OFFICIAL_CLEAN private_simulator_removed=1 vendor_sources_edited=0',flush=True)


if __name__=='__main__':main()
