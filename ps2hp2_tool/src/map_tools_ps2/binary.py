from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import Iterable


def u16le(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def u32le(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def f32le(data: bytes, offset: int) -> float:
    return struct.unpack_from("<f", data, offset)[0]


def unpack_f32s(data: bytes, offset: int, count: int) -> tuple[float, ...]:
    return struct.unpack_from("<" + "f" * count, data, offset)


def align(value: int, boundary: int) -> int:
    return (value + boundary - 1) & ~(boundary - 1)


@dataclass(frozen=True)
class Vec3:
    x: float
    y: float
    z: float

    def __iter__(self) -> Iterable[float]:
        yield self.x
        yield self.y
        yield self.z


Matrix4 = tuple[tuple[float, float, float, float], ...]


def transform_point(point: Vec3, matrix: Matrix4) -> Vec3:
    x, y, z = point.x, point.y, point.z
    return Vec3(
        x * matrix[0][0] + y * matrix[1][0] + z * matrix[2][0] + matrix[3][0],
        x * matrix[0][1] + y * matrix[1][1] + z * matrix[2][1] + matrix[3][1],
        x * matrix[0][2] + y * matrix[1][2] + z * matrix[2][2] + matrix[3][2],
    )


IDENTITY4: Matrix4 = (
    (1.0, 0.0, 0.0, 0.0),
    (0.0, 1.0, 0.0, 0.0),
    (0.0, 0.0, 1.0, 0.0),
    (0.0, 0.0, 0.0, 1.0),
)
