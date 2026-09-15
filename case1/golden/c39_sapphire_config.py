"""Use installed official IP-manager validation/generation in an isolated tree.

Never edit a vendor implementation. S0/S1/S2 all use the SAME installed IP version;
the supplied demo uses 3.3.0 whereas the installed package is currently 3.4.1.
Run with Efinity's bundled Python. Generation is a separately authorized action.
"""
import argparse
from dataclasses import replace
import json
import os
from pathlib import Path
import re
import shutil
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
EFINITY = Path('D:/ELS/Efinity/2026.1')
SOC_DIR = EFINITY / 'ipm/ip/efx_soc/efx_soc/ipm'
VENDOR_SETTINGS = Path('D:/contest/Ti60F225_DemoBoard_v4/08_ti60f225_soc_demo/09_Ti60F225_co_debug_demo/par/ddr_demo_ti60/ip/soc/settings.json')
PROFILES = {
    's0': {},
    's1': {'AXISlave': "1'b0", 'AXIMaster': "1'b0"},
    's2': {'AXISlave': "1'b0", 'AXIMaster': "1'b0", 'SOC_MODE': '1',
           'DDRCLK_DOMAIN': '1', 'MULDIV_EXT': "1'b1", 'BARREL_SHIFTER': "1'b1", 'REDUCED_CSR': "1'b0"},
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', choices=PROFILES, required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--generate', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch('[a-zA-Z0-9_]+', args.run_id):
        raise ValueError('unsafe run id')
    target = ROOT / 'efinity' / ('c39_cpu_' + args.run_id)
    if target.exists():
        raise ValueError('refuse overwrite existing output ' + str(target))
    target.mkdir()
    (target / 'logs').mkdir()
    (target / 'user').mkdir()
    (target / 'user/gui').mkdir()
    (target / 'tmp').mkdir()
    (target / 'runtime').mkdir()
    # The official cache writer expects this metadata at its private cache root.
    # Copy the public IP-XACT definition, never an editable installed source.
    shutil.copy2(SOC_DIR / 'ip_component.xml', target / 'user/ip_component.xml')
    shutil.copy2(SOC_DIR / 'gui/config_template.json', target / 'user/gui/config_template.json')
    os.environ['EFINITY_HOME'] = EFINITY.as_posix()
    os.environ['EFINITY_USER_DIR'] = (target / 'user').as_posix()
    os.environ['EFXIPM_HOME'] = (EFINITY / 'ipm').as_posix()
    os.environ['QT_QPA_PLATFORM'] = 'offscreen'
    # IPM treats ANY Java stderr as failure, including JAVA_TOOL_OPTIONS' banner.
    # Supply limits as normal command arguments via our private launcher instead.
    if os.environ.get('JAVA_TOOL_OPTIONS') or os.environ.get('JDK_JAVA_OPTIONS') or os.environ.get('_JAVA_OPTIONS'):
        raise RuntimeError('inherited Java option environment needs explicit review')
    java = shutil.which('java.exe')
    if not java:
        raise RuntimeError('java.exe not available')
    (target / 'runtime/java.cmd').write_text(
        '@echo off\n"' + str(Path(java).resolve()) + '" -XX:ActiveProcessorCount=2 -Xmx768m %*\nexit /b %errorlevel%\n',
        encoding='ascii')
    os.environ['PATH'] = str(target / 'runtime') + os.pathsep + os.environ['PATH']
    os.environ['TMP'] = os.environ['TEMP'] = str(target / 'tmp')
    sys.path.insert(0, str(EFINITY / 'ipm/bin'))
    from run_c37_leaf_probe import budget
    budget()
    from common.logger import Logger
    Logger.setup_logger(str(target / 'logs'), log_filename='ipm.log')
    from efx_ipmgr.api_v2 import IPManagerBackend, Resolve
    from efx_ipmgr.production_api.type.vlnv_type import VLNV

    class ScopedBackend(IPManagerBackend):
        def reload_vlnv(self, opt):
            return super().reload_vlnv(replace(opt, xml_search_dir=(SOC_DIR,), user_xml_search_dir=()))

    xml = ET.parse(SOC_DIR / 'ip_component.xml').getroot()
    identity = {item.tag.rsplit('}', 1)[-1]: item.text for item in xml
                if item.tag.rsplit('}', 1)[-1] in ('vendor', 'library', 'name', 'version')}
    vlnv = VLNV(**identity)
    backend = ScopedBackend()
    backend.load(vlnv, ipm_dir_path=str(target / 'user'), device='Ti60F225', family='Titanium')
    settings = json.loads(VENDOR_SETTINGS.read_text(encoding='utf-8-sig'))
    configured = dict(settings['conf'])
    configured.update(PROFILES[args.profile])
    configured['HexFile_PathEnable'] = "1'b0"
    parameters = backend.get_ip_params(vlnv, resolve=Resolve.USER)
    names = {p.name for p in parameters}
    if not set(PROFILES[args.profile]) <= names:
        raise ValueError('missing requested official parameters')
    parameters = [p._replace(value=configured[p.name]) if p.name in configured else p for p in parameters]
    result, _, _, _ = backend.validate_params(vlnv, parameters, device='Ti60F225', family='Titanium')
    if not result.result:
        raise ValueError('official parameter validation failed: ' + repr(result.error_tuple_msg))
    resolved = backend.get_ip_params(vlnv, resolve=Resolve.USER)
    values = {p.name: p.value for p in resolved}
    for key, expected in PROFILES[args.profile].items():
        if str(values[key]) != expected:
            raise ValueError(f'official validation changed requested {key}: {values[key]} != {expected}')
    targets = backend.get_ip_filesets(vlnv)
    report = {
        'profile': args.profile, 'vlnv': identity, 'vendor_ip_version': settings['args'][-1]['version'],
        'official_validation_pass': True, 'requested_changes': PROFILES[args.profile],
        'parameters': values, 'generation_requested': args.generate,
        'generation_complete': False, 'physical_resource_measured': False,
        'vendor_sources_modified': False,
    }
    (target / 'validated_config.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print('C39_SAPPHIRE_CONFIG_VALIDATED ' + json.dumps({'profile': args.profile, 'version': identity['version'], 'parameters': len(values), 'directory': str(target)}), flush=True)
    if args.generate:
        generated = backend.generate_ip(vlnv, resolved, targets, gen_name='c39_soc_' + args.profile,
                                        proj_path=target, user_proj_path=target, user_ip_location=target,
                                        device='Ti60F225', family='Titanium', project_name='c39_cpu_' + args.profile)
        if generated is None:
            raise RuntimeError('official generator did not return settings')
        generated.set_params(resolved)
        # copy() serializes the supplied validated values directly, without
        # looking them up in a second unconfigured global backend singleton.
        generated.copy(target / 'ip' / ('c39_soc_' + args.profile) / 'settings.json')
        report['generation_complete'] = True
        (target / 'validated_config.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
        print('C39_SAPPHIRE_GENERATION_RETURNED profile=' + args.profile + ' independent_RTL_audit_pending=1', flush=True)


if __name__ == '__main__':
    main()
