from __future__ import annotations

from collections.abc import Iterable, Iterator
from typing import TypeVar


T = TypeVar("T")


def progress_iter(iterable: Iterable[T], *, total: int | None = None, desc: str = "", enabled: bool = False) -> Iterator[T]:
    if not enabled:
        yield from iterable
        return

    try:
        from tqdm import tqdm
    except ImportError:
        yield from iterable
        return

    yield from tqdm(iterable, total=total, desc=desc, unit="item")


def progress_byte_chunks(
    chunks: Iterable[bytes],
    *,
    total: int,
    desc: str = "",
    enabled: bool = False,
) -> Iterator[bytes]:
    if not enabled:
        yield from chunks
        return

    try:
        from tqdm import tqdm
    except ImportError:
        yield from chunks
        return

    with tqdm(total=total, desc=desc, unit="B", unit_scale=True, unit_divisor=1024) as bar:
        for chunk in chunks:
            yield chunk
            bar.update(len(chunk))
