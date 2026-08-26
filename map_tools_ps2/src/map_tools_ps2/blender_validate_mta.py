from __future__ import annotations

import importlib
import json
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from map_tools_ps2.mta_txd import dxt_raster_format_flags, mip_dimensions


def _load(path: Path):
    sys.path.insert(0, str(path.parent))
    package = importlib.import_module(path.name)
    return (
        importlib.import_module(f"{package.__name__}.gtaLib.dff"),
        importlib.import_module(f"{package.__name__}.gtaLib.txd"),
        importlib.import_module(f"{package.__name__}.gtaLib.col"),
    )


def main() -> None:
    args = sys.argv[sys.argv.index("--") + 1 :]
    if len(args) not in {2, 3}:
        raise SystemExit(
            "usage: blender --background --python blender_validate_mta.py -- "
            "LOOSE_DIR DRAGONFF_PATH [MANIFEST]"
        )
    root, dragonff_path = Path(args[0]), Path(args[1])
    manifest_path = Path(args[2]) if len(args) == 3 else root.parent / "mta_stage.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.is_file() else None
    expected_alpha = {
        texture["name"]: str(texture.get("alpha_mode") or "OPAQUE").upper()
        for texture in (manifest or {}).get("textures", [])
    }
    dff_lib, txd_lib, col_lib = _load(dragonff_path)
    dff_files = sorted((root / "dff").glob("*.dff"))
    col_files = sorted((root / "col").glob("*.col"))
    txd_files = sorted(root.glob("*.txd"))
    max_vertices = 0
    prelit_geometries = 0
    textured_materials = 0
    texture_references: set[str] = set()
    max_prop_local_aabb_center_error = 0.0
    max_prelight_channel_error = 0
    prelight_mismatches = []
    dff_bounds = {}
    dff_face_counts = {}
    manifest_models = {model["model_id"]: model for model in (manifest or {}).get("models", [])}
    for path in dff_files:
        value = dff_lib.dff()
        value.load_file(str(path))
        if not value.geometry_list:
            raise RuntimeError(f"DFF has no geometry: {path.name}")
        model_vertices = []
        for geometry in value.geometry_list:
            model_vertices.extend(geometry.vertices)
            max_vertices = max(max_vertices, len(geometry.vertices))
            if len(geometry.vertices) > 65535:
                raise RuntimeError(f"DFF vertex limit exceeded: {path.name}")
            if geometry.prelit_colors:
                prelit_geometries += 1
                if len(geometry.prelit_colors) != len(geometry.vertices):
                    raise RuntimeError(f"DFF prelight count mismatch: {path.name}")
            if geometry.uv_layers and any(len(layer) != len(geometry.vertices) for layer in geometry.uv_layers):
                raise RuntimeError(f"DFF UV count mismatch: {path.name}")
            if any(triangle.material >= len(geometry.materials) for triangle in geometry.triangles):
                raise RuntimeError(f"DFF face material index is invalid: {path.name}")
            textured_materials += sum(bool(material.textures) for material in geometry.materials)
            texture_references.update(texture.name for material in geometry.materials for texture in material.textures)
        if manifest is not None:
            expected_model = manifest_models.get(path.stem)
            actual_colors = [tuple(color) for geometry in value.geometry_list for color in geometry.prelit_colors]
            expected_colors = [tuple(color) for color in (expected_model or {}).get("colors", [])]
            if len(actual_colors) != len(expected_colors):
                prelight_mismatches.append(
                    {"model": path.stem, "expected": len(expected_colors), "actual": len(actual_colors)}
                )
            else:
                max_prelight_channel_error = max(
                    max_prelight_channel_error,
                    max(
                        (
                            abs(actual[channel] - expected[channel])
                            for actual, expected in zip(actual_colors, expected_colors)
                            for channel in range(4)
                        ),
                        default=0,
                    ),
                )
        if "_p_" in path.stem and model_vertices:
            center = tuple(
                (min(float(getattr(vertex, axis)) for vertex in model_vertices)
                 + max(float(getattr(vertex, axis)) for vertex in model_vertices))
                * 0.5
                for axis in ("x", "y", "z")
            )
            max_prop_local_aabb_center_error = max(
                max_prop_local_aabb_center_error,
                sum(component * component for component in center) ** 0.5,
            )
        if model_vertices:
            dff_bounds[path.stem] = (
                tuple(min(float(getattr(vertex, axis)) for vertex in model_vertices) for axis in ("x", "y", "z")),
                tuple(max(float(getattr(vertex, axis)) for vertex in model_vertices) for axis in ("x", "y", "z")),
            )
        dff_face_counts[path.stem] = sum(len(geometry.triangles) for geometry in value.geometry_list)
    col_models = 0
    col_faces = 0
    bounds_only_col_models = 0
    max_bounds_only_col_error = 0.0
    max_mesh_col_bounds_error = 0.0
    mesh_col_face_mismatches = []
    for path in col_files:
        value = col_lib.coll()
        value.load_file(str(path))
        col_models += len(value.models)
        col_faces += sum(len(model.mesh_faces) for model in value.models)
        bounds_only_col_models += sum(
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
                if expected_model and expected_model.get("collision_kind") != "mesh":
                    raise RuntimeError(f"unexpected physical COL mesh: {path.name}")
                expected_faces = len(expected_model.get("collision_faces", [])) if expected_model else dff_face_counts.get(path.stem)
                if expected_faces != len(model.mesh_faces):
                    mesh_col_face_mismatches.append(
                        {"model": path.stem, "dff": expected_faces, "col": len(model.mesh_faces)}
                    )
                expected = dff_bounds.get(path.stem)
                if expected is None:
                    raise RuntimeError(f"mesh COL has no matching DFF: {path.name}")
                max_mesh_col_bounds_error = max(
                    max_mesh_col_bounds_error,
                    *(abs(float(model.bounds.min[axis]) - expected[0][axis]) for axis in range(3)),
                    *(abs(float(model.bounds.max[axis]) - expected[1][axis]) for axis in range(3)),
                )
    if max_bounds_only_col_error > 0.001:
        raise RuntimeError(f"bounds-only COL does not match DFF bounds: {max_bounds_only_col_error}")
    if mesh_col_face_mismatches:
        raise RuntimeError(f"mesh COL face counts do not match DFF: {mesh_col_face_mismatches}")
    if max_mesh_col_bounds_error > 0.01:
        raise RuntimeError(f"mesh COL does not match DFF bounds: {max_mesh_col_bounds_error}")
    if prelight_mismatches or max_prelight_channel_error > 1:
        raise RuntimeError(
            "DFF prelight colors exceed the accepted DragonFF one-byte quantization tolerance: "
            f"count_mismatches={prelight_mismatches}, max_channel_error={max_prelight_channel_error}"
        )
    dff_names = {path.stem for path in dff_files}
    col_names = {path.stem for path in col_files}
    if dff_names != col_names:
        raise RuntimeError(
            f"DFF/COL basename mismatch: dff_only={sorted(dff_names-col_names)}, col_only={sorted(col_names-dff_names)}"
        )
    if any(re.match(r"t\d+_c_", name) for name in dff_names):
        raise RuntimeError("obsolete t##_c_* collision-carrier DFF is present")
    txd_textures = 0
    txd_texture_names: set[str] = set()
    txd_alpha_flags = Counter()
    txd_alpha_ranges = Counter()
    txd_alpha_classes = Counter()
    txd_formats = Counter()
    txd_mip_levels = Counter()
    txd_mip_bytes = 0
    for path in txd_files:
        value = txd_lib.txd()
        value.load_file(str(path))
        txd_textures += len(value.native_textures)
        txd_texture_names.update(texture.name for texture in value.native_textures)
        for texture in value.native_textures:
            has_alpha = bool(texture.has_alpha())
            txd_alpha_flags["alpha" if has_alpha else "opaque"] += 1
            rgba = texture.to_rgba()
            alphas = rgba[3::4] if rgba else b""
            alpha_range = (min(alphas), max(alphas)) if alphas else (255, 255)
            txd_alpha_ranges[f"{alpha_range[0]}-{alpha_range[1]}"] += 1
            mode = expected_alpha.get(texture.name)
            if mode:
                txd_alpha_classes[mode] += 1
                expected_format = txd_lib.D3DFormat.D3D_DXT5 if mode == "BLEND" else txd_lib.D3DFormat.D3D_DXT1
                format_name = "DXT5" if mode == "BLEND" else "DXT1"
                txd_formats[format_name] += 1
                dimensions = mip_dimensions(texture.width, texture.height)
                txd_mip_levels[texture.num_levels] += 1
                txd_mip_bytes += sum(len(level) for level in texture.pixels)
                if texture.d3d_format != expected_format or not texture.platform_properties.compressed:
                    raise RuntimeError(f"texture {texture.name} is not compressed as {format_name}")
                expected_raster_flags = dxt_raster_format_flags(mode, mipmaps=True)
                if texture.raster_format_flags != expected_raster_flags:
                    raise RuntimeError(
                        f"texture {texture.name} has incompatible DXT raster flags: "
                        f"0x{texture.raster_format_flags:04x}/0x{expected_raster_flags:04x}"
                    )
                if texture.num_levels != len(dimensions) or not texture.get_raster_has_mipmaps():
                    raise RuntimeError(
                        f"texture {texture.name} has incomplete mipmaps: {texture.num_levels}/{len(dimensions)}"
                    )
                block_bytes = 16 if mode == "BLEND" else 8
                for level, (width, height) in zip(texture.pixels, dimensions):
                    expected_bytes = ((width + 3) // 4) * ((height + 3) // 4) * block_bytes
                    if len(level) != expected_bytes:
                        raise RuntimeError(
                            f"texture {texture.name} mip {width}x{height} has invalid byte count"
                        )
                if mode == "OPAQUE":
                    if has_alpha or alpha_range != (255, 255):
                        raise RuntimeError(
                            f"opaque texture {texture.name} retained alpha: "
                            f"has_alpha={has_alpha}, range={alpha_range}"
                        )
                elif mode in {"MASK", "BLEND"}:
                    if not has_alpha:
                        raise RuntimeError(f"{mode.lower()} texture {texture.name} lost its alpha flag")
                else:
                    raise RuntimeError(f"unsupported staged alpha mode for {texture.name}: {mode}")
    missing_texture_references = sorted(texture_references - txd_texture_names)
    if missing_texture_references:
        raise RuntimeError(f"DFF texture references missing from TXD: {missing_texture_references}")
    if expected_alpha and txd_texture_names != set(expected_alpha):
        raise RuntimeError(
            "TXD/staging texture mismatch: "
            f"missing={sorted(set(expected_alpha) - txd_texture_names)}, "
            f"unexpected={sorted(txd_texture_names - set(expected_alpha))}"
        )
    print(
        "MTA_VALIDATE "
        + json.dumps(
            {
                "status": "ok",
                "dff_files": len(dff_files),
                "col_files": len(col_files),
                "txd_files": len(txd_files),
                "max_dff_vertices": max_vertices,
                "prelit_geometries": prelit_geometries,
                "max_prelight_channel_error": max_prelight_channel_error,
                "prelight_mismatches": prelight_mismatches,
                "textured_materials": textured_materials,
                "col_models": col_models,
                "col_faces": col_faces,
                "bounds_only_col_models": bounds_only_col_models,
                "max_bounds_only_col_error": max_bounds_only_col_error,
                "max_mesh_col_bounds_error": max_mesh_col_bounds_error,
                "mesh_col_face_mismatches": mesh_col_face_mismatches,
                "dff_col_name_sets_match": True,
                "txd_textures": txd_textures,
                "txd_alpha_classes": dict(txd_alpha_classes),
                "txd_alpha_flags": dict(txd_alpha_flags),
                "txd_alpha_ranges": dict(sorted(txd_alpha_ranges.items())),
                "txd_formats": dict(txd_formats),
                "txd_mip_levels": {str(key): value for key, value in sorted(txd_mip_levels.items())},
                "txd_mip_bytes": txd_mip_bytes,
                "texture_references": len(texture_references),
                "max_prop_local_aabb_center_error": max_prop_local_aabb_center_error,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
