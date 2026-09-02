from __future__ import annotations

import importlib
import json
import math
import re
import sys
from collections import Counter
from pathlib import Path

import bpy

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from map_tools_ps2.mta_txd import build_dxt_mip_chain, dxt_raster_format_flags, mip_dimensions


def _arguments() -> tuple[Path, Path, Path | None]:
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if len(args) < 2:
        raise SystemExit("usage: blender --background --python blender_export_mta.py -- MANIFEST OUT_DIR [DRAGONFF_PATH]")
    return Path(args[0]), Path(args[1]), Path(args[2]) if len(args) > 2 and args[2] else None


def _load_dragonff(path: Path | None):
    candidates = []
    if path is not None:
        if path.name.lower() == "dragonff":
            sys.path.insert(0, str(path.parent))
            candidates.append("dragonff")
        else:
            sys.path.insert(0, str(path))
    candidates.extend(("bl_ext.blender_org.dragonff", "dragonff"))
    errors = []
    for name in candidates:
        try:
            module = importlib.import_module(name)
            try:
                module.register()
            except Exception as exc:
                if "already registered" not in str(exc).lower():
                    errors.append(f"{name}.register: {exc}")
            return (
                importlib.import_module(f"{name}.ops.dff_exporter"),
                importlib.import_module(f"{name}.ops.txd_exporter"),
                importlib.import_module(f"{name}.ops.col_exporter"),
                importlib.import_module(f"{name}.ops.state"),
            )
        except Exception as exc:
            errors.append(f"{name}: {exc}")
    raise RuntimeError("DragonFF could not be loaded: " + "; ".join(errors))


def _clear_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for collection in tuple(bpy.data.collections):
        bpy.data.collections.remove(collection)


def _load_images(manifest: dict, root: Path) -> dict[str, bpy.types.Image]:
    images = {}
    for texture in manifest["textures"]:
        image = bpy.data.images.load(str(root / texture["file"]), check_existing=False)
        image.name = texture["name"]
        image.colorspace_settings.name = "sRGB"
        images[texture["name"]] = image
    return images


def _visual_material(value: dict, images: dict[str, bpy.types.Image]) -> bpy.types.Material:
    material = bpy.data.materials.new(f"mat_{value.get('texture_name') or 'default'}")
    material.use_nodes = True
    material.diffuse_color = (1.0, 1.0, 1.0, 1.0)
    nodes = material.node_tree.nodes
    principled = next((node for node in nodes if node.type == "BSDF_PRINCIPLED"), None)
    if principled is not None:
        principled.inputs["Base Color"].default_value = (1.0, 1.0, 1.0, 1.0)
        principled.inputs["Roughness"].default_value = 1.0
    texture_name = value.get("texture_name")
    if texture_name and texture_name in images and principled is not None:
        image_node = nodes.new("ShaderNodeTexImage")
        image_node.image = images[texture_name]
        image_node.label = texture_name
        material.node_tree.links.new(image_node.outputs["Color"], principled.inputs["Base Color"])
        material.node_tree.links.new(image_node.outputs["Alpha"], principled.inputs["Alpha"])
    if value.get("alpha") and texture_name is None:
        material.diffuse_color = (1.0, 1.0, 1.0, 0.0)
        if principled is not None:
            principled.inputs["Base Color"].default_value = (1.0, 1.0, 1.0, 0.0)
            principled.inputs["Alpha"].default_value = 0.0
    return material


