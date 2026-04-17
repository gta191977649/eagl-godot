from __future__ import annotations

from typing import Literal

PrimitiveMode = Literal["strip", "fan", "triangles", "quads", "unknown"]


def strip_indices(start_index: int, count: int) -> list[int]:
    indices: list[int] = []
    for i in range(count - 2):
        a = start_index + i
        b = start_index + i + 1
        c = start_index + i + 2
        face = (a, c, b) if (start_index + i) & 1 else (a, b, c)
        if len({face[0], face[1], face[2]}) == 3:
            indices.extend(face)
    return indices


def fan_indices(count: int) -> list[int]:
    indices: list[int] = []
    for index in range(1, count - 1):
        indices.extend((0, index, index + 1))
    return indices


def triangle_list_indices(count: int) -> list[int]:
    indices: list[int] = []
    for start_index in range(0, count - (count % 3), 3):
        indices.extend((start_index, start_index + 1, start_index + 2))
    return indices


def quad_batch_indices(count: int) -> list[int]:
    indices: list[int] = []
    for start_index in range(0, count - (count % 4), 4):
        indices.extend((start_index, start_index + 1, start_index + 2))
        indices.extend((start_index + 1, start_index + 3, start_index + 2))
    return indices


def indices_for_primitive(mode: PrimitiveMode, count: int) -> list[int] | None:
    if mode == "strip":
        return strip_indices(0, count)
    if mode == "fan":
        return fan_indices(count)
    if mode == "triangles":
        return triangle_list_indices(count)
    if mode == "quads":
        return quad_batch_indices(count)
    return None
