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


@dataclass(frozen=True)
class Vec4:
    x: float
    y: float
    z: float
    w: float

    def __iter__(self) -> Iterable[float]:
        yield self.x
        yield self.y
        yield self.z
        yield self.w


Matrix4 = tuple[tuple[float, float, float, float], ...]


def compose_matrix4(left: Matrix4, right: Matrix4) -> Matrix4:
    return tuple(
        tuple(sum(left[row][inner] * right[inner][column] for inner in range(4)) for column in range(4))
        for row in range(4)
    )  # type: ignore[return-value]


def transform_point4(point: Vec3, matrix: Matrix4) -> Vec4:
    x, y, z = point.x, point.y, point.z
    return Vec4(
        x * matrix[0][0] + y * matrix[1][0] + z * matrix[2][0] + matrix[3][0],
        x * matrix[0][1] + y * matrix[1][1] + z * matrix[2][1] + matrix[3][1],
        x * matrix[0][2] + y * matrix[1][2] + z * matrix[2][2] + matrix[3][2],
        x * matrix[0][3] + y * matrix[1][3] + z * matrix[2][3] + matrix[3][3],
    )


def transform_point(point: Vec3, matrix: Matrix4) -> Vec3:
    transformed = transform_point4(point, matrix)
    return Vec3(transformed.x, transformed.y, transformed.z)


IDENTITY4: Matrix4 = (
    (1.0, 0.0, 0.0, 0.0),
    (0.0, 1.0, 0.0, 0.0),
    (0.0, 0.0, 1.0, 0.0),
    (0.0, 0.0, 0.0, 1.0),
)
