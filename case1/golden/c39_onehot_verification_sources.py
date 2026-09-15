"""Explicit one-hot runners, derived without weakening retained native/C37 gates."""
import sys
from c39_candidate_sources import ROOT, replace_once
from c39_trained_verification_sources import verify as verify_native_runners


def artifacts():
    verify_native_runners()
    contract = (ROOT / 'golden/c39_trained_contract.py').read_text(encoding='utf-8-sig')
    contract = contract.replace('c39_native_sources', 'c39_onehot_sources')
    contract = contract.replace('C39_NATIVE', 'C39_ONEHOT').replace('C39_TRAINED', 'C39_ONEHOT_TRAINED')
    contract = contract.replace('c1_ti60_c39_host_native', 'c1_ti60_c39_host_onehot')
    contract = replace_once(contract, 'c39_host_native_pnr_20260915a', 'c39_host_onehot_pnr_20260915a')
    contract = replace_once(contract, 'rtl/c39/c39_operand_codec.sv', 'rtl/c39_onehot/c39_operand_codec.sv')
    contract = contract.replace('native-format C39', 'one-hot C39')
    contract = replace_once(contract,
        "    print('C39_ONEHOT_RESOURCE_PREFLIGHT_PASS ' + json.dumps(report, separators=(',', ':')), flush=True)",
        "    print('C39_ONEHOT_RESOURCE_PREFLIGHT_PASS ' + json.dumps(report, separators=(',', ':')), flush=True)\n"
        "    from c39_joint_cdc_evidence import check as check_joint\n"
        "    joint = check_joint('c39_onehot_acceptance_20260915a_joint_s2_onehot_cdc')\n"
        "    print('C39_JOINT_CDC_EVIDENCE_PASS ' + json.dumps(joint, separators=(',', ':')), flush=True)")
    yield 'golden/c39_onehot_trained_contract.py', contract
    for source in (
        'golden/run_c39_trained_host_probe.py',
        'golden/check_c39_trained_pipeline.py',
        'scripts/run_c39_trained_pipeline_detached.ps1',
    ):
        text = (ROOT / source).read_text(encoding='utf-8-sig')
        text = text.replace('c39_trained', 'c39_onehot_trained')
        text = text.replace('c39_operator_preflight', 'c39_onehot_operator_preflight')
        text = text.replace('c39_source_preflight', 'c39_onehot_source_preflight')
        text = text.replace('C39_', 'C39_ONEHOT_').replace('C39_ONEHOT_NATIVE', 'C39_ONEHOT')
        text = text.replace('c1_ti60_c39_host_native', 'c1_ti60_c39_host_onehot')
        text = text.replace('native-format resource candidate', 'one-hot resource candidate')
        if source == 'golden/check_c39_trained_pipeline.py':
            text = replace_once(text, "    camera_config(status.get('camera_profile','legacy'))", """    from c39_joint_cdc_evidence import check as check_joint
    observed_joint=one_json((folder/'c39_onehot_source_preflight.tail.log').read_text(encoding='utf-8-sig'),
                            'C39_JOINT_CDC_EVIDENCE_PASS ')
    if observed_joint!=check_joint('c39_onehot_acceptance_20260915a_joint_s2_onehot_cdc'):
        raise ValueError('joint mapped CDC/timing preflight differs from actual evidence')
    camera_config(status.get('camera_profile','legacy'))""")
        yield source.replace('c39_trained', 'c39_onehot_trained'), text


def verify():
    for relative, expected in artifacts():
        if (ROOT / relative).read_text(encoding='utf-8-sig').strip() != expected.strip():
            raise ValueError('onehot verification source differs: ' + relative)


if __name__ == '__main__':
    if '--emit-patch' in sys.argv:
        print('*** Begin Patch')
        for relative, content in artifacts():
            if (ROOT / relative).exists():
                raise ValueError('refuse overwrite ' + relative)
            print('*** Add File: ' + (ROOT / relative).as_posix())
            print('\n'.join('+' + line for line in content.splitlines()))
        print('*** End Patch')
    else:
        verify()
        print('C39_ONEHOT_VERIFICATION_SOURCE_PASS retained_native_C37_gates_preserved=True actual_simulation=False')
