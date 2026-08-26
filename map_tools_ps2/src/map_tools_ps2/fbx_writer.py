from __future__ import annotations

import json
import shutil
import struct
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class FbxNode:
    name: str
    props: list[bytes] = field(default_factory=list)
    children: list["FbxNode"] = field(default_factory=list)


def _find_blender() -> str | None:
    found = shutil.which("blender") or shutil.which("blender.exe")
    if found:
        return found
    candidates = (
        Path(r"C:\Program Files\Blender Foundation\Blender 4.5\blender.exe"),
        Path(r"C:\Program Files\Blender Foundation\Blender 4.4\blender.exe"),
        Path(r"C:\Program Files\Blender Foundation\Blender 4.3\blender.exe"),
    )
    return next((str(p) for p in candidates if p.exists()), None)


def write_binary_fbx_with_blender(glb_path: Path, out_path: Path, texture_dir: Path) -> dict[str, object]:
    blender = _find_blender()
    if blender is None:
        raise RuntimeError("Blender CLI was not found; install Blender or use --fbx-backend python")
    script = Path(__file__).with_name("blender_export_fbx.py")
    texture_dir.mkdir(parents=True, exist_ok=True)
    command = [blender, "--background", "--factory-startup", "--python", str(script), "--", str(glb_path), str(out_path), str(texture_dir)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError("Blender FBX export failed:\n" + result.stdout[-4000:] + "\n" + result.stderr[-4000:])
    if not out_path.exists() or out_path.stat().st_size < 32:
        raise RuntimeError("Blender completed without creating a valid FBX file")
    return {"fbx_backend": "blender", "fbx_bytes": out_path.stat().st_size, "fbx_textures": len(list(texture_dir.glob("*.png")))}


def _s(v: str) -> bytes:
    b = v.encode("utf-8"); return b"S" + struct.pack("<I", len(b)) + b


def _i(v: int) -> bytes: return b"L" + struct.pack("<q", v)
def _d(v: float) -> bytes: return b"D" + struct.pack("<d", v)
def _b(v: bool) -> bytes: return b"C" + (b"\x01" if v else b"\x00")
def _ad(values: list[float]) -> bytes: return b"d" + struct.pack("<III", len(values), 0, len(values) * 8) + struct.pack("<" + "d" * len(values), *values)
def _ai(values: list[int]) -> bytes: return b"i" + struct.pack("<III", len(values), 0, len(values) * 4) + struct.pack("<" + "i" * len(values), *values)


def _encode(node: FbxNode, start: int, version: int = 7400) -> bytes:
    name = node.name.encode("utf-8")
    props = b"".join(node.props)
    header_len = 13 + len(name) + len(props)
    child_pos = start + header_len
    encoded_children: list[bytes] = []
    cursor = child_pos
    for child in node.children:
        encoded = _encode(child, cursor, version)
        encoded_children.append(encoded)
        cursor += len(encoded)
    child_bytes = b"".join(encoded_children)
    if node.children:
        child_bytes += b"\0" * 13
    end = start + header_len + len(child_bytes)
    if end >= 0xFFFFFFFF:
        raise ValueError("FBX 7.4 output exceeds 32-bit node offset limit")
    return struct.pack("<IIIB", end, len(node.props), len(props), len(name)) + name + props + child_bytes


def _size(node: FbxNode) -> int:
    props = sum(len(p) for p in node.props)
    child = sum(_size(c) for c in node.children)
    return 13 + len(node.name.encode("utf-8")) + props + child + (13 if node.children else 0)


def _prop70(name: str, value: float | int | str) -> FbxNode:
    if isinstance(value, str): return FbxNode("P", [_s(name), _s("KString"), _s(""), _s("A"), _s(value)])
    if isinstance(value, int): return FbxNode("P", [_s(name), _s("int"), _s("Integer"), _s("A"), _i(value)])
    return FbxNode("P", [_s(name), _s("double"), _s("Number"), _s("A"), _d(value)])


def _prop70_vec3(name: str, values: tuple[float, float, float]) -> FbxNode:
    return FbxNode("P", [_s(name), _s("Vector3D"), _s("Vector"), _s("A"), _d(values[0]), _d(values[1]), _d(values[2])])


def _load_glb(path: Path) -> tuple[dict[str, Any], bytes]:
    data = path.read_bytes()
    if data[:4] != b"glTF": raise ValueError("expected GLB input")
    json_len = struct.unpack_from("<I", data, 12)[0]
    state = json.loads(data[20:20 + json_len].decode("utf-8"))
    bin_pos = 20 + json_len + 8
    bin_len = struct.unpack_from("<I", data, 20 + json_len)[0]
    return state, data[bin_pos:bin_pos + bin_len]


def _read_accessor(state: dict[str, Any], binary: bytes, index: int) -> list[float] | list[int]:
    a = state["accessors"][index]; v = state["bufferViews"][a["bufferView"]]
    pos = v.get("byteOffset", 0) + a.get("byteOffset", 0); count = a["count"]
    if a["componentType"] == 5125: return list(struct.unpack_from("<" + "I" * count, binary, pos))
    width = {"VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
    return list(struct.unpack_from("<" + "f" * (count * width), binary, pos))


def write_binary_fbx_from_glb(glb_path: Path, out_path: Path, texture_dir: Path | None = None) -> dict[str, int]:
    state, binary = _load_glb(glb_path)
    texture_count = 0
    if texture_dir is not None:
        texture_dir.mkdir(parents=True, exist_ok=True)
        for image in state.get("images", []):
            if "bufferView" not in image:
                continue
            view = state["bufferViews"][image["bufferView"]]
            start = view.get("byteOffset", 0)
            payload = binary[start:start + view["byteLength"]]
            name = Path(image.get("name", f"texture_{texture_count:04d}.png")).stem + ".png"
            (texture_dir / name).write_bytes(payload)
            texture_count += 1
    objects = FbxNode("Objects")
    connections = FbxNode("Connections")
    definitions = FbxNode("Definitions", [_i(1)])
    geometry_ids: dict[int, int] = {}
    model_ids: dict[int, int] = {}
    next_id = 100000
    for mesh_index, mesh in enumerate(state.get("meshes", [])):
        gid = next_id; next_id += 1; geometry_ids[mesh_index] = gid
        vertices: list[float] = []; polygons: list[int] = []; uvs: list[float] = []
        vertex_offset = 0
        for primitive in mesh.get("primitives", []):
            pos = _read_accessor(state, binary, primitive["attributes"]["POSITION"]); idx = _read_accessor(state, binary, primitive["indices"])
            vertices.extend(pos)
            polygons.extend((int(i) + vertex_offset) if j == len(idx) - 1 else (int(i) + vertex_offset) for j, i in enumerate(idx))
            if "TEXCOORD_0" in primitive["attributes"]: uvs.extend(_read_accessor(state, binary, primitive["attributes"]["TEXCOORD_0"]))
            vertex_offset += len(pos) // 3
        mesh_name = mesh.get("name", f"Geometry_{mesh_index}")
        g = FbxNode("Geometry", [_i(gid), _s(mesh_name + "\x00\x01Geometry"), _s("Mesh")], [
            FbxNode("Vertices", [_ad(vertices)]), FbxNode("PolygonVertexIndex", [_ai([x if (i + 1) % 3 else -(x + 1) for i, x in enumerate(polygons)])]),
            FbxNode("LayerElementMaterial", [_i(0), _s("ByPolygon"), _s("IndexToDirect")], [FbxNode("Name", [_s("Material")]), FbxNode("Materials", [_ai([0] * (len(polygons) // 3))])]),
        ])
        objects.children.append(g)
    for node_index, node in enumerate(state.get("nodes", [])):
        if "mesh" not in node: continue
        mid = next_id; next_id += 1; model_ids[node_index] = mid
        props = FbxNode("Properties70", [], [_prop70_vec3("Lcl Translation", (0.0, 0.0, 0.0)), _prop70("ShadingModel", "Phong")])
        model_name = node.get("name", f"Model_{node_index}")
        model = FbxNode("Model", [_i(mid), _s(model_name + "\x00\x01Model"), _s("Mesh")], [props])
        if "matrix" in node: model.children.append(FbxNode("Transform", [_ad([float(x) for x in node["matrix"]])]))
        objects.children.append(model)
        connections.children.append(FbxNode("C", [_s("OO"), _i(geometry_ids[node["mesh"]]), _i(mid)]))
    root = FbxNode("Model", [_i(0), _s("Scene\x00\x01Model"), _s("Null")])
    objects.children.append(root)
    for mid in model_ids.values(): connections.children.append(FbxNode("C", [_s("OO"), _i(mid), _i(0)]))
    top = FbxNode("FBXHeaderExtension", [], [FbxNode("FBXVersion", [_i(7400)])])
    global_props = FbxNode("Properties70", [], [
        _prop70("UnitScaleFactor", 1.0),
        _prop70("OriginalUnitScaleFactor", 1.0),
        _prop70("UpAxis", 2), _prop70("UpAxisSign", 1),
        _prop70("FrontAxis", 1), _prop70("FrontAxisSign", 1),
        _prop70("CoordAxis", 0), _prop70("CoordAxisSign", 1),
    ])
    global_settings = FbxNode("GlobalSettings", [], [global_props])
    documents = FbxNode("Documents", [], [FbxNode("Count", [_i(1)]), FbxNode("Document", [_i(1), _s("Scene"), _s("")])])
    top_nodes = [top, global_settings, documents, definitions, objects, connections]
    payload_parts: list[bytes] = []
    cursor = 27
    for node in top_nodes:
        encoded = _encode(node, cursor)
        payload_parts.append(encoded)
        cursor += len(encoded)
    payload = b"".join(payload_parts) + b"\0" * 13
    header = b"Kaydara FBX Binary  \x00\x1a\x00" + struct.pack("<I", 7400)
    out_path.parent.mkdir(parents=True, exist_ok=True); out_path.write_bytes(header + payload)
    return {"fbx_geometries": len(geometry_ids), "fbx_models": len(model_ids), "fbx_textures": texture_count}
