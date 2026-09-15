"""Create a private camera-cadence testbench or audit completed native evidence."""
import argparse
import json
from pathlib import Path

from r2_camera_cadence_contract import ROOT,TOP,render_testbench,assess,profile


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile',choices=('legacy','camera30'),required=True)
    parser.add_argument('--output-dir',type=Path,required=True)
    parser.add_argument('--evidence',type=Path)
    args=parser.parse_args()
    root=args.output_dir.resolve()
    if root.exists() or not any(root.is_relative_to(ROOT/part) for part in ('sim','outputs')):
        raise ValueError('new private sim/outputs directory required')
    if args.evidence:
        report=assess(args.evidence.read_text(encoding='utf-8-sig'),args.profile)
        report['source_evidence_file']=str(args.evidence.resolve())
        root.mkdir(parents=True)
        (root/'cadence.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
        print('C36_CAMERA_CADENCE_AUDITED '+json.dumps(report,separators=(',',':')))
    else:
        source,report=render_testbench((ROOT/'sim'/f'{TOP}.sv').read_text(encoding='utf-8-sig'),args.profile)
        root.mkdir(parents=True)
        (root/f'{TOP}.sv').write_text(source,encoding='utf-8')
        (root/'cadence.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
        print('C36_CAMERA_CADENCE_FIXTURE_PREPARED '+json.dumps(report,separators=(',',':')))


if __name__=='__main__':
    main()
