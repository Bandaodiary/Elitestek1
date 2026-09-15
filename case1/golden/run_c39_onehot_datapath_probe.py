"""Bind unchanged complete numerical gates to one-hot RTL; retain compiled metadata."""
import json
import re
import run_c39_datapath_probe as probe
from c39_direct_sources import REPLACEMENTS as direct_replacements
from c39_native_sources import OLD_SOURCE, NEW_SOURCE
from c39_onehot_sources import OLD, NEW, sources, verify
from c39_fallback_compile_audit import EXPECTED, metadata
from run_c39_requant_probe import compiled_sources


def window_metadata(head, tail, source_list, options):
    """Check the actual compiled top capacity and complete terminal source table."""
    prefix = '-Ptb_c37_window_capacity.ROW_WORDS='
    requested = [int(option[len(prefix):]) for option in options if option.startswith(prefix)]
    if len(requested) != 1 or requested[0] not in (512, 1024):
        raise ValueError('missing/invalid explicit window capacity')
    actual = re.findall(r'\.param/l "ROW_WORDS"[^\r\n]*\+C4<([01]+)>;', head)
    if not actual or int(actual[0], 2) != requested[0]:
        raise ValueError('actual compiled window capacity differs')
    expected = [path.resolve().as_posix() for path in source_list]
    entries = compiled_sources(tail, expected)
    return dict(row_words=requested[0], source_files=expected,
                actual_source_entries=entries, metadata_read_limit_bytes=32768)


def main():
    verify()
    mapping = {old: direct_replacements.get(new, new) for old, new in probe.REPLACEMENTS.items()}
    mapping.update(direct_replacements)
    mapping = {old: NEW_SOURCE if new == OLD_SOURCE else new for old, new in mapping.items()}
    mapping[OLD_SOURCE] = NEW_SOURCE
    mapping[OLD] = NEW
    probe.REPLACEMENTS = mapping
    probe.sources = sources
    original_compile = probe.baseline_gate.compile_test

    def compile_with_metadata(folder, top, source_list, options=()):
        executable = original_compile(folder, top, source_list, options)
        if top == 'tb_c37_window_capacity':
            with executable.open('rb') as stream:
                head = stream.read(16384).decode('utf-8', errors='strict')
                stream.seek(max(0, executable.stat().st_size - 16384))
                tail = stream.read(16384).decode('utf-8', errors='strict')
            record = window_metadata(head, tail, source_list, options)
            record['snapshot'] = str(executable)
            print('C39_ONEHOT_WINDOW_COMPILED_SNAPSHOT ' + json.dumps(record, separators=(',', ':')), flush=True)
        if top == 'tb_c37_operator_fallback':
            prefixes = [option for option in options if option.startswith('-P' + top + '.STALLS=')]
            if len(prefixes) != 1:
                raise ValueError('missing explicit fallback backpressure profile')
            stalls = int(prefixes[0].split('=')[-1])
            expected = tuple(NEW if source == OLD else source for source in EXPECTED)
            record = metadata(executable, stalls, expected)
            record['required_candidate_sources_verified'] = record.pop('required_native_sources_verified')
            record['variant'] = 'onehot'
            record['simulation_complete'] = False
            print('C39_ONEHOT_COMPILED_SNAPSHOT ' + json.dumps(record, separators=(',', ':')), flush=True)
        return executable

    probe.baseline_gate.compile_test = compile_with_metadata
    print('C39_ONEHOT_VARIANT_BEGIN actual_shared_decode_unpack=1', flush=True)
    probe.main()


if __name__ == '__main__':
    main()
