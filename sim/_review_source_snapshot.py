"""Parent-owned immutable source copies for reproducible independent builds.

Only copies sources into a dedicated test build directory. Never edits source
RTL, tool installations or parameter data. A rerun intentionally refreshes its
own snapshots before Icarus compilation; the resulting manifest identifies the
exact bytes tested even while an implementer continues editing elsewhere.
"""
from __future__ import annotations
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def freeze_sources(sources, build_dir):
    base = Path(build_dir).resolve() / 'parent_source_snapshot'
    base.mkdir(parents=True, exist_ok=True)
    copied = []
    manifest = {}
    for source in sources:
        original = Path(source).resolve()
        try:
            relative = original.relative_to(ROOT)
        except ValueError:
            # Test-only generated wrappers may live outside the repository.
            relative = Path('test_only_external') / original.name
        target = base / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        data = original.read_bytes()
        if str(relative) in manifest:
            raise ValueError('Duplicate source snapshot destination: ' + str(relative))
        target.write_bytes(data)
        manifest[str(relative)] = dict(original=str(original), snapshot=str(target),
                                       sha256=hashlib.sha256(data).hexdigest())
        copied.append(str(target))
    (base / 'sources.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    return copied
