"""Register already-generated S0/S1/S2 validated configs without regeneration."""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
directory = Path(sys.argv[1]).resolve()
if not directory.is_relative_to(ROOT / 'efinity'):
    raise ValueError('unexpected settings path')
report = json.loads((directory / 'validated_config.json').read_text(encoding='utf-8'))
assert report['generation_complete'] and report['official_validation_pass']
name = 'c39_soc_' + report['profile']
target = directory / 'ip' / name / 'settings.json'
content = {'args': ['-o', name, '--base_path', str(directory / 'ip'), '--vlnv', report['vlnv']],
           'conf': report['parameters'], 'sw_version': '2026.1.132.3.9'}
if target.exists():
    old = target.read_text(encoding='utf-8-sig')
    old_obj = json.loads(old)
    # Retain generated fileset selections and metadata; repair only config/path.
    old_obj.update(content)
    new = json.dumps(old_obj, indent=4) + '\n'
    print('*** Begin Patch\n*** Update File: ' + target.as_posix() + '\n@@')
    print('\n'.join('-' + line for line in old.splitlines()))
    print('\n'.join('+' + line for line in new.splitlines()))
else:
    new = json.dumps(content, indent=4) + '\n'
    print('*** Begin Patch\n*** Add File: ' + target.as_posix())
    print('\n'.join('+' + line for line in new.splitlines()))
print('*** End Patch')
