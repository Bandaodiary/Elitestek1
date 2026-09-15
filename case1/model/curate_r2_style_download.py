"""Recover a useful group-disjoint dataset after a bounded download stops.

Does not restart networking, delete/move/duplicate photos, rewrite the failed
worker's status, or pretend the originally requested download completed.
The logical split is in manifest.json; file directories retain download origin.
"""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import random

import psutil

from prepare_r2_style_data import save_json, validate_manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dataset', type=Path, required=True)
    parser.add_argument('--train', type=int, default=192)
    parser.add_argument('--val', type=int, default=32)
    parser.add_argument('--test', type=int, default=32)
    args = parser.parse_args()
    root = args.dataset.resolve()
    if (root/'manifest.json').exists():
        raise FileExistsError('curated manifest already exists')
    status = json.loads((root/'status.json').read_text(encoding='utf-8'))
    if status['state'] != 'failed' or 'network body-byte budget exhausted' not in status.get('error',''):
        raise ValueError('only a terminal, budget-limited download may be curated here')
    try:
        process = psutil.Process(status['pid'])
        if abs(process.create_time()-status['process_start']) < .001:
            raise RuntimeError('original download worker still alive; no curation')
    except psutil.NoSuchProcess:
        pass
    requested = {k:getattr(args,k) for k in ('train','val','test')}
    if min(requested.values()) < 1 or sum(requested.values()) > len(status['images']):
        raise ValueError('insufficient downloaded images')
    by_author = defaultdict(list)
    for row in status['images']:
        by_author[row['AuthorProfileURL'].rstrip('/')].append(row)
    groups = list(by_author.values())
    rng = random.Random(status['seed']+2)
    rng.shuffle(groups)
    # Prefer whole small author groups for exact validation/test counts, keeping
    # enough distinct photographers and photos available for actual training.
    groups.sort(key=len)
    selected = []
    for split in ('val','test','train'):
        needed = requested[split]
        unused = []
        for group in groups:
            if needed and (len(group) <= needed or split == 'train'):
                taken = group[:needed]
                selected.extend(dict(row, downloaded_split=row['split'], split=split) for row in taken)
                needed -= len(taken)
            else:
                unused.append(group)
        if needed:
            raise ValueError(f'cannot form exact whole-photographer {split} split')
        groups = unused
    manifest = dict(status)
    manifest.pop('error',None)
    manifest.update(state='complete', images=selected, requested=requested,
                    counts=requested, split_rule='seeded photographer-disjoint groups; excess final training photos unused; curated after byte-budget stop',
                    download_request_completed=False,
                    original_download_status='status.json',
                    original_download_requested=status['requested'],
                    original_downloaded_images=len(status['images']),
                    unused_downloaded_images=len(status['images'])-len(selected),
                    file_directory_names_are_not_logical_split=True)
    validate_manifest(root, manifest)
    save_json(root/'manifest.json', manifest)
    print('C36_BOUNDED_DATASET_CURATED '+json.dumps(dict(counts=requested, downloaded=len(status['images']),
        body_bytes=status['network_body_bytes'], additional_download_bytes=0, image_files_moved_or_copied=0)))


if __name__ == '__main__':
    main()
