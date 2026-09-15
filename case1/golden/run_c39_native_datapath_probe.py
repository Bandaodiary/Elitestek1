"""Existing full numerical gates, explicitly bound to the native-format experiment."""
import run_c39_datapath_probe as probe
from c39_direct_sources import REPLACEMENTS as direct_replacements
from c39_native_sources import ROOT, OLD_SOURCE, NEW_SOURCE, sources, verify


if __name__ == '__main__':
    verify()
    mapping = {old: direct_replacements.get(new, new) for old, new in probe.REPLACEMENTS.items()}
    mapping.update(direct_replacements)
    mapping = {old: NEW_SOURCE if new == OLD_SOURCE else new for old, new in mapping.items()}
    mapping[OLD_SOURCE] = NEW_SOURCE
    probe.REPLACEMENTS = mapping
    probe.sources = sources
    print('C39_NATIVE_VARIANT_BEGIN actual_compact_RGB_DW_construction=1', flush=True)
    probe.main()
