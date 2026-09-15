"""C26 unstoppable camera/ROI/Resize->CNN fixtures for a private no-wave xsim run."""
import argparse
import json
from pathlib import Path
from r2_fused_camera_vectors import vectors
from check_r2_fused_host_source import source_gate


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--width', type=int, required=True)
    p.add_argument('--height', type=int, required=True)
    p.add_argument('--profile', choices=('microstyle24', 'drop_res1'), default='microstyle24')
    a = p.parse_args()
    source_gate()
    a.output.mkdir(parents=True, exist_ok=True)
    if any((a.output/n).exists() for n in ('package', 'metadata.json', 'parameters.mem', 'expected.mem')):
        raise FileExistsError('private vectors already exist')
    m = vectors(a.output, a.width, a.height, a.profile)
    print('C35_FUSED_CAMERA_HOST_VECTOR_BUILD '+json.dumps(dict(profile=a.profile,
          width=a.width, height=a.height, sources=m['sources'], actual_resize_golden=True, actual_roi=True, unstoppable_source=True,
          stage_count=m['stage_count'], parameter_words=m['parameter_words'],
          input_words=m['input_words'], expected_words=m['expected_words'],
          dw_packets=m['dw_packets'], dw_stage=m['dw_stage'], pw_stage=m['pw_stage'])))


if __name__ == '__main__':
    main()
