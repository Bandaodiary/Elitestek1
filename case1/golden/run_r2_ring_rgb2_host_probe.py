"""C34 named full-host candidate. Reuse C33 stimuli without changing its files."""
import sys
import xml.etree.ElementTree as ET
import run_r2_credit_rgb2_host_probe as retained

ROOT=retained.ROOT
PROJECT=ROOT/'efinity/c1_ti60_r2_ring_rgb2_host96.xml'
SOURCES=[(PROJECT.parent/e.attrib['name']).resolve().relative_to(ROOT).as_posix()
         for e in ET.parse(PROJECT).getroot().iter()
         if e.tag.rsplit('}',1)[-1]=='design_file' and e.attrib['name']!='c1_ti60_r2_ring_rgb2_host96.sv']
TOP='tb_c1_r2_ring_rgb2_host_system'
PREFIX='C1_R2_RING_RGB2_HOST_SYSTEM_'


def main():
    if '--paired' in sys.argv:
        sys.argv.remove('--paired')
        retained.main()  # Actual C33 run with the same argv, before any override.
    retained.PROJECT=PROJECT;retained.SOURCES=SOURCES;retained.TOP=TOP;retained.PREFIX=PREFIX
    # compile-only in the old driver names its original top explicitly. Do not
    # accept it here and accidentally compile a different design.
    if '--compile-only' in sys.argv:raise ValueError('C34 compile via its actual host testbench')
    retained.main()


if __name__=='__main__':main()
