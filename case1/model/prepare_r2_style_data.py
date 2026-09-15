"""Bounded, attributed Open Images subset + small training-only feature weights.

No archive download, dataset package install, private images, or checksums.
Image IDs AND photographer groups are disjoint between our train/val/test sets.
These are our own splits of a sample from upstream's validation partition;
they are not the official Open Images benchmark splits. Dataset license claims
are retained, not independently certified. Review originals before publication.
"""
from __future__ import annotations

import argparse
import csv
import ctypes
import io
import json
import os
from pathlib import Path
import random
import re
import time
import urllib.request

from PIL import Image
import psutil


METADATA_URL = 'https://storage.googleapis.com/openimages/2018_04/validation/validation-images-with-rotation.csv'
WEIGHTS_URL = 'https://download.pytorch.org/models/squeezenet1_1-b8a52dc0.pth'
SOURCE_PAGE = 'https://storage.googleapis.com/openimages/web/download_v7.html'
LICENSE_NOTE = 'https://storage.googleapis.com/openimages/web/factsfigures_v7.html'
FIELDS = ('ImageID', 'OriginalURL', 'OriginalLandingURL', 'License',
          'AuthorProfileURL', 'Author', 'Title', 'Rotation')


def save_json(path: Path, data):
    temporary = path.with_suffix(path.suffix + '.pending')
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
    temporary.replace(path)


def outside_job():
    if os.name != 'nt':
        return None
    api = ctypes.WinDLL('kernel32', use_last_error=True)
    api.GetCurrentProcess.restype = ctypes.c_void_p
    api.IsProcessInJob.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    result = ctypes.c_int()
    if not api.IsProcessInJob(api.GetCurrentProcess(), None, ctypes.byref(result)):
        raise ctypes.WinError(ctypes.get_last_error())
    return not bool(result.value)


