"""Reproducible source-only audit; a successful scan is NOT GTA validation."""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

from map_tools_ps2.chunks import parse_chunks
from map_tools_ps2.comp import load_bundle_bytes
from map_tools_ps2.source_physics import parse_source_physics


def audit(path: Path) -> dict:
    bundle = load_bundle_bytes(path)
    physics = parse_source_physics(parse_chunks(bundle), bundle)
    return dict(source=str(path.resolve()), sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                **physics.report(),
                binding_errors=dict(Counter(b.error for b in physics.bindings if b.error)),
                )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tracks', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    summary = []
    for family in (10, 20, 30, 40, 60):
        for variant in range(1, 7):
            track_id = family + variant
            row = audit(args.tracks / f'TRACKB{track_id}.LZC')
            (args.output / f'track{track_id}.json').write_text(json.dumps(row, indent=2), encoding='utf-8')
            item = dict(track=track_id, templates=len(row['templates']), bindings=len(row['bindings']),
                        errors=row['errors'], binding_errors=row['binding_errors'])
            summary.append(item)
            print(json.dumps(item), flush=True)
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
