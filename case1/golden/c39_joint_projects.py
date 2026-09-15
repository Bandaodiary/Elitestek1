"""Reuse the C38 wiring rules with a generated official CPU and explicit RTL."""
import argparse
import json
from pathlib import Path
import c38_joint_sources as joint
from c39_sapphire_port_audit import public_ports
from c39_candidate_sources import sources as candidate_sources
from c39_direct_sources import sources as direct_sources, verify as verify_direct
from c39_native_sources import sources as native_sources, verify as verify_native


def host_sources(host):
    if host == 'c37':
        from c37_sources import sources
        return sources
    if host == 'c39':
        return candidate_sources
    if host == 'direct':
        verify_direct()
        return direct_sources
    if host == 'native':
        verify_native()
        return native_sources
    if host == 'onehot':
        from c39_onehot_sources import sources, verify
        verify()
        return sources
    raise ValueError('unknown explicit host variant: ' + host)


def artifacts(directory, host):
    selected_sources = host_sources(host)
    directory = directory.resolve()
    if not directory.is_relative_to((joint.ROOT / 'efinity').resolve()):
        raise ValueError('CPU outside dedicated workspace area')
    cpu = json.loads((directory / 'validated_config.json').read_text(encoding='utf-8'))
    if not cpu['generation_complete'] or not cpu['official_validation_pass']:
        raise ValueError('CPU generation incomplete')
    profile = cpu['profile']
    module = 'c39_soc_' + profile
    source = directory / 'ip' / module / (module + '.v')
    cpu_ports = public_ports(source, module)
    name = 'c1_ti60_c39_joint_' + profile + '_' + host
    previous_ports = joint.ports
    previous_soc, previous_name, previous_sources = joint.SOC, joint.NAME, joint.sources
    try:
        joint.SOC, joint.NAME = source, name
        joint.ports = lambda path, mod, count, constants: cpu_ports if Path(path) == source else previous_ports(path, mod, count, constants)
        joint.sources = selected_sources
        result = joint.build()
    finally:
        joint.ports = previous_ports
        joint.SOC, joint.NAME, joint.sources = previous_soc, previous_name, previous_sources
    key = 'efinity/' + name + '.sv'
    anchor = '    soc u_soc ('
    if result[key].count(anchor) != 1:
        raise ValueError('CPU instance anchor changed')
    result[key] = '// C39 generated official IP / explicit host ablation. Not board signoff.\n' + result[key].replace(anchor, '    ' + module + ' u_soc (')
    contract = json.loads(result.pop('review/C38_JOINT_SOURCE_CONTRACT.json'))
    contract.update(cpu_profile=profile, cpu_ip_version=cpu['vlnv']['version'], host_variant=host,
                    cpu_config_file=str(directory / 'validated_config.json'),
                    external_AXI_A_removed=profile in ('s1', 's2'),
                    external_32bit_ingress_removed=profile in ('s1', 's2'))
    result['review/C39_JOINT_' + profile.upper() + '_' + host.upper() + '_CONTRACT.json'] = json.dumps(contract, indent=2) + '\n'
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--host', choices=('c37', 'c39', 'direct', 'native', 'onehot'), default='c37')
    args = parser.parse_args()
    print('*** Begin Patch')
    for relative, content in artifacts(args.directory, args.host).items():
        if (joint.ROOT / relative).exists():
            raise ValueError('refuse overwrite existing joint project ' + relative)
        print('*** Add File: ' + (joint.ROOT / relative).as_posix())
        print('\n'.join('+' + line for line in content.splitlines()))
    print('*** End Patch')
