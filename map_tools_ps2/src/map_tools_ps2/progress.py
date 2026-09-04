from __future__ import annotations

from collections.abc import Iterable, Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from typing import Any, Callable
from typing import TypeVar


T = TypeVar("T")

ProgressCallback = Callable[[str, int, int | None, Any | None], None]
_callback: ContextVar[ProgressCallback | None] = ContextVar("map_tools_ps2_progress_callback", default=None)


@contextmanager
def progress_context(callback: ProgressCallback | None):
    token = _callback.set(callback)
    try:
        yield
    finally:
        _callback.reset(token)


def report_progress(stage: str, current: int, total: int | None = None, item: Any | None = None) -> None:
    callback = _callback.get()
    if callback is not None:
        callback(stage, current, total, item)


def progress_iter(iterable: Iterable[T], *, total: int | None = None, desc: str = "", enabled: bool = False) -> Iterator[T]:
    callback = _callback.get()
    if not enabled:
        for index, item in enumerate(iterable, 1):
            report_progress(desc, index, total, item)
            yield item
        return

    try:
        from tqdm import tqdm
    except ImportError:
        yield from iterable
        return

    for index, item in enumerate(tqdm(iterable, total=total, desc=desc, unit="item"), 1):
        if callback is not None:
            callback(desc, index, total, item)
        yield item


def progress_byte_chunks(
    chunks: Iterable[bytes],
    *,
    total: int,
    desc: str = "",
    enabled: bool = False,
) -> Iterator[bytes]:
    if not enabled:
        completed = 0
        for chunk in chunks:
            completed += len(chunk)
            report_progress(desc, completed, total, None)
            yield chunk
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
            report_progress(desc, bar.n, total, None)


@contextmanager
def cli_progress_context(enabled: bool = True):
    """Render report_progress() updates as tqdm bars for terminal runs.

    Without this the CLI silently drops every progress report, so long exports
    look like they have hung.

    An embedder that already installed a callback keeps it: the GUI calls the
    CLI entry point directly with its output redirected, so taking the callback
    over would freeze its progress bar and draw tqdm's escape codes into its
    log pane instead.
    """
    if not enabled or _callback.get() is not None:
        yield
        return
    try:
        from tqdm import tqdm
    except ImportError:
        yield
        return

    state: dict[str, Any] = {"bar": None, "stage": None}

    def close() -> None:
        if state["bar"] is not None:
            state["bar"].close()
        state["bar"] = None
        state["stage"] = None

    def callback(stage: str, current: int, total: int | None, item: Any | None) -> None:
        if stage != state["stage"]:
            close()
            state["stage"] = stage
            state["bar"] = tqdm(total=total, desc=stage, unit="item", disable=None)
        bar = state["bar"]
        if bar is None:
            return
        if total is not None and bar.total != total:
            bar.total = total
        # Stages report an absolute position; tqdm counts increments. A stage
        # that restarts its counter would otherwise stall the bar forever, so
        # rewind instead of clamping the difference to zero.
        if current < bar.n:
            bar.reset(total=bar.total)
        bar.update(current - bar.n)
        if item is not None:
            label = getattr(item, "name", None) or str(item)
            bar.set_postfix_str(label[:40], refresh=False)

    try:
        with progress_context(callback):
            yield
    finally:
        close()
