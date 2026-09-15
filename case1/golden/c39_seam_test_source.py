"""Derive an independent C39 seam regression without changing the C38 gate."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def source():
    old = (ROOT / 'golden/run_c38_joint_seam_probe.py').read_text(encoding='utf-8-sig')
    imports = '''from c38_joint_sources import ROOT, SOC, DDR, HOST, NAME, ports, build, same_artifact
from c37_sources import sources'''
    replacement = '''import argparse
import json
from c38_joint_sources import ROOT, DDR, HOST, ports as original_ports, same_artifact
from c37_sources import sources as retained_sources
from c39_candidate_sources import sources as candidate_sources
from c39_joint_projects import artifacts, host_sources
from c39_sapphire_port_audit import public_ports

parser=argparse.ArgumentParser()
parser.add_argument('directory',type=Path)
parser.add_argument('--host',choices=('c37','c39','direct','native','onehot'),default='c39')
args=parser.parse_args()
directory=args.directory.resolve()
report=json.loads((directory/'validated_config.json').read_text(encoding='utf-8'))
profile=report['profile']
CPU_MODULE='c39_soc_'+profile
SOC=directory/'ip'/CPU_MODULE/(CPU_MODULE+'.v')
NAME='c1_ti60_c39_joint_'+profile+'_'+args.host
sources=host_sources(args.host)
def build():return artifacts(directory,args.host)
def ports(path,module,count,constants):
    return public_ports(path,CPU_MODULE) if path==SOC else original_ports(path,module,count,constants)'''
    if old.count(imports) != 1:
        raise ValueError('C38 imports changed')
    old = old.replace(imports, replacement)
    start, end = old.index('def main():'), old.index('\ndef execute():')
    old = old[:start] + '''def main():
    from run_c37_leaf_probe import budget
    from c39_seam_admission import check
    budget()
    check()
    execute()

''' + old[end:]
    anchor = "for name,ps in [('soc',soc),('ddr3_top',ddr)]:"
    if old.count(anchor) != 1:
        raise ValueError('C38 stub declaration changed')
    old = old.replace(anchor, "for name,ps in [(CPU_MODULE,soc),('ddr3_top',ddr)]:")
    old = old.replace('C38', 'C39').replace('c38_seam_', 'c39_seam_').replace('actual_C37_RTL=1', 'actual_host_RTL=1')
    # Do not rewrite retained helper module names in imports.
    old = old.replace('from c39_joint_sources import ROOT, DDR', 'from c38_joint_sources import ROOT, DDR')
    return old


if __name__ == '__main__':
    target=ROOT/'golden/run_c39_joint_seam_probe.py'
    if target.exists():raise ValueError('refuse overwrite independent gate')
    print('*** Begin Patch\n*** Add File: '+target.as_posix())
    print('\n'.join('+'+line for line in source().splitlines()))
    print('*** End Patch')
