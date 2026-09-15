"""Private C17 fixtures for the WMI-detached xsim runner, no waves."""
import argparse
import json
from pathlib import Path
from r2_plan_vectors import vectors


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--width', type=int, required=True)
    p.add_argument('--height', type=int, required=True)
    p.add_argument('--profile', choices=('microstyle24', 'drop_res1'), default='drop_res1')
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    if any((a.output/n).exists() for n in ('package', 'metadata.json', 'parameters.mem', 'expected.mem')):
        raise FileExistsError('private vectors already exist')
    m = vectors(a.output, a.width, a.height, a.profile)
    print('C1_R2_BOUND_GRAPH_VECTOR_BUILD '+json.dumps(dict(profile=a.profile, width=a.width, height=a.height,
          stage_count=m['stage_count'], parameter_words=m['parameter_words'], input_words=m['input_words'],
          expected_words=m['expected_words'])))


if __name__ == '__main__':
    main()