def _mesh_object(model: dict, materials: list[bpy.types.Material]) -> bpy.types.Object:
    mesh = bpy.data.meshes.new(model["model_id"])
    mesh.from_pydata(model["vertices"], [], model["faces"])
    mesh.update()
    for material in materials:
        mesh.materials.append(material)
    for polygon, material_index in zip(mesh.polygons, model["face_materials"]):
        polygon.material_index = material_index
        polygon.use_smooth = True
    if model["uvs"]:
        uv_layer = mesh.uv_layers.new(name="UVMap")
        for polygon in mesh.polygons:
            for vertex_index, loop_index in zip(polygon.vertices, polygon.loop_indices):
                uv_layer.data[loop_index].uv = model["uvs"][vertex_index]
    if model["colors"]:
        color_layer = mesh.color_attributes.new(name="Day", type="BYTE_COLOR", domain="CORNER")
        for polygon in mesh.polygons:
            for vertex_index, loop_index in zip(polygon.vertices, polygon.loop_indices):
                rgba = model["colors"][vertex_index]
                # Store source bytes through Blender's explicit sRGB API.
                # DragonFF converts the linear view back to sRGB on export.
                color_layer.data[loop_index].color_srgb = tuple(value / 255.0 for value in rgba)
    obj = bpy.data.objects.new(model["model_id"], mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.dff.type = "OBJ"
    obj.dff.uv_map1 = bool(model["uvs"])
    obj.dff.uv_map2 = False
    obj.dff.day_cols = bool(model["colors"])
    obj.dff.night_cols = False
    obj.dff.export_frame_name = True
    return obj


def _weld_model_for_lod(model: dict) -> dict:
    """Index identical position/UV/prelight/material corners before Decimate."""
    vertices, uvs, colors, faces, face_materials = [], [], [], [], []
    lookup = {}
    for face, material_index in zip(model["faces"], model["face_materials"]):
        welded_face = []
        for source_index in face:
            position = tuple(float(value) for value in model["vertices"][source_index])
            uv = tuple(float(value) for value in model["uvs"][source_index]) if model["uvs"] else (0.0, 0.0)
            color = tuple(int(value) for value in model["colors"][source_index]) if model["colors"] else (255, 255, 255, 255)
            key = (tuple(round(value, 6) for value in position), tuple(round(value, 6) for value in uv), color, material_index)
            index = lookup.get(key)
            if index is None:
                index = lookup[key] = len(vertices)
                vertices.append(position)
                uvs.append(uv)
                colors.append(color)
            welded_face.append(index)
        if len(set(welded_face)) == 3:
            faces.append(tuple(welded_face))
            face_materials.append(material_index)
    return {
        **model,
        "vertices": vertices,
        "uvs": uvs if model["uvs"] else [],
        "colors": colors if model["colors"] else [],
        "faces": faces,
        "face_materials": face_materials,
    }


def _mesh_metrics(vertices, faces) -> dict:
    if not vertices or not faces:
        return {"bounds": ((0, 0, 0), (0, 0, 0)), "area": 0.0, "coverage": [0.0, 0.0, 0.0]}
    minimum = tuple(min(vertex[axis] for vertex in vertices) for axis in range(3))
    maximum = tuple(max(vertex[axis] for vertex in vertices) for axis in range(3))
    area = 0.0
    for face in faces:
        a, b, c = (vertices[index] for index in face)
        ab = tuple(b[axis] - a[axis] for axis in range(3))
        ac = tuple(c[axis] - a[axis] for axis in range(3))
        cross = (
            ab[1] * ac[2] - ab[2] * ac[1],
            ab[2] * ac[0] - ab[0] * ac[2],
            ab[0] * ac[1] - ab[1] * ac[0],
        )
        area += math.sqrt(sum(value * value for value in cross)) * 0.5
    coverage = []
    for dropped_axis in range(3):
        axes = [axis for axis in range(3) if axis != dropped_axis]
        occupied = set()
        spans = [max(maximum[axis] - minimum[axis], 1e-9) for axis in axes]
        for face in faces:
            projected = [
                tuple((vertices[index][axis] - minimum[axis]) / spans[i] * 39.0 for i, axis in enumerate(axes))
                for index in face
            ]
            min_x = max(0, math.floor(min(point[0] for point in projected)))
            max_x = min(39, math.ceil(max(point[0] for point in projected)))
            min_y = max(0, math.floor(min(point[1] for point in projected)))
            max_y = min(39, math.ceil(max(point[1] for point in projected)))
            ax, ay = projected[0]
            bx, by = projected[1]
            cx, cy = projected[2]
            denominator = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            if abs(denominator) < 1e-9:
                continue
            for x in range(min_x, max_x + 1):
                for y in range(min_y, max_y + 1):
                    px, py = x + 0.5, y + 0.5
                    first = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / denominator
                    second = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / denominator
                    third = 1.0 - first - second
                    if min(first, second, third) >= -1e-6:
                        occupied.add((x, y))
        coverage.append(len(occupied) / 1600.0)
    return {"bounds": (minimum, maximum), "area": area, "coverage": coverage}


def _object_to_corner_model(obj: bpy.types.Object, template: dict) -> dict:
    mesh = obj.data
    uv_layer = mesh.uv_layers.active
    color_layer = mesh.color_attributes.get("Day")
    vertices, uvs, colors, faces, face_materials = [], [], [], [], []
    for polygon in mesh.polygons:
        loop_indices = list(polygon.loop_indices)
        if len(loop_indices) < 3:
            continue
        polygon_corner_indices = []
        for loop_index in loop_indices:
            loop = mesh.loops[loop_index]
            vertices.append(tuple(float(value) for value in mesh.vertices[loop.vertex_index].co))
            uvs.append(tuple(float(value) for value in uv_layer.data[loop_index].uv) if uv_layer else (0.0, 0.0))
            if color_layer:
                rgba = color_layer.data[loop_index].color_srgb
                colors.append(tuple(max(0, min(255, round(value * 255.0))) for value in rgba))
            else:
                colors.append((255, 255, 255, 255))
            polygon_corner_indices.append(len(vertices) - 1)
        for index in range(1, len(polygon_corner_indices) - 1):
            faces.append((polygon_corner_indices[0], polygon_corner_indices[index], polygon_corner_indices[index + 1]))
            face_materials.append(int(polygon.material_index))
    return {
        **template,
        "vertices": vertices,
        "uvs": uvs if template["uvs"] else [],
        "colors": colors if template["colors"] else [],
        "faces": faces,
        "face_materials": face_materials,
        "collision_vertices": [],
        "collision_faces": [],
        "collision_materials": [],
        "collision_kind": "bounds",
    }


def _build_lod_model(source: dict, target: dict, materials: list[bpy.types.Material]) -> tuple[dict | None, dict]:
    welded = _weld_model_for_lod(source)
    source_metrics = _mesh_metrics(welded["vertices"], welded["faces"])
    requested = float(target.get("lod_target_ratio", 0.12))
    ratios = []
    for ratio in (requested, 0.20, 0.32, 0.48, 0.65):
        if ratio not in ratios:
            ratios.append(ratio)
    attempts = []
    for ratio in ratios:
        obj = _mesh_object({**welded, "model_id": target["model_id"]}, materials)
        edge_uses = {}
        for face in welded["faces"]:
            for first, second in ((face[0], face[1]), (face[1], face[2]), (face[2], face[0])):
                key = tuple(sorted((first, second)))
                edge_uses[key] = edge_uses.get(key, 0) + 1
        for edge in obj.data.edges:
            if edge_uses.get(tuple(sorted(edge.vertices)), 0) == 1:
                edge.use_seam = True
        modifier = obj.modifiers.new("Adaptive LOD", "DECIMATE")
        modifier.decimate_type = "COLLAPSE"
        modifier.ratio = ratio
        modifier.use_collapse_triangulate = True
        if hasattr(modifier, "delimit"):
            modifier.delimit = {"MATERIAL", "UV", "SEAM", "SHARP"}
        bpy.context.view_layer.objects.active = obj
        obj.select_set(True)
        bpy.ops.object.modifier_apply(modifier=modifier.name)
        candidate = _object_to_corner_model(obj, target)
        metrics = _mesh_metrics(candidate["vertices"], candidate["faces"])
        source_min, source_max = source_metrics["bounds"]
        candidate_min, candidate_max = metrics["bounds"]
        extent = [max(source_max[axis] - source_min[axis], 1e-6) for axis in range(3)]
        bounds_error = max(
            abs(candidate_min[axis] - source_min[axis]) / extent[axis] for axis in range(3)
        )
        bounds_error = max(bounds_error, max(abs(candidate_max[axis] - source_max[axis]) / extent[axis] for axis in range(3)))
        area_ratio = metrics["area"] / source_metrics["area"] if source_metrics["area"] else 1.0
        coverage_ratio = [
            metrics["coverage"][axis] / source_metrics["coverage"][axis]
            if source_metrics["coverage"][axis] else 1.0
            for axis in range(3)
        ]
        finite_attributes = all(math.isfinite(value) for vertex in candidate["vertices"] for value in vertex)
        finite_attributes = finite_attributes and all(math.isfinite(value) for uv in candidate["uvs"] for value in uv)
        valid = (
            bool(candidate["faces"])
            and len(candidate["vertices"]) <= 65535
            and bounds_error <= 0.005
            and 0.55 <= area_ratio <= 1.35
            and min(coverage_ratio) >= 0.86
            and finite_attributes
        )
        attempts.append({
            "ratio": ratio, "vertices": len(candidate["vertices"]), "triangles": len(candidate["faces"]),
            "bounds_error": bounds_error, "area_ratio": area_ratio, "projection_coverage": coverage_ratio,
            "valid": valid,
        })
        visual_mesh = obj.data
        bpy.data.objects.remove(obj, do_unlink=True)
        bpy.data.meshes.remove(visual_mesh)
        if valid:
            return candidate, {"status": "generated", "ratio": ratio, "attempts": attempts}
    if str(target.get("lod_mode", "auto")) == "required":
        raise RuntimeError(f"no valid LOD candidate for {source['model_id']}: {attempts}")
    return None, {"status": "skipped", "ratio": None, "attempts": attempts}


def _collision_collection(model: dict) -> tuple[bpy.types.Collection, bpy.types.Object, bpy.types.Mesh] | None:
    if not model["collision_faces"]:
        return None
    collection = bpy.data.collections.new(model["model_id"])
    bpy.context.scene.collection.children.link(collection)
    collection.dff.type = "CMN"
    collection.dff.auto_bounds = True
    mesh = bpy.data.meshes.new(model["model_id"] + "_col")
    mesh.from_pydata(model["collision_vertices"], [], model["collision_faces"])
    mesh.update()
    surface_indices = sorted(set(model["collision_materials"] or [0]))
    material_slots = {}
    for surface in surface_indices:
        material = bpy.data.materials.new(f"col_{surface}")
        material.dff.col_mat_index = max(0, min(255, int(surface)))
        material.dff.col_day_light = 15
        material.dff.col_night_light = 15
        material_slots[surface] = len(mesh.materials)
        mesh.materials.append(material)
    for polygon, surface in zip(mesh.polygons, model["collision_materials"]):
        polygon.material_index = material_slots[surface]
    obj = bpy.data.objects.new(model["model_id"] + "_col", mesh)
    collection.objects.link(obj)
    obj.dff.type = "COL"
    return collection, obj, mesh


def _export_bounds_only_col(module, model: dict, path: Path) -> None:
    """Write a COL3 containing DFF-local bounds and no collision primitives."""
    vertices = model["vertices"]
    if not vertices:
        raise RuntimeError(f"cannot build bounds-only COL for empty model {model['model_id']}")
    minimum = tuple(min(float(vertex[axis]) for vertex in vertices) for axis in range(3))
    maximum = tuple(max(float(vertex[axis]) for vertex in vertices) for axis in range(3))
    center = tuple((minimum[axis] + maximum[axis]) * 0.5 for axis in range(3))
    radius = math.sqrt(sum((maximum[axis] - minimum[axis]) ** 2 for axis in range(3))) * 0.5

    library = module.col
    library.Sections.init_sections(3)
    value = library.ColModel()
    value.version = 3
    value.model_name = model["model_id"]
    value.model_id = 0
    value.bounds = library.TBounds(
        min=library.TVector(*minimum),
        max=library.TVector(*maximum),
        center=library.TVector(*center),
        radius=radius,
    )
    library.coll(value).write_file(str(path))


def _export_dff(module, state_module, obj: bpy.types.Object, path: Path) -> None:
    exporter = module.dff_exporter
    exporter.selected = False
    exporter.export_frame_names = True
    exporter.exclude_geo_faces = False
    exporter.mass_export = False
    exporter.preserve_positions = False
    exporter.preserve_rotations = False
    exporter.path = str(path.parent)
    exporter.file_name = str(path)
    exporter.version = 0x36003
    exporter.export_coll = False
    exporter.coll_ext_type = 0
    exporter.apply_coll_trans = True
    exporter.from_outliner = False
    exporter.frame_objects = {}
    state_module.State.update_scene()
    exporter.export_objects([obj])


def _texture_alpha_mode(texture: dict) -> str:
    mode = str(texture.get("alpha_mode") or "OPAQUE").upper()
    if mode not in {"OPAQUE", "MASK", "BLEND"}:
        raise ValueError(f"unsupported texture alpha mode for {texture.get('name')}: {mode}")
    return mode


def _configure_native_dxt(module, native, mode: str, alpha_cutoff: float | None) -> None:
    native.pixels = build_dxt_mip_chain(
        native.pixels[0], native.width, native.height, mode, alpha_cutoff
    )
    native.num_levels = len(native.pixels)
    native.raster_format_flags = dxt_raster_format_flags(mode, mipmaps=True)
    native.d3d_format = (
        module.txd.D3DFormat.D3D_DXT5
        if mode == "BLEND"
        else module.txd.D3DFormat.D3D_DXT1
    )
    native.depth = 16
    native.platform_properties = type(
        "PlatformProperties",
        (),
        {
            "alpha": mode != "OPAQUE",
            "cube_texture": False,
            "auto_mipmaps": False,
            "compressed": True,
        },
    )()


def _export_txd(module, manifest: dict, images: dict[str, bpy.types.Image], path: Path) -> None:
    value = module.txd.txd()
    value.device_id = module.txd.DeviceType.DEVICE_D3D9
    for texture in manifest["textures"]:
        name = texture["name"]
        image = images.get(name)
        if image is None:
            raise RuntimeError(f"staged texture image was not loaded: {name}")
        native = module.txd_exporter._create_texture_native_from_image(image, name)
        _configure_native_dxt(
            module,
            native,
            _texture_alpha_mode(texture),
            texture.get("alpha_cutoff"),
        )
        value.native_textures.append(native)
    value.write_file(str(path), 0x36003)


def _validate_txd(module, path: Path, texture_records: list[dict]) -> dict:
    value = module.txd.txd()
    value.load_file(str(path))
    expected = {texture["name"]: _texture_alpha_mode(texture) for texture in texture_records}
    actual_names = {texture.name for texture in value.native_textures}
    if actual_names != set(expected):
        missing = sorted(set(expected) - actual_names)
        unexpected = sorted(actual_names - set(expected))
        raise RuntimeError(f"TXD texture-name mismatch; missing={missing}, unexpected={unexpected}")

    class_counts = {"OPAQUE": 0, "MASK": 0, "BLEND": 0}
    flag_counts = {"opaque": 0, "alpha": 0}
    format_counts = {"DXT1": 0, "DXT5": 0}
    mip_level_counts: dict[str, int] = {}
    total_mip_bytes = 0
    range_counts: dict[str, int] = {}
    key_ranges = {}
    key_names = {"ROAD01", "RDTOGRAVEL", "ST_GRAVEL", "SKYBLUE", "XT_CONIFERE", "W_BIGTREE", "ST_SHADOWSQUARE"}
    for texture in value.native_textures:
        mode = expected[texture.name]
        class_counts[mode] += 1
        has_alpha = bool(texture.has_alpha())
        flag_counts["alpha" if has_alpha else "opaque"] += 1
        expected_format = (
            module.txd.D3DFormat.D3D_DXT5
            if mode == "BLEND"
            else module.txd.D3DFormat.D3D_DXT1
        )
        format_name = "DXT5" if mode == "BLEND" else "DXT1"
        format_counts[format_name] += 1
        expected_levels = len(mip_dimensions(texture.width, texture.height))
        mip_level_counts[str(texture.num_levels)] = mip_level_counts.get(str(texture.num_levels), 0) + 1
        total_mip_bytes += sum(len(level) for level in texture.pixels)
        if texture.d3d_format != expected_format or not texture.platform_properties.compressed:
            raise RuntimeError(
                f"texture {texture.name} is not expected {format_name}: "
                f"format={texture.d3d_format}, compressed={texture.platform_properties.compressed}"
            )
        expected_raster_flags = dxt_raster_format_flags(mode, mipmaps=True)
        if texture.raster_format_flags != expected_raster_flags:
            raise RuntimeError(
                f"texture {texture.name} has incompatible DXT raster flags: "
                f"0x{texture.raster_format_flags:04x}/0x{expected_raster_flags:04x}"
            )
        if texture.num_levels != expected_levels or not texture.get_raster_has_mipmaps():
            raise RuntimeError(
                f"texture {texture.name} has incomplete mipmaps: "
                f"levels={texture.num_levels}/{expected_levels}, flag={texture.get_raster_has_mipmaps()}"
            )
        for level, (width, height) in zip(texture.pixels, mip_dimensions(texture.width, texture.height)):
            block_bytes = 16 if mode == "BLEND" else 8
            expected_bytes = ((width + 3) // 4) * ((height + 3) // 4) * block_bytes
            if len(level) != expected_bytes:
                raise RuntimeError(
                    f"texture {texture.name} mip {width}x{height} has {len(level)} bytes, expected {expected_bytes}"
                )
        rgba = texture.to_rgba()
        alphas = rgba[3::4] if rgba else b""
        alpha_range = (min(alphas), max(alphas)) if alphas else (255, 255)
        range_key = f"{alpha_range[0]}-{alpha_range[1]}"
        range_counts[range_key] = range_counts.get(range_key, 0) + 1
        if texture.name in key_names:
            key_ranges[texture.name] = {
                "mode": mode,
                "has_alpha": has_alpha,
                "range": list(alpha_range),
                "format": format_name,
                "mip_levels": texture.num_levels,
            }
        if mode == "OPAQUE":
            if has_alpha or alpha_range != (255, 255):
                raise RuntimeError(
                    f"opaque texture {texture.name} retained alpha flag/range: "
                    f"has_alpha={has_alpha}, range={alpha_range}"
                )
        else:
            if not has_alpha:
                raise RuntimeError(f"{mode.lower()} texture {texture.name} lost its TXD alpha flag")

    for name in ("ROAD01", "RDTOGRAVEL", "ST_GRAVEL", "SKYBLUE"):
        if name in expected and expected[name] != "OPAQUE":
            raise RuntimeError(f"known opaque texture {name} was classified as {expected[name]}")
    for name in ("XT_CONIFERE", "W_BIGTREE"):
        if name in expected and expected[name] == "OPAQUE":
            raise RuntimeError(f"known cutout texture {name} was classified as opaque")
    return {
        "textures": len(value.native_textures),
        "classes": class_counts,
        "alpha_flags": flag_counts,
        "formats": format_counts,
        "mip_level_counts": dict(sorted(mip_level_counts.items(), key=lambda item: int(item[0]))),
        "total_mip_bytes": total_mip_bytes,
        "alpha_ranges": dict(sorted(range_counts.items())),
        "key_textures": key_ranges,
    }


def main() -> None:
    manifest_path, out_dir, dragonff_path = _arguments()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    dff_module, txd_module, col_module, state_module = _load_dragonff(dragonff_path)
    _clear_scene()
    out_dir.mkdir(parents=True, exist_ok=True)
    dff_dir, col_dir = out_dir / "dff", out_dir / "col"
    dff_dir.mkdir(exist_ok=True)
    col_dir.mkdir(exist_ok=True)
    images = _load_images(manifest, manifest_path.parent)
    shared_materials = [_visual_material(value, images) for value in manifest["material_catalog"]]

    exported_models = []
    # LOD geometry is already generated by the Eagle Editor meshoptimizer
    # bridge. Blender/DragonFF only serializes the staged geometry here.
    for model in manifest["models"]:
        materials = [shared_materials[index] for index in model["materials"]]
        obj = _mesh_object(model, materials)
        _export_dff(dff_module, state_module, obj, dff_dir / f"{model['model_id']}.dff")
        collision_data = _collision_collection(model)
        if collision_data is None:
            _export_bounds_only_col(col_module, model, col_dir / f"{model['model_id']}.col")
        else:
            collection, collision_obj, collision_mesh = collision_data
            col_module.export_col(
                {
                    "file_name": str(col_dir / f"{model['model_id']}.col"),
                    "version": 3,
                    "collection": collection,
                    "apply_transformations": True,
                    "only_selected": False,
                }
            )
            bpy.data.objects.remove(collision_obj, do_unlink=True)
            bpy.data.meshes.remove(collision_mesh)
            bpy.data.collections.remove(collection)
        visual_mesh = obj.data
        bpy.data.objects.remove(obj, do_unlink=True)
        bpy.data.meshes.remove(visual_mesh)
        exported_models.append(model)

    txd_path = out_dir / manifest["txd_file"]
    _export_txd(txd_module, manifest, images, txd_path)
    max_dff_vertices = 0
    prelit_geometries = 0
    max_prop_local_aabb_center_error = 0.0
    max_local_aabb_center_error = 0.0
    max_prelight_channel_error = 0
    prelight_mismatches = []
    dff_bounds = {}
    dff_face_counts = {}
    dff_texture_mismatches = []
    dff_material_assignment_mismatches = []
    manifest_models = {model["model_id"]: model for model in exported_models}
    for path in dff_dir.glob("*.dff"):
        value = dff_module.dff.dff()
        value.load_file(str(path))
        model_vertices = []
        for geometry in value.geometry_list:
            max_dff_vertices = max(max_dff_vertices, len(geometry.vertices))
            prelit_geometries += bool(geometry.prelit_colors)
            model_vertices.extend(geometry.vertices)
        expected_model = manifest_models.get(path.stem)
        actual_texture_names = sorted({
            texture.name
            for geometry in value.geometry_list
            for material in geometry.materials
            for texture in material.textures
            if texture.name
        })
        expected_texture_names = sorted({
            manifest["material_catalog"][index].get("texture_name")
            for index in (expected_model or {}).get("materials", [])
            if manifest["material_catalog"][index].get("texture_name")
        })
        if actual_texture_names != expected_texture_names:
            dff_texture_mismatches.append({
                "model": path.stem, "expected": expected_texture_names, "actual": actual_texture_names,
            })
        actual_assignments = {}
        for geometry in value.geometry_list:
            for triangle in geometry.triangles:
                material = geometry.materials[int(triangle.material)]
                texture_name = material.textures[0].name if material.textures else None
                actual_assignments[texture_name] = actual_assignments.get(texture_name, 0) + 1
        expected_assignments = {}
        if expected_model:
            for face, material in zip(expected_model.get("faces", []), expected_model.get("face_materials", [])):
                catalog_index = expected_model["materials"][int(material)]
                texture_name = manifest["material_catalog"][catalog_index].get("texture_name")
                expected_assignments[texture_name] = expected_assignments.get(texture_name, 0) + 1
        if actual_assignments != expected_assignments:
            dff_material_assignment_mismatches.append({
                "model": path.stem,
                "expected_count": sum(expected_assignments.values()),
                "actual_count": sum(actual_assignments.values()),
                "missing_assignments": sum((expected_assignments[key] - actual_assignments.get(key, 0)) for key in expected_assignments if expected_assignments[key] > actual_assignments.get(key, 0)),
                "unexpected_assignments": sum((actual_assignments[key] - expected_assignments.get(key, 0)) for key in actual_assignments if actual_assignments[key] > expected_assignments.get(key, 0)),
            })
        actual_colors = [tuple(color) for geometry in value.geometry_list for color in geometry.prelit_colors]
        expected_colors = [tuple(color) for color in (expected_model or {}).get("colors", [])]
        if len(actual_colors) != len(expected_colors):
            prelight_mismatches.append(
                {"model": path.stem, "expected": len(expected_colors), "actual": len(actual_colors)}
            )
        else:
            # DragonFF rebuilds and reorders RenderWare vertices while writing
            # bin-mesh material splits.  Position/color pairing therefore
            # cannot be compared by source vertex index (and float32 position
            # quantization makes position buckets unreliable on large chunks).
            # Compare each complete channel distribution instead.  This still
            # proves that every staged prelight byte reached the DFF while
            # remaining invariant to DragonFF's legal vertex reordering.
            for channel in range(4):
                actual_channel = sorted(int(color[channel]) for color in actual_colors)
                expected_channel = sorted(int(color[channel]) for color in expected_colors)
                max_prelight_channel_error = max(
                    max_prelight_channel_error,
                    max(
                        (abs(actual - expected) for actual, expected in zip(actual_channel, expected_channel)),
                        default=0,
                    ),
                )
        dff_face_counts[path.stem] = sum(len(geometry.triangles) for geometry in value.geometry_list)
        if model_vertices:
            dff_bounds[path.stem] = (
                tuple(min(float(getattr(vertex, axis)) for vertex in model_vertices) for axis in ("x", "y", "z")),
                tuple(max(float(getattr(vertex, axis)) for vertex in model_vertices) for axis in ("x", "y", "z")),
            )
        if model_vertices:
            center = tuple(
                (min(float(getattr(vertex, axis)) for vertex in model_vertices)
                 + max(float(getattr(vertex, axis)) for vertex in model_vertices))
                * 0.5
                for axis in ("x", "y", "z")
            )
            center_error = sum(component * component for component in center) ** 0.5
            max_local_aabb_center_error = max(max_local_aabb_center_error, center_error)
            if "_p_" in path.stem:
                max_prop_local_aabb_center_error = max(max_prop_local_aabb_center_error, center_error)
    col_faces = 0
    bounds_only_cols = 0
    max_bounds_only_col_error = 0.0
    max_mesh_col_bounds_error = 0.0
    mesh_col_face_mismatches = []
    mesh_col_surface_mismatches = []
    for path in col_dir.glob("*.col"):
        value = col_module.col.coll()
        value.load_file(str(path))
        col_faces += sum(len(model.mesh_faces) for model in value.models)
        bounds_only_cols += sum(
            not model.mesh_faces and not model.boxes and not model.spheres
            for model in value.models
        )
        for model in value.models:
            if not model.mesh_faces and not model.boxes and not model.spheres:
                expected = dff_bounds.get(path.stem)
                if expected is None:
                    raise RuntimeError(f"bounds-only COL has no matching DFF: {path.name}")
                actual = (model.bounds.min, model.bounds.max)
                max_bounds_only_col_error = max(
                    max_bounds_only_col_error,
                    *(abs(float(actual[bound][axis]) - expected[bound][axis]) for bound in range(2) for axis in range(3)),
                )
            else:
                expected_model = manifest_models.get(path.stem)
                expected_faces = len(expected_model.get("collision_faces", [])) if expected_model else None
                if expected_model is None or expected_model.get("collision_kind") != "mesh":
                    raise RuntimeError(f"unexpected physical COL mesh: {path.name}")
                if expected_faces != len(model.mesh_faces):
                    mesh_col_face_mismatches.append(
                        {"model": path.stem, "dff": expected_faces, "col": len(model.mesh_faces)}
                    )
                expected_surfaces = Counter(int(value) for value in expected_model.get("collision_materials", []))
                actual_surfaces = Counter(
                    int(face.material if hasattr(face, "material") else face.surface.material)
                    for face in model.mesh_faces
                )
                if expected_surfaces != actual_surfaces:
                    mesh_col_surface_mismatches.append({
                        "model": path.stem,
                        "expected": dict(sorted(expected_surfaces.items())),
                        "actual": dict(sorted(actual_surfaces.items())),
                    })
                # Native road COL geometry intentionally does not have the
                # same faces or bounds as the visual DFF. Compare the
                # DragonFF result with the staged collision vertices when
                # present; visual/bounds COLs still use the DFF bounds.
                staged_vertices = expected_model.get("collision_vertices", []) if expected_model else []
                if staged_vertices:
                    expected_bounds = (
                        tuple(min(float(vertex[axis]) for vertex in staged_vertices) for axis in range(3)),
                        tuple(max(float(vertex[axis]) for vertex in staged_vertices) for axis in range(3)),
                    )
                else:
                    expected_bounds = dff_bounds[path.stem]
                max_mesh_col_bounds_error = max(
                    max_mesh_col_bounds_error,
                    *(abs(float(model.bounds.min[axis]) - expected_bounds[0][axis]) for axis in range(3)),
                    *(abs(float(model.bounds.max[axis]) - expected_bounds[1][axis]) for axis in range(3)),
                )
    if max_bounds_only_col_error > 0.001:
        raise RuntimeError(f"bounds-only COL does not match DFF bounds: {max_bounds_only_col_error}")
    if mesh_col_face_mismatches:
        raise RuntimeError(f"mesh COL face counts do not match staged collision geometry: {mesh_col_face_mismatches}")
    if mesh_col_surface_mismatches:
        raise RuntimeError(f"mesh COL surfaces do not match staged collision materials: {mesh_col_surface_mismatches}")
    if max_mesh_col_bounds_error > 0.01:
        raise RuntimeError(f"mesh COL does not match DFF bounds: {max_mesh_col_bounds_error}")
    if dff_texture_mismatches or dff_material_assignment_mismatches:
        raise RuntimeError(
            "DFF material/TXD references changed during DragonFF export: "
            f"textures={dff_texture_mismatches[:10]}, assignments={dff_material_assignment_mismatches[:10]}"
        )
    if prelight_mismatches or max_prelight_channel_error > 1:
        raise RuntimeError(
            "DFF prelight colors exceed the accepted DragonFF one-byte quantization tolerance: "
            f"count_mismatches={prelight_mismatches}, max_channel_error={max_prelight_channel_error}"
        )
    dff_names = {path.stem for path in dff_dir.glob("*.dff")}
    col_names = {path.stem for path in col_dir.glob("*.col")}
    if dff_names != col_names:
        raise RuntimeError(
            f"DFF/COL basename mismatch: dff_only={sorted(dff_names-col_names)}, col_only={sorted(col_names-dff_names)}"
        )
    if any(re.match(r"t\d+_c_", name) for name in dff_names):
        raise RuntimeError("obsolete t##_c_* collision-carrier DFF was exported")
    txd_report = _validate_txd(txd_module, txd_path, manifest["textures"])
    print(
        "MTA_EXPORT "
        + json.dumps(
            {
                "dff": len(list(dff_dir.glob("*.dff"))),
                "col": len(list(col_dir.glob("*.col"))),
                "txd_textures": txd_report["textures"],
                "txd_alpha": txd_report,
                "max_dff_vertices": max_dff_vertices,
                "prelit_geometries": prelit_geometries,
                "max_prelight_channel_error": max_prelight_channel_error,
                "prelight_mismatches": prelight_mismatches,
                "dff_texture_mismatches": dff_texture_mismatches,
                "dff_material_assignment_mismatches": dff_material_assignment_mismatches,
                "max_prop_local_aabb_center_error": max_prop_local_aabb_center_error,
                "max_local_aabb_center_error": max_local_aabb_center_error,
                "col_faces": col_faces,
                "bounds_only_cols": bounds_only_cols,
                "max_bounds_only_col_error": max_bounds_only_col_error,
                "max_mesh_col_bounds_error": max_mesh_col_bounds_error,
                "mesh_col_face_mismatches": mesh_col_face_mismatches,
                "mesh_col_surface_mismatches": mesh_col_surface_mismatches,
                "dff_col_name_sets_match": True,
                "lod": manifest.get("lod_generation", []),
                "status": "ok",
            }
        )
    )


if __name__ == "__main__":
    main()
