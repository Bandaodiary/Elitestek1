"""Fetch ONE official-example style teacher with a hard 8 MiB body budget.

The upstream package is ~25 MB. This reader requires HTTP byte ranges and
extracts only the chosen member; no full-package fallback, automatic retries,
arbitrary archive extraction, executable download, or large VGG download.
"""
import argparse
import io
import json
from pathlib import Path
import re
import urllib.request
import zipfile

ORIGIN = 'https://www.dropbox.com/s/lrvwfehqdcxoza8/saved_models.zip?dl=1'
OFFICIAL = 'https://github.com/pytorch/examples/tree/main/fast_neural_style'
RAW = 'https://raw.githubusercontent.com/pytorch/examples/main/'


class Budget:
    limit = 8 * 2**20

    def __init__(self):
        self.received = 0
        self.requests = []

    def read(self, response, maximum):
        if maximum < 0 or self.received + maximum > self.limit:
            raise ValueError('teacher download would exceed the 8 MiB total body budget')
        chunks = []
        remaining = maximum
        while remaining:
            data = response.read(min(65536, remaining))
            if not data:
                break
            self.received += len(data)
            chunks.append(data)
            remaining -= len(data)
        return b''.join(chunks)


class RangedZip(io.RawIOBase):
    def __init__(self, budget):
        self.budget = budget
        with urllib.request.urlopen(urllib.request.Request(ORIGIN, method='HEAD'), timeout=20) as response:
            self.size = int(response.headers['Content-Length'])
            self.url = response.geturl()
            if response.headers.get('Accept-Ranges') != 'bytes' or not 0 < self.size < 40 * 2**20:
                raise ValueError('official package is not the expected bounded range-capable archive')
        self.position = 0
        self.windows = []

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=0):
        position = offset + (self.position if whence == 1 else self.size if whence == 2 else 0)
        if whence not in (0, 1, 2) or not 0 <= position <= self.size:
            raise ValueError('invalid remote archive seek')
        self.position = position
        return position

    def read(self, amount=-1):
        amount = self.size - self.position if amount < 0 else min(amount, self.size - self.position)
        if not amount:
            return b''
        start, end = self.position, self.position + amount - 1
        for left, right, cached in self.windows:
            if left <= start and end <= right:
                self.position += amount
                return cached[start-left:end-left+1]
        # One tail window covers EOCD, optional ZIP64 locator and directory;
        # avoid many tiny requests to a temporary redirected Dropbox URL.
        left = min(start, max(0, self.size-65536))
        right = min(self.size-1, max(end, left+65535))
        count = right-left+1
        if self.budget.received + count > self.budget.limit:
            raise ValueError('range window exceeds remaining teacher budget')
        request = urllib.request.Request(ORIGIN, headers={'Range': f'bytes={left}-{right}', 'Accept-Encoding': 'identity'})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                if response.status != 206 or response.headers.get('Content-Range') != f'bytes {left}-{right}/{self.size}':
                    raise ValueError('server ignored the range; refusing full download')
                data = self.budget.read(response, count)
        except OSError as exc:
            # zipfile otherwise hides HTTP errors behind "not a zip file".
            raise RuntimeError('public teacher range unavailable: '+str(exc)) from exc
        if len(data) != count:
            raise ValueError('incomplete range response')
        self.windows.append((left, right, data))
        self.position += amount
        self.budget.requests.append(dict(start=left, end=right, body_bytes=len(data)))
        return data[start-left:end-left+1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--style', choices=('mosaic', 'candy', 'rain_princess', 'udnie'), default='mosaic')
    args = parser.parse_args()
    root = args.output.resolve()
    assets = Path(__file__).resolve().parents[1] / 'assets'
    if root.exists() or not root.is_relative_to(assets):
        raise ValueError('new case1/assets teacher directory required')
    root.mkdir(parents=True)
    budget = Budget()
    manifest = dict(state='preparing', official_example=OFFICIAL, upstream_archive=ORIGIN,
                    style=args.style, body_budget=budget.limit, FPGA_teacher_deployment=False,
                    trained_student_available=False, weights_redistribution_license_independently_verified=False)
    try:
        with RangedZip(budget) as remote, zipfile.ZipFile(remote) as archive:
            expected = args.style + '.pth'
            matches = [entry for entry in archive.infolist() if Path(entry.filename).name == expected]
            if len(matches) != 1 or not 0 < matches[0].file_size <= 8 * 2**20:
                raise ValueError('single bounded teacher checkpoint not found')
            entry = matches[0]
            manifest.update(archive_bytes=remote.size, member=entry.filename,
                            checkpoint_bytes=entry.file_size, compressed_member_bytes=entry.compress_size)
            data = archive.read(entry)
            if len(data) != entry.file_size:
                raise ValueError('teacher member length mismatch')
        # Constrained tensor-only loader; never unpickle an arbitrary module.
        import torch
        state = torch.load(io.BytesIO(data), map_location='cpu', weights_only=True)
        if not isinstance(state, dict) or not all(isinstance(k, str) and isinstance(v, torch.Tensor) for k, v in state.items()):
            raise ValueError('teacher is not a tensor state dictionary')
        if state['conv1.conv2d.weight'].shape != (32, 3, 9, 9) or state['deconv3.conv2d.weight'].shape != (3, 32, 9, 9):
            raise ValueError('wrong teacher architecture')
        (root / expected).write_bytes(data)
        # Archive source and license as data for review, not executable imports.
        for relative, destination in (
            ('LICENSE', 'UPSTREAM_LICENSE.txt'),
            ('fast_neural_style/neural_style/transformer_net.py', 'transformer_net.py.reference'),
            ('fast_neural_style/download_saved_models.py', 'download_saved_models.py.reference')):
            with urllib.request.urlopen(RAW + relative, timeout=20) as response:
                length = int(response.headers.get('Content-Length', '65536'))
                if length > 65536:
                    raise ValueError('unexpectedly large upstream reference')
                document = budget.read(response, length)
            (root / destination).write_bytes(document)
        manifest.update(state='complete', tensor_entries=len(state), checkpoint_file=expected,
                        checkpoint_loaded_weights_only=True, body_bytes_received=budget.received,
                        range_requests=budget.requests)
    except BaseException as exc:
        manifest.update(state='failed', error=repr(exc), body_bytes_received=budget.received,
                        range_requests=budget.requests)
        raise
    finally:
        (root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print('C36_STYLE_TEACHER_FETCHED ' + json.dumps({k: v for k, v in manifest.items() if k != 'range_requests'}, separators=(',', ':')))


if __name__ == '__main__':
    main()
