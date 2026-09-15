"""Compare only bounded public IP headers; never inspect protected payloads."""
import argparse
import json
from pathlib import Path
import re
from c38_joint_sources import SOC, ports

ROOT = Path(__file__).resolve().parents[1]


def public_ports(path, module):
    opened = False
    with path.open(encoding='utf-8-sig') as stream:
        for count, line in enumerate(stream, 1):
            if count > 512 or '`pragma protect' in line:
                raise ValueError('public header boundary not found before protected payload')
            if re.search(r'\bmodule\s+' + re.escape(module) + r'\b', line):
                opened = True
            if opened and re.search(r'\)\s*;', line):
                return ports(path, module, count, {})
    raise ValueError('missing public module header')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    directory = args.directory.resolve()
    if not directory.is_relative_to((ROOT / 'efinity').resolve()):
        raise ValueError('not a C39 workspace directory')
    report = json.loads((directory / 'validated_config.json').read_text(encoding='utf-8'))
    if not report['generation_complete'] or not report['official_validation_pass']:
        raise ValueError('official generation not complete')
    profile = report['profile']
    name = 'c39_soc_' + profile
    baseline = public_ports(SOC, 'soc')
    candidate = public_ports(directory / 'ip' / name / (name + '.v'), name)
    removed = sorted(set(baseline) - set(candidate))
    added = sorted(set(candidate) - set(baseline))
    changed = sorted(key for key in set(candidate) & set(baseline) if candidate[key] != baseline[key])
    # Official IP-XACT ties axiAInterrupt and axiA_* to AXISlave, despite the
    # generator CLI using the io_axiA spelling internally.
    unexpected = [key for key in removed if not key.startswith(('axiA_', 'io_ddrMasters_0_')) and key != 'axiAInterrupt']
    if profile == 's0' and (removed or added or changed):
        raise ValueError('S0 public boundary differs from vendor baseline')
    if profile == 's1' and (unexpected or added or changed or not removed):
        raise ValueError('S1 changed interfaces outside the two requested ports: ' +
                         json.dumps({'unexpected_removed': unexpected, 'added': added, 'changed': changed, 'removed_count': len(removed)}))
    print('C39_SAPPHIRE_PUBLIC_PORT_AUDIT ' + json.dumps({
        'profile': profile, 'installed_version': report['vlnv']['version'],
        'reference_ports': len(baseline), 'candidate_ports': len(candidate),
        'removed': removed, 'added': added, 'changed_width_or_direction': changed,
        'profile_boundary_pass': profile in ('s0', 's1'),
        'S2_requires_separate_clock_contract': profile == 's2',
        'protected_payload_read': False, 'cpu_execution_verified': False,
    }), flush=True)


if __name__ == '__main__':
    main()
