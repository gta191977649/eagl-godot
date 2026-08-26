from __future__ import annotations

import json
import math
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .binary import Vec3, transform_point
from .glb_writer import (
    _dedupe_object_faces,
    _indices_for_block,
    _ps2_to_gltf_vertices,
    _pack_vif_colors,
    _pack_vec2,
    _pack_vec3,
)
from .model import MeshObject, Scene, transformed_block_vertices
from .material_alpha import decide_material_alpha
from .primitive_stream import primitive_stream_for_block
from .textures import TextureLibrary


@dataclass(frozen=True)
class OptPrimitive:
    positions: tuple[Vec3, ...]
    indices: tuple[int, ...]
    texcoords: tuple[tuple[float, float], ...]
    colors: tuple[int, ...]
    texture_hash: int | None
    render_flag: int | None


@dataclass(frozen=True)
class OptGeometry:
    key: str
    name: str
    primitives: tuple[OptPrimitive, ...]


@dataclass(frozen=True)
class OptNode:
    name: str
    geometry_key: str
    matrix: tuple[float, ...] | None = None


def _identity() -> tuple[float, ...]:
    return (1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0)


def _matrix_gltf(m: tuple[tuple[float, float, float, float], ...]) -> tuple[float, ...]:
    # B maps PS2 (x,y,z) to glTF (x,z,-y): M' = B M B^-1.
    b = ((1.0, 0.0, 0.0), (0.0, 0.0, 1.0), (0.0, -1.0, 0.0))
    # PS2 matrices in this project are row-vector matrices: translation is in
    # the last row. glTF uses column-vector matrices, so transpose first.
    a = tuple(tuple(float(m[c][r]) for c in range(3)) for r in range(3))
    t = tuple(float(m[3][r]) for r in range(3))
    out = [[0.0] * 4 for _ in range(4)]
    for r in range(3):
        for c in range(3):
            out[r][c] = sum(b[r][i] * a[i][j] * b[c][j] for i in range(3) for j in range(3))
        out[r][3] = sum(b[r][i] * t[i] for i in range(3))
    out[3][3] = 1.0
    return tuple(out[r][c] for c in range(4) for r in range(4))


def _cell(obj: MeshObject, size: float) -> tuple[int, int, int]:
    p = transform_point(obj.blocks[0].run.vertices[0], obj.transform) if obj.blocks and obj.blocks[0].run.vertices else Vec3(0, 0, 0)
    return (math.floor(p.x / size), math.floor(p.y / size), math.floor(p.z / size))


def _primitive(obj: MeshObject, block, bake_transform: bool) -> OptPrimitive | None:
    vertices = transformed_block_vertices(obj, block) if bake_transform else block.run.vertices
    gltf_vertices = _ps2_to_gltf_vertices(vertices)
    if len(gltf_vertices) < 3:
        return None
    indices = _indices_for_block(gltf_vertices, obj.name, block)
    if not indices:
        return None
    uv = tuple(block.run.texcoords) if len(block.run.texcoords) >= len(gltf_vertices) else ()
    colors = tuple(block.run.packed_values) if len(block.run.packed_values) >= len(gltf_vertices) else ()
    return OptPrimitive(gltf_vertices, tuple(indices), uv, colors, None, block.render_flag)