class BoundedDownload:
    def __init__(self, limit_bytes):
        self.limit_bytes = limit_bytes
        self.received = 0

    def get(self, url, cap, prefix=False):
        if self.received + cap > self.limit_bytes:
            raise RuntimeError('network body-byte budget exhausted; no further download')
        headers = {'User-Agent': 'Case1-RTL-Style-Research/1.0'}
        if prefix:
            headers['Range'] = f'bytes=0-{cap-1}'
        data = bytearray()
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=25) as response:
            length = response.headers.get('Content-Length')
            if length and int(length) > cap and not prefix:
                raise ValueError('remote object exceeds per-file byte cap')
            while len(data) < cap:
                chunk = response.read(min(65536, cap - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
                self.received += len(chunk)
            if not prefix and len(data) == cap:
                raise ValueError('object reaches size cap; refuse potentially truncated data')
        return bytes(data)


def split_metadata(data: bytes, seed: int):
    # A prefix may end inside a quoted CSV field. Remove the partial final row
    # and accept only complete rows with validated identity/license fields.
    text = data.decode('utf-8-sig').rsplit('\n', 1)[0] + '\n'
    rows = []
    seen_sources = set()
    for raw in csv.DictReader(io.StringIO(text)):
        if any(raw.get(k) is None for k in FIELDS):
            continue
        if not re.fullmatch('[0-9a-f]{16}', raw['ImageID']):
            continue
        if raw['License'].rstrip('/') not in ('https://creativecommons.org/licenses/by/2.0',
                                              'http://creativecommons.org/licenses/by/2.0'):
            continue
        if raw['Rotation'] not in ('0', '0.0'):
            continue
        if not raw['AuthorProfileURL'] or not raw['OriginalLandingURL'] or not raw['Author']:
            continue
        if raw['OriginalLandingURL'] in seen_sources:
            continue
        seen_sources.add(raw['OriginalLandingURL'])
        rows.append({k: raw[k] for k in FIELDS})
    # Group on photographer URL, preventing a photographer's near-duplicate
    # series from being divided across our evaluation boundaries.
    groups = sorted({r['AuthorProfileURL'].rstrip('/') for r in rows})
    rng = random.Random(seed)
    rng.shuffle(groups)
    group_split = {g: ('val' if i % 10 == 0 else 'test' if i % 10 == 1 else 'train')
                   for i, g in enumerate(groups)}
    candidates = {k: [] for k in ('train', 'val', 'test')}
    for row in rows:
        candidates[group_split[row['AuthorProfileURL'].rstrip('/')]].append(row)
    for values in candidates.values():
        rng.shuffle(values)
    return candidates


def validate_manifest(root: Path, manifest):
    assert manifest['state'] == 'complete'
    ids, sources, authors = {}, {}, {}
    counts = {k: 0 for k in manifest['requested']}
    for row in manifest['images']:
        split = row['split']
        for lookup, key in ((ids, row['ImageID']), (sources, row['OriginalLandingURL']),
                            (authors, row['AuthorProfileURL'].rstrip('/'))):
            assert key not in lookup or lookup[key] == split, 'split leakage'
            lookup[key] = split
        path = (root / row['file']).resolve()
        assert path.is_relative_to(root.resolve()), 'path escapes dataset'
        assert path.stat().st_size == row['download_bytes']
        with Image.open(path) as image:
            assert list(image.size) == row['size']
            image.verify()
        counts[split] += 1
    assert len(ids) == len(manifest['images']), 'duplicate image'
    assert counts == manifest['requested'], (counts, manifest['requested'])
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--train', type=int, default=256)
    parser.add_argument('--val', type=int, default=32)
    parser.add_argument('--test', type=int, default=32)
    parser.add_argument('--seed', type=int, default=20260915)
    parser.add_argument('--budget-mib', type=int, default=64)
    parser.add_argument('--require-detached', action='store_true')
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    root = args.output.resolve()
    if args.verify_only:
        manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
        print('C36_DATASET_VERIFY_PASS', validate_manifest(root, manifest))
        return
    if min(args.train, args.val, args.test) < 1 or args.budget_mib > 64:
        raise ValueError('positive split sizes and <=64 MiB body budget required')
    if root.exists():
        raise FileExistsError('new dataset directory required; no silent overwrite or redownload')
    detached = outside_job()
    if args.require_detached and detached is not True:
        raise RuntimeError('worker must not be in a Windows Job')
    process = psutil.Process()
    process.cpu_affinity(process.cpu_affinity()[-1:])
    if os.name == 'nt':
        process.nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)
    root.mkdir(parents=True)
    requested = {k: getattr(args, k) for k in ('train', 'val', 'test')}
    manifest = dict(state='preparing', pid=os.getpid(), process_start=process.create_time(), outside_windows_job=detached,
                    created_local=time.strftime('%Y-%m-%dT%H:%M:%S%z'), seed=args.seed,
                    source_page=SOURCE_PAGE, license_note=LICENSE_NOTE,
                    dataset='Open Images, bounded sample of upstream validation',
                    split_rule='photographer-group-disjoint, seeded, 8:1:1 candidate allocation',
                    public_redistribution_reviewed=False, upstream_license_claim='CC BY 2.0',
                    requested=requested, images=[], failures=[], network_body_bytes=0,
                    network_body_budget_bytes=args.budget_mib * 2**20)
    downloader = BoundedDownload(manifest['network_body_budget_bytes'])
    try:
        manifest['state'] = 'downloading_metadata'
        save_json(root / 'status.json', manifest)
        candidates = split_metadata(downloader.get(METADATA_URL, 1024*1024, prefix=True), args.seed)
        manifest['candidate_counts'] = {k: len(v) for k, v in candidates.items()}
        save_json(root / 'candidate_sources.json', candidates)
        weights = downloader.get(WEIGHTS_URL, 6*2**20)
        (root / 'squeezenet1_1.pth').write_bytes(weights)
        manifest['feature_weights'] = dict(file='squeezenet1_1.pth', url=WEIGHTS_URL,
                                           bytes=len(weights), role='training_only_not_RTL')
        for split, count in requested.items():
            (root / split).mkdir()
            acquired = 0
            for source in candidates[split]:
                if acquired == count:
                    break
                image_id = source['ImageID']
                url = f'https://open-images-dataset.s3.amazonaws.com/validation/{image_id}.jpg'
                try:
                    data = downloader.get(url, 512*1024)
                    with Image.open(io.BytesIO(data)) as image:
                        size = list(image.size)
                        if image.format != 'JPEG' or min(size) < 128:
                            raise ValueError('not JPEG or too small')
                        image.verify()
                    relative = f'{split}/{image_id}.jpg'
                    (root / relative).write_bytes(data)
                    manifest['images'].append(dict(source, split=split, file=relative, size=size,
                                                   download_url=url, download_bytes=len(data)))
                    acquired += 1
                except (ValueError, OSError) as exc:
                    manifest['failures'].append(dict(ImageID=image_id, split=split, error=str(exc)))
                manifest.update(state='downloading_images', network_body_bytes=downloader.received,
                                counts={k: sum(r['split'] == k for r in manifest['images']) for k in requested})
                save_json(root / 'status.json', manifest)
                time.sleep(0.05)  # Sequential and deliberately modest connection rate.
            if acquired != count:
                raise RuntimeError(f'not enough usable {split} images: {acquired}/{count}')
        manifest.update(state='complete', network_body_bytes=downloader.received)
        validate_manifest(root, manifest)
        save_json(root / 'manifest.json', manifest)
        save_json(root / 'status.json', manifest)
        print('C36_DATASET_PREPARE_PASS', json.dumps(dict(counts=requested, bytes=downloader.received)))
    except Exception as exc:
        manifest.update(state='failed', error=repr(exc), network_body_bytes=downloader.received)
        save_json(root / 'status.json', manifest)
        raise


if __name__ == '__main__':
    main()
