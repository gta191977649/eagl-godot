from __future__ import annotations

import json
import struct
from pathlib import Path
from typing import Any

from .model import Scene


def write_ps2mesh_debug(scene: Scene, json_path: Path, bin_path: Path | None = None) -> Path:
    if bin_path is None:
        bin_path = json_path.with_suffix(".bin")

    payload = bytearray()
    objects: list[dict[str, Any]] = []
    for object_index, obj in enumerate(scene.objects):
        blocks: list[dict[str, Any]] = []
        for block_index, block in enumerate(obj.blocks):
            vertex_view = _append_vec3(payload, block.run.vertices)
            texcoord_view = _append_vec2(payload, block.run.texcoords)
            packed_view = _append_u32(payload, block.run.packed_values)
            blocks.append(
                {
                    "block_index": block_index,
                    "primitive_mode": block.primitive_mode,
                    "expected_face_count": block.expected_face_count,
                    "topology_code": block.topology_code,
                    "texture_index": block.texture_index,
                    "render_flag": block.render_flag,
                    "source_offset": block.source_offset,
                    "source_qword_size": block.source_qword_size,
                    "vertex_count": len(block.run.vertices),
                    "texcoord_count": len(block.run.texcoords),
                    "packed_count": len(block.run.packed_values),
                    "vif_header": list(block.run.header) if block.run.header is not None else None,
                    "vertices": vertex_view,
                    "texcoords": texcoord_view,
                    "packed_values": packed_view,
                }
            )
        objects.append(
            {
                "object_index": object_index,
                "name": obj.name,
                "chunk_offset": obj.chunk_offset,
                "transform": [list(row) for row in obj.transform],
                "texture_hashes": list(obj.texture_hashes),
                "blocks": blocks,
            }
        )

    document = {
        "asset": {
            "version": 1,
            "generator": "map_tools_ps2 ps2mesh debug writer",
            "binary": bin_path.name,
        },
        "scene": {
            "object_count": len(scene.objects),
            "vertex_count": scene.vertex_count,
            "objects": objects,
        },
    }

    json_path.parent.mkdir(parents=True, exist_ok=True)
    bin_path.parent.mkdir(parents=True, exist_ok=True)
    bin_path.write_bytes(bytes(payload))
    json_path.write_text(json.dumps(document, separators=(",", ":"), indent=2), encoding="utf-8")
    return bin_path


def _append_vec3(payload: bytearray, values) -> dict[str, Any]:
    offset = _align_payload(payload)
    for value in values:
        payload.extend(struct.pack("<fff", value.x, value.y, value.z))
    return _view(offset, len(payload) - offset, len(values), "VEC3", "f32le")


def _append_vec2(payload: bytearray, values) -> dict[str, Any]:
    offset = _align_payload(payload)
    for u, v in values:
        payload.extend(struct.pack("<ff", u, v))
    return _view(offset, len(payload) - offset, len(values), "VEC2", "f32le")


def _append_u32(payload: bytearray, values) -> dict[str, Any]:
    offset = _align_payload(payload)
    for value in values:
        payload.extend(struct.pack("<I", value))
    return _view(offset, len(payload) - offset, len(values), "SCALAR", "u32le")


def _align_payload(payload: bytearray) -> int:
    while len(payload) % 4:
        payload.append(0)
    return len(payload)


def _view(offset: int, byte_length: int, count: int, value_type: str, component_type: str) -> dict[str, Any]:
    return {
        "byte_offset": offset,
        "byte_length": byte_length,
        "count": count,
        "type": value_type,
        "component_type": component_type,
    }