def build_optimized(scene: Scene, chunk_size: float = 300.0, instance_mode: str = "reuse") -> tuple[tuple[OptGeometry, ...], tuple[OptNode, ...], dict[str, Any]]:
    # Some scenery templates are referenced by 0x00034103 placement records
    # but are not listed in the first solid-pack template palette. Placement
    # names are therefore authoritative; otherwise they become stray static
    # meshes at the origin (for example MOUNTBKGS30_02_CHOP1).
    placement_names = {instance.object_name for instance in scene.scenery_instances}
    templates = {o.name: o for o in scene.objects if o.name in placement_names or o.chunk_offset in scene.scenery_template_offsets}
    static = [o for o in scene.objects if o.name not in placement_names and o.chunk_offset not in scene.scenery_template_offsets]
    geometries: dict[str, OptGeometry] = {}
    nodes: list[OptNode] = []
    static_groups: dict[tuple[tuple[int, int, int], tuple[int, ...]], list[MeshObject]] = {}
    for obj in static:
        mats = tuple(sorted(obj.texture_hashes))
        static_groups.setdefault((_cell(obj, chunk_size), mats), []).append(obj)

    def make_geometry(key: str, name: str, objects: list[MeshObject], bake: bool) -> None:
        by_texture: dict[tuple[int | None, int | None], list[OptPrimitive]] = {}
        for obj in objects:
            for block in obj.blocks:
                p = _primitive(obj, block, bake)
                if p is None:
                    continue
                tex = obj.texture_hashes[block.texture_index] if block.texture_index is not None and block.texture_index < len(obj.texture_hashes) else (obj.texture_hashes[0] if obj.texture_hashes else None)
                by_texture.setdefault((tex, p.render_flag), []).append(OptPrimitive(p.positions, p.indices, p.texcoords, p.colors, tex, p.render_flag))
        merged: list[OptPrimitive] = []
        for (tex, render_flag), parts in by_texture.items():
            positions: list[Vec3] = []
            indices: list[int] = []
            uvs: list[tuple[float, float]] = []
            colors: list[int] = []
            for p in parts:
                base = len(positions)
                positions.extend(p.positions)
                indices.extend(i + base for i in p.indices)
                if p.texcoords:
                    uvs.extend(p.texcoords)
                if p.colors:
                    colors.extend(p.colors)
            merged.append(OptPrimitive(tuple(positions), tuple(indices), tuple(uvs), tuple(colors), tex, render_flag))
        geometries[key] = OptGeometry(key, name, tuple(merged))

    for index, (group, objects) in enumerate(static_groups.items()):
        key = f"static_{index:06d}"
        make_geometry(key, key, objects, True)
        if geometries[key].primitives:
            nodes.append(OptNode(key, key))

    instance_count = 0
    if instance_mode == "reuse":
        for name, obj in templates.items():
            key = f"template_{obj.name_hash if obj.name_hash is not None else name}"
            # Match the original placement path: scenery template vertices
            # are local and receive only the recorded instance transform.
            make_geometry(key, obj.name, [obj], False)
        for index, instance in enumerate(scene.scenery_instances):
            obj = templates.get(instance.object_name)
            if obj is None:
                continue
            key = f"template_{obj.name_hash if obj.name_hash is not None else obj.name}"
            if key in geometries and geometries[key].primitives:
                nodes.append(OptNode(f"{instance.object_name}_inst_{index:05d}", key, _matrix_gltf(instance.transform)))
                instance_count += 1
    else:
        for index, instance in enumerate(scene.scenery_instances):
            obj = templates.get(instance.object_name)
            if obj is None:
                continue
            placed = MeshObject(obj.name, obj.chunk_offset, instance.transform, obj.blocks, obj.texture_hashes, obj.name_hash)
            key = f"expanded_{index:06d}"
            make_geometry(key, key, [placed], True)
            if geometries[key].primitives:
                nodes.append(OptNode(key, key))
                instance_count += 1

    source_triangles = sum(len(_indices_for_block(_ps2_to_gltf_vertices(transformed_block_vertices(o, b)), o.name, b)) // 3 for o in scene.objects for b in o.blocks)
    output_triangles = sum(len(p.indices) // 3 for g in geometries.values() for p in g.primitives)
    report = {
        "source_objects": len(scene.objects),
        "static_source_objects": len(static),
        "optimized_geometries": len(geometries),
        "output_nodes": len(nodes),
        "template_geometries": sum(1 for k in geometries if k.startswith("template_")),
        "placement_instances": instance_count,
        "source_triangles": source_triangles,
        "output_triangles": output_triangles,
        "geometry_reuse": instance_count,
        "chunk_size": chunk_size,
        "instance_mode": instance_mode,
    }
    return tuple(geometries.values()), tuple(nodes), report


def write_optimized_glb(geometries: tuple[OptGeometry, ...], nodes: tuple[OptNode, ...], textures: TextureLibrary, out_path: Path, vertex_colors: str = "always") -> None:
    binary = bytearray()
    views: list[dict[str, Any]] = []
    accessors: list[dict[str, Any]] = []
    materials: list[dict[str, Any]] = [{"name": "default", "pbrMetallicRoughness": {"baseColorFactor": [0.8, 0.8, 0.8, 1], "roughnessFactor": 1}, "extensions": {"KHR_materials_unlit": {}}}]
    images: list[dict[str, Any]] = []
    gltf_textures: list[dict[str, Any]] = []
    mat_cache: dict[tuple[int | None, str], int] = {(None, "OPAQUE"): 0}
    texture_usage: dict[int, set[int | None]] = {}
    for geometry in geometries:
        for primitive in geometry.primitives:
            if primitive.texture_hash is not None:
                texture_usage.setdefault(primitive.texture_hash, set()).add(primitive.render_flag)

    def add(data: bytes, target: int | None = None) -> int:
        while len(binary) % 4: binary.append(0)
        off = len(binary); binary.extend(data)
        v = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if target is not None: v["target"] = target
        views.append(v); return len(views) - 1

    def acc(data: bytes, typ: str, count: int, comp: int = 5126, target: int | None = None) -> int:
        a = {"bufferView": add(data, target), "componentType": comp, "count": count, "type": typ}
        accessors.append(a); return len(accessors) - 1

    def mat(tex: int | None, render_flag: int | None) -> int:
        t = textures.get(tex) if tex is not None else None
        if t is None: return 0
        decision = decide_material_alpha(t, render_flag, texture_usage.get(tex, ()))
        key = (tex, decision.mode)
        if key in mat_cache: return mat_cache[key]
        iv = add(t.png); image = len(images); images.append({"name": t.name, "bufferView": iv, "mimeType": "image/png"})
        ti = len(gltf_textures); gltf_textures.append({"sampler": 0, "source": image, "name": t.name})
        value = {"name": t.name, "pbrMetallicRoughness": {"baseColorTexture": {"index": ti}, "roughnessFactor": 1}, "extensions": {"KHR_materials_unlit": {}}}
        if decision.mode != "OPAQUE": value["alphaMode"] = decision.mode
        if decision.mode == "MASK": value["alphaCutoff"] = decision.cutoff if decision.cutoff is not None else 0.5
        value["extras"] = {"ps2AlphaReason": decision.reason, "ps2RenderFlag": render_flag or 0}
        materials.append(value); mat_cache[key] = len(materials) - 1; return len(materials) - 1

    mesh_json: list[dict[str, Any]] = []
    mesh_index = {g.key: i for i, g in enumerate(geometries)}
    for g in geometries:
        prims = []
        for p in g.primitives:
            attrs = {"POSITION": acc(_pack_vec3(p.positions), "VEC3", len(p.positions), target=34962)}
            if p.texcoords: attrs["TEXCOORD_0"] = acc(_pack_vec2(p.texcoords), "VEC2", len(p.texcoords), target=34962)
            if p.colors and vertex_colors != "off": attrs["COLOR_0"] = acc(_pack_vif_colors(p.colors), "VEC4", len(p.colors), target=34962)
            ib = struct.pack("<" + "I" * len(p.indices), *p.indices)
            prims.append({"attributes": attrs, "indices": acc(ib, "SCALAR", len(p.indices), 5125, 34963), "material": mat(p.texture_hash, p.render_flag), "mode": 4})
        mesh_json.append({"name": g.name, "primitives": prims})
    gltf_nodes = []
    for n in nodes:
        value = {"name": n.name, "mesh": mesh_index[n.geometry_key]}
        if n.matrix is not None and n.matrix != _identity(): value["matrix"] = list(n.matrix)
        gltf_nodes.append(value)
    state = {"asset": {"version": "2.0", "generator": "map_tools_ps2 optimized exporter"}, "extensionsUsed": ["KHR_materials_unlit"], "scene": 0, "scenes": [{"nodes": list(range(len(gltf_nodes)))}], "nodes": gltf_nodes, "meshes": mesh_json, "buffers": [{"byteLength": len(binary)}], "bufferViews": views, "accessors": accessors, "materials": materials, "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}], "textures": gltf_textures, "images": images}
    js = json.dumps(state, separators=(",", ":")).encode(); js += b" " * ((4 - len(js) % 4) % 4)
    while len(binary) % 4: binary.append(0)
    total = 12 + 8 + len(js) + 8 + len(binary)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("wb") as fh:
        fh.write(struct.pack("<III", 0x46546C67, 2, total)); fh.write(struct.pack("<I4s", len(js), b"JSON")); fh.write(js); fh.write(struct.pack("<I4s", len(binary), b"BIN\0")); fh.write(binary)
