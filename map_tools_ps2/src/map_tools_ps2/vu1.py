from __future__ import annotations

from .binary import Matrix4, Vec3, Vec4, transform_point4

VU1_TRANSFORM_MATRIX_ADDR = 0x348
VU1_TEXTURE_MATRIX_ADDR = 0x354
VU1_EXTRA_MATRIX_ADDR = 0x35C


def transform_vu1_position(vertex: Vec3, matrix: Matrix4) -> Vec4:
    return transform_point4(vertex, matrix)


def transform_vu1_positions(vertices: tuple[Vec3, ...], matrix: Matrix4) -> tuple[Vec4, ...]:
    return tuple(transform_vu1_position(vertex, matrix) for vertex in vertices)
