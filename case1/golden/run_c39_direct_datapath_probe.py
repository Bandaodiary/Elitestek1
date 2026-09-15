"""Unchanged C39/C37 numerical gates with two producer-native source replacements."""
import run_c39_datapath_probe as probe
from c39_direct_sources import ROOT, REPLACEMENTS, sources, verify


if __name__ == '__main__':
    verify()
    probe.REPLACEMENTS = {old: REPLACEMENTS.get(new, new) for old, new in probe.REPLACEMENTS.items()}
    probe.REPLACEMENTS.update(REPLACEMENTS)
    probe.sources = sources
    print('C39_DIRECT_VARIANT_BEGIN actual_producer_native_sources=1', flush=True)
    probe.main()
