import json
import math
import struct
import xml.etree.ElementTree as ET
from collections import Counter
from types import SimpleNamespace

import pytest

from map_tools_ps2.binary import IDENTITY4, Vec3, transform_point
from map_tools_ps2.img_archive import ImgEntry, read_img_v2_directory, write_img_v2
from map_tools_ps2.mta_export import _img_archive_declarations, _prepare_eagle_lods, _write_resource_xml, _write_staging, _write_water_dat
from map_tools_ps2.model import DecodedBlock, MeshObject, Scene, SceneryInstance, TrackCollisionPolygon
from map_tools_ps2.mta_scene import (
    DEFAULT_HP2_TO_GTA_SURFACE,
    MtaWaterQuad,
    _native_collision_surface,
    build_mta_scene,
    cell_for_xy,
    compose_zxy_row,
    decompose_placement,
)
from map_tools_ps2.mta_txd import build_bgra_mip_chain, build_dxt_mip_chain, dxt_raster_format_flags, mip_dimensions
from map_tools_ps2.material_alpha import decide_material_alpha, is_opaque_surface_state
from map_tools_ps2.textures import TextureLibrary
from map_tools_ps2.vif import VifVertexRun


def _matrix(rotation=(20.0, -35.0, 72.0), scale=(0.8, 1.2, 1.5), position=(10.0, -20.0, 5.0)):
    rows = compose_zxy_row(rotation)
    return tuple(
        tuple(rows[row][column] * scale[row] for column in range(3)) + (0.0,)
        for row in range(3)
    ) + (tuple(position) + (1.0,),)


def test_mta_zxy_transform_roundtrip():
    source = _matrix()
    position, rotation, scale, error = decompose_placement(source)
    rebuilt_rotation = compose_zxy_row(rotation)
    rebuilt = [[rebuilt_rotation[row][column] * scale[row] for column in range(3)] for row in range(3)]
    assert position == pytest.approx(source[3][:3])
    assert error < 1e-6
    for row in range(3):
        assert rebuilt[row] == pytest.approx(source[row][:3], abs=1e-6)


def test_mta_negative_scale_roundtrip():
    source = _matrix(scale=(-0.75, 1.0, 2.0))
    _position, rotation, scale, error = decompose_placement(source)
    rebuilt_rotation = compose_zxy_row(rotation)
    rebuilt = [[rebuilt_rotation[row][column] * scale[row] for column in range(3)] for row in range(3)]
    assert error < 1e-6
    for row in range(3):
        assert rebuilt[row] == pytest.approx(source[row][:3], abs=1e-6)


def test_img_v2_roundtrip_and_alignment(tmp_path):
    path = tmp_path / "models.img"
    stats = write_img_v2(path, [ImgEntry("one.dff", b"abc"), ImgEntry("two.dff", b"x" * 3000)])
    entries = read_img_v2_directory(path)
    assert stats["entries"] == 2
    assert path.read_bytes()[:4] == b"VER2"
    assert entries == [(1, 1, "one.dff"), (2, 2, "two.dff")]
    assert path.stat().st_size % 2048 == 0


def test_txd_complete_mip_chain_and_dxt_sizes():
    assert mip_dimensions(8, 4) == [(8, 4), (4, 2), (2, 1), (1, 1)]
    base = bytes((20, 40, 80, 255)) * (8 * 4)
    levels = build_dxt_mip_chain(base, 8, 4, "OPAQUE")
    assert [len(level) for level in levels] == [16, 8, 8, 8]
    blend = build_dxt_mip_chain(base, 8, 4, "BLEND")
    assert [len(level) for level in blend] == [32, 16, 16, 16]


def test_txd_dxt_raster_flags_match_gta_native_conventions():
    assert dxt_raster_format_flags("OPAQUE") == 0x8200
    assert dxt_raster_format_flags("MASK") == 0x8100
    assert dxt_raster_format_flags("BLEND") == 0x8300
    assert dxt_raster_format_flags("OPAQUE", mipmaps=False) == 0x0200


def test_txd_alpha_aware_mips_and_mask_dxt1_transparency():
    # BGRA: an opaque red texel next to a fully transparent black texel.
    base = bytes((0, 0, 255, 255, 0, 0, 0, 0))
    levels = build_bgra_mip_chain(base, 2, 1, "MASK")
    assert levels[1] == bytes((0, 0, 255, 128))
    compressed = build_dxt_mip_chain(base, 2, 1, "MASK", 0.5)[0]
    color0, color1, indices = struct.unpack("<HHI", compressed)
    assert color0 <= color1  # BC1 three-colour mode enables index 3 transparency.
    assert any(((indices >> (index * 2)) & 3) == 3 for index in range(16))


def test_img_rejects_duplicate_and_long_names(tmp_path):
    with pytest.raises(ValueError, match="duplicate"):
        write_img_v2(tmp_path / "dup.img", [ImgEntry("a.dff", b"1"), ImgEntry("A.DFF", b"2")])
    with pytest.raises(ValueError, match="1..24"):
        write_img_v2(tmp_path / "long.img", [ImgEntry("x" * 25, b"1")])


def _triangle_object(name, offset, transform=IDENTITY4, texture_hashes=(), render_flag=None):
    run = VifVertexRun(
        vertices=(Vec3(0, 0, 0), Vec3(10, 0, 0), Vec3(0, 10, 0)),
        texcoords=((0, 0), (1, 0), (0, 1)),
        packed_values=(0xFFFF, 0x83E0, 0x801F),
        header=None,
        tri_cull=None,
    )
    return MeshObject(
        name,
        offset,
        transform,
        (DecodedBlock(run, primitive_mode="triangles", render_flag=render_flag),),
        texture_hashes,
        123,
    )


def _surface_polygon(index, material_id, x=0.0, y=0.0, z=0.0):
    return TrackCollisionPolygon(
        index,
        0,
        material_id,
        0,
        3,
        (Vec3(x, y, z), Vec3(x + 10, y, z), Vec3(x, y + 10, z)),
        4,
        index * 0x20,
    )


def _two_cluster_road(name="RD_SECTION40_CHOP1"):
    run = VifVertexRun(
        vertices=(
            Vec3(-310, 0, 0), Vec3(-300, 0, 0), Vec3(-310, 10, 0),
            Vec3(300, 0, 0), Vec3(310, 0, 0), Vec3(300, 10, 0),
        ),
        texcoords=((0, 0), (1, 0), (0, 1)) * 2,
        packed_values=(0xFFFF,) * 6,
        header=None,
        tri_cull=None,
    )
    return MeshObject(name, 1, IDENTITY4, (DecodedBlock(run, primitive_mode="triangles"),), (), 123)


def _mixed_alpha_object(name="MIXED_MODEL"):
    def block(x, texture_index):
        run = VifVertexRun(
            vertices=(Vec3(x, 0, 0), Vec3(x + 10, 0, 0), Vec3(x, 10, 0)),
            texcoords=((0, 0), (1, 0), (0, 1)),
            packed_values=(0xFFFF,) * 3,
            header=None,
            tri_cull=None,
        )
        return DecodedBlock(run, primitive_mode="triangles", texture_index=texture_index)

    return MeshObject(name, 1, IDENTITY4, (block(0, 0), block(30, 1)), (100, 200), 123)


def _alpha_texture(name, *, blend):
    return SimpleNamespace(
        name=name,
        png=b"png-data",
        has_alpha=blend,
        alpha_mode="BLEND" if blend else "OPAQUE",
        alpha_cutoff=None,
        alpha_zero_count=1 if blend else 0,
        alpha_opaque_count=1,
        alpha_intermediate_count=1 if blend else 0,
        is_any_semitransparency=1 if blend else 0,
        alpha_bits=0x44 if blend else 0x0A,
        alpha_fix=0,
        texture_fx=0,
    )


def test_mta_staging_preserves_texture_alpha_metadata(tmp_path):
    texture = SimpleNamespace(
        name="ROAD01",
        png=b"png-data",
        has_alpha=False,
        alpha_mode=None,
        alpha_cutoff=None,
    )
    textures = TextureLibrary({123: texture})
    source = Scene(objects=[_triangle_object("ROAD", 1, texture_hashes=(123,))])
    scene = build_mta_scene(source, textures, track_id=31, resource_name="TEST", collision_mode="bounds-only")
    manifest_path = _write_staging(scene, textures, tmp_path)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["textures"] == [
        {
            "hash": 123,
            "name": "ROAD01",
            "file": "textures/ROAD01.png",
            "has_alpha": False,
            "alpha_mode": "OPAQUE",
                "alpha_cutoff": None,
                "source_alpha_mode": "OPAQUE",
        }
    ]
    assert (tmp_path / "textures" / "ROAD01.png").read_bytes() == b"png-data"


def test_mta_staging_uses_surface_state_instead_of_texture_name_hardcode(tmp_path):
    texture = SimpleNamespace(
        name="RDTOGRAVEL",
        png=b"png-data",
        has_alpha=True,
        alpha_mode="MASK",
        alpha_cutoff=0.5,
    )
    textures = TextureLibrary({123: texture})
    source = Scene(objects=[_triangle_object("ANY_OBJECT", 1, texture_hashes=(123,), render_flag=0x4041)])
    scene = build_mta_scene(source, textures, track_id=31, resource_name="TEST", collision_mode="bounds-only")
    manifest = json.loads(_write_staging(scene, textures, tmp_path).read_text(encoding="utf-8"))
    record = manifest["textures"][0]
    assert record["name"] == "RDTOGRAVEL"
    assert record["has_alpha"] is False
    assert record["alpha_mode"] == "OPAQUE"
    assert record["alpha_cutoff"] is None
    assert record["source_alpha_mode"] == "MASK"


def test_shared_alpha_decision_uses_tpk_flags_and_surface_state():
    cutout = SimpleNamespace(
        alpha_mode="MASK", alpha_cutoff=0.5, alpha_zero_count=10, alpha_opaque_count=20,
        alpha_intermediate_count=0, is_any_semitransparency=0, alpha_bits=0x0A,
        alpha_fix=0, texture_fx=0,
    )
    assert is_opaque_surface_state(0x4041)
    assert decide_material_alpha(cutout, 0x4041, {0x4041}).mode == "OPAQUE"
    assert decide_material_alpha(cutout, None, {None}).mode == "MASK"
    blend = SimpleNamespace(**{**cutout.__dict__, "is_any_semitransparency": 1, "alpha_bits": 0x44})
    assert decide_material_alpha(blend, 0x4041, {0x4041}).mode == "BLEND"


def test_mta_creates_txd_variants_for_one_texture_with_multiple_surface_states():
    texture = SimpleNamespace(
        name="SHARED",
        png=b"png-data",
        has_alpha=True,
        alpha_mode="MASK",
        alpha_cutoff=0.5,
        alpha_zero_count=10,
        alpha_opaque_count=20,
        alpha_intermediate_count=0,
        is_any_semitransparency=0,
        alpha_bits=0x0A,
        alpha_fix=0,
        texture_fx=0,
    )
    source = Scene(
        objects=[
            _triangle_object("OPAQUE_USE", 1, texture_hashes=(123,), render_flag=0x4041),
            _triangle_object("MASK_USE", 2, texture_hashes=(123,), render_flag=0x1000),
        ]
    )
    result = build_mta_scene(source, TextureLibrary({123: texture}), track_id=31, resource_name="TEST")
    assert result.texture_variants == {
        (123, "MASK", None): "SHARED_m",
        (123, "OPAQUE", None): "SHARED_o",
    }
    assert {material.alpha_mode for model in result.models for material in model.materials} == {"MASK", "OPAQUE"}


def test_builtin_hp2_surface_mapping_is_complete_and_overrideable():
    assert set(DEFAULT_HP2_TO_GTA_SURFACE) == set(range(33))
    assert {material_id: DEFAULT_HP2_TO_GTA_SURFACE[material_id] for material_id in (2, 3, 6, 9, 22)} == {
        2: 26,
        3: 27,
        6: 9,
        9: 85,
        22: 153,
    }
    assert _native_collision_surface(3, {}) == 27
    assert _native_collision_surface(3, {"hp2_materials": {"3": 99}}) == 99
    assert _native_collision_surface(3, {"hp2_materials": {"3": 999}}) == 27
    assert _native_collision_surface(3, {"hp2_materials": {"3": "bad"}}) == 27


def test_surface_prefixes_split_road_dirt_grass_and_shared_nonroad_texture():
    texture_values = {
        100: _alpha_texture("SHARED_ROAD", blend=False),
        200: _alpha_texture("DIRT_TEXTURE", blend=False),
        300: _alpha_texture("GRASS_TEXTURE", blend=False),
    }
    source = Scene(
        objects=[
            _triangle_object("RD_SECTION_ROAD", 1, texture_hashes=(100,)),
            _triangle_object(
                "RD_SECTION_DIRT", 2,
                transform=_matrix(rotation=(0, 0, 0), scale=(1, 1, 1), position=(20, 0, 0)),
                texture_hashes=(200,),
            ),
            _triangle_object(
                "RD_SECTION_GRASS", 3,
                transform=_matrix(rotation=(0, 0, 0), scale=(1, 1, 1), position=(40, 0, 0)),
                texture_hashes=(300,),
            ),
            _triangle_object("BUILDING_WITH_SHARED_TEXTURE", 4, texture_hashes=(100,)),
        ],
        track_collision_polygons=[
            _surface_polygon(0, 1, 0),
            _surface_polygon(1, 3, 20),
            _surface_polygon(2, 6, 40),
        ],
    )
    result = build_mta_scene(source, TextureLibrary(texture_values), track_id=31, resource_name="TEST")
    material_names = {
        model.source_name: {material.texture_name for material in model.materials}
        for model in result.models
        if not model.is_lod
    }
    assert material_names["RD_SECTION_ROAD"] == {"road_SHARED_ROAD"}
    assert material_names["RD_SECTION_DIRT"] == {"dirt_DIRT_TEXTURE"}
    assert material_names["RD_SECTION_GRASS"] == {"grass_GRASS_TEXTURE"}
    assert material_names["BUILDING_WITH_SHARED_TEXTURE"] == {"SHARED_ROAD"}
    assert set(result.texture_variants.values()) == {
        "SHARED_ROAD", "road_SHARED_ROAD", "dirt_DIRT_TEXTURE", "grass_GRASS_TEXTURE",
    }
    assert result.report["road_surface_classification"] == {
        "matched": 3,
        "inherited": 0,
        "ambiguous": 0,
        "unmatched": 0,
        "matched_hp2_materials": {"1": 1, "3": 1, "6": 1},
        "prefixed_triangles": {"dirt": 1, "grass": 1, "road": 1},
    }


def test_surface_prefix_composes_with_alpha_and_31_character_limit():
    texture = SimpleNamespace(
        name="A_VERY_LONG_ROAD_TEXTURE_NAME_123456789",
        png=b"png-data",
        has_alpha=True,
        alpha_mode="MASK",
        alpha_cutoff=0.5,
        alpha_zero_count=10,
        alpha_opaque_count=20,
        alpha_intermediate_count=0,
        is_any_semitransparency=0,
        alpha_bits=0x0A,
        alpha_fix=0,
        texture_fx=0,
    )
    source = Scene(
        objects=[
            _triangle_object("RD_SECTION_LONG_A", 1, texture_hashes=(100,), render_flag=0x4041),
            _triangle_object(
                "RD_SECTION_LONG_B", 2,
                transform=_matrix(rotation=(0, 0, 0), scale=(1, 1, 1), position=(20, 0, 0)),
                texture_hashes=(100,), render_flag=0x1000,
            ),
        ],
        track_collision_polygons=[_surface_polygon(0, 1), _surface_polygon(1, 1, 20)],
    )
    result = build_mta_scene(source, TextureLibrary({100: texture}), track_id=31, resource_name="TEST")
    names = sorted(result.texture_variants.values())
    assert len(names) == 2
    assert all(name.startswith("road_") and len(name) <= 31 for name in names)
    assert {name[-2:] for name in names} == {"_m", "_o"}


def test_surface_prefix_uses_nearest_height_for_overlapping_road_levels():
    source = Scene(
        objects=[
            _triangle_object("RD_SECTION_LOWER", 1, texture_hashes=(100,)),
            _triangle_object(
                "RD_SECTION_UPPER", 2,
                transform=_matrix(rotation=(0, 0, 0), scale=(1, 1, 1), position=(0, 0, 10)),
                texture_hashes=(200,),
            ),
        ],
        track_collision_polygons=[
            _surface_polygon(0, 1, z=0),
            _surface_polygon(1, 3, z=10),
        ],
    )
    result = build_mta_scene(
        source,
        TextureLibrary({
            100: _alpha_texture("LOWER", blend=False),
            200: _alpha_texture("UPPER", blend=False),
        }),
        track_id=31,
        resource_name="TEST",
    )
    names = {
        model.source_name: {material.texture_name for material in model.materials}
        for model in result.models if model.kind == "road"
    }
    assert names["RD_SECTION_LOWER"] == {"road_LOWER"}
    assert names["RD_SECTION_UPPER"] == {"dirt_UPPER"}


def test_unmatched_shared_texture_stays_unprefixed_when_categories_are_ambiguous():
    source = Scene(
        objects=[
            _triangle_object("RD_SECTION_ROAD", 1, texture_hashes=(100,)),
            _triangle_object(
                "RD_SECTION_DIRT", 2,
                transform=_matrix(rotation=(0, 0, 0), scale=(1, 1, 1), position=(20, 0, 0)),
                texture_hashes=(100,),
            ),
            _triangle_object(
                "RD_SECTION_UNKNOWN", 3,
                transform=_matrix(rotation=(0, 0, 0), scale=(1, 1, 1), position=(40, 0, 0)),
                texture_hashes=(100,),
            ),
        ],
        track_collision_polygons=[_surface_polygon(0, 1), _surface_polygon(1, 3, 20)],
    )
    result = build_mta_scene(
        source,
        TextureLibrary({100: _alpha_texture("SHARED", blend=False)}),
        track_id=31,
        resource_name="TEST",
    )
    names = {
        model.source_name: {material.texture_name for material in model.materials}
        for model in result.models if model.kind == "road"
    }
    assert names["RD_SECTION_ROAD"] == {"road_SHARED"}
    assert names["RD_SECTION_DIRT"] == {"dirt_SHARED"}
    assert names["RD_SECTION_UNKNOWN"] == {"SHARED"}
    assert result.report["road_surface_classification"]["ambiguous"] == 1


def test_invalid_hp2_override_warns_and_uses_builtin_mapping():
    source = Scene(
        objects=[_triangle_object("RD_SECTION_DIRT", 1)],
        track_collision_polygons=[_surface_polygon(0, 3)],
    )
    result = build_mta_scene(
        source,
        TextureLibrary({}),
        track_id=31,
        resource_name="TEST",
        collision_rules={"hp2_materials": {"3": 999}},
    )
    road = next(model for model in result.models if model.kind == "road")
    assert road.collision_materials == [27]
    assert any("invalid hp2_materials entry" in warning for warning in result.warnings)
    assert result.report["hp2_surface_mapping"]["3"]["source"] == "built_in"


def test_mta_scene_reuses_scaled_prop_and_assigns_native_road_collision():
    static = _triangle_object("RD_SECTION10_CHOP1", 1)
    prop = _triangle_object("PILLAR", 2)
    placement_a = SceneryInstance(0, "PILLAR", _matrix(rotation=(0, 0, 0), scale=(0.8, 1.2, 1.0), position=(20, 20, 0)), 3, 0)
    placement_b = SceneryInstance(0, "PILLAR", _matrix(rotation=(0, 0, 90), scale=(0.8, 1.2, 1.0), position=(320, 20, 0)), 3, 1)
    collision = TrackCollisionPolygon(0, 0, 9, 0, 3, (Vec3(0, 0, 0), Vec3(5, 0, 0), Vec3(0, 5, 0)), 4, 0)
    source = Scene(
        objects=[static, prop],
        scenery_instances=[placement_a, placement_b],
        scenery_template_offsets={2},
        track_collision_polygons=[collision],
    )
    result = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST")
    prop_models = [model for model in result.models if model.kind == "prop"]
    prop_placements = [placement for placement in result.placements if placement.element_type == "object"]
    assert len(prop_models) == 1
    assert len(prop_placements) == 2
    assert prop_placements[0].model_id == prop_placements[1].model_id
    for axis in range(3):
        assert (
            min(vertex[axis] for vertex in prop_models[0].vertices)
            + max(vertex[axis] for vertex in prop_models[0].vertices)
        ) * 0.5 == pytest.approx(0.0, abs=1e-8)
    assert {placement.zone for placement in prop_placements} == {
        "t31_xp000_yp000",
        "t31_xp001_yp000",
    }
    road = next(model for model in result.models if model.kind == "road")
    assert road.collision_kind == "mesh"
    assert road.collision_vertices == [(-5.0, -5.0, 0.0), (0.0, -5.0, 0.0), (-5.0, 0.0, 0.0)]
    assert road.collision_faces == [(0, 1, 2)]
    assert road.collision_materials == [85]
    assert prop_models[0].collision_kind == "bounds"
    assert not prop_models[0].collision_faces
    assert result.report["track_collision_input_polygons"] == 1
    assert result.report["track_collision_used"] is True
    assert result.report["native_polygons_assigned"] == 1
    assert result.report["native_polygons_unassigned"] == 0
    assert result.report["collision_models"] == 0
    assert not any(model.model_id.startswith("t31_c_") for model in result.models)
    assert max(len(model.vertices) for model in result.models) <= 60000
    assert result.report["prop_recentered_models"] == 1
    assert result.report["prop_pivot_offset_before"]["max"] == pytest.approx(math.sqrt(52.0))
    assert result.report["prop_pivot_offset_after"]["max"] == pytest.approx(0.0, abs=1e-8)
    assert result.report["max_pivot_world_reconstruction_error"] < 1e-10
    assert result.report["bounds_error"] < 1e-6


def test_lod_policy_skips_small_vegetation_and_reports_reason():
    source = Scene(objects=[_triangle_object("XT_GRASSA_L1_00", 1)])
    result = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST", collision_mode="bounds-only")

    assert not any(model.is_lod for model in result.models)
    decision = next(item for item in result.report["lod_decisions"] if item["source"] == "XT_GRASSA_L1_00")
    assert decision["category"] == "small_vegetation"
    assert decision["decision"] == "skip"
    assert result.report["lod_skipped_small"] == 1


def test_large_tree_vegetation_gets_lod_when_geometry_is_large():
    tree = _triangle_object("XT_TREE_LARGE", 1)
    source = Scene(
        objects=[tree],
        scenery_instances=[SceneryInstance(0, tree.name, _matrix(scale=(10, 10, 10)), 1, 0)],
        scenery_template_offsets={1},
    )
    result = build_mta_scene(
        source, TextureLibrary({}), track_id=31, resource_name="TEST",
        collision_mode="bounds-only", lod_min_triangles=0,
    )

    decision = next(item for item in result.report["lod_decisions"] if item["source"] == tree.name)
    assert decision["category"] == "vegetation"
    assert decision["reason"] == "large_vegetation"
    assert any(model.is_lod for model in result.models)


@pytest.mark.parametrize("name", ["WATER", "SKYDOME", "SKYDOME_ENVMAP"])
def test_lod_policy_directly_skips_water_and_sky(name):
    source = Scene(objects=[_triangle_object(name, 1)])
    result = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST", collision_mode="bounds-only")

    assert not any(model.is_lod for model in result.models)
    assert not any(item["source"] == name for item in result.report["lod_decisions"])


@pytest.mark.parametrize("name", ["SHD_S10_CHOP1", "TRACK_HELICOPTER"])
def test_lod_policy_excludes_other_special_models(name):
    source = Scene(objects=[_triangle_object(name, 1)])
    result = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST", collision_mode="bounds-only")

    assert not any(model.is_lod for model in result.models)
    decision = next(item for item in result.report["lod_decisions"] if item["source"] == name)
    assert decision["category"] == "special"
    assert decision["decision"] == "skip"


def test_repeated_small_prop_does_not_get_lod():
    prop = _triangle_object("XS_TINY_PROP", 2)
    placements = [
        SceneryInstance(0, prop.name, _matrix(scale=(5, 5, 5), position=(index * 100, 0, 0)), 3, index)
        for index in range(40)
    ]
    result = build_mta_scene(
        Scene(objects=[prop], scenery_instances=placements, scenery_template_offsets={2}),
        TextureLibrary({}), track_id=31, resource_name="TEST", collision_mode="bounds-only",
    )

    assert not any(model.is_lod for model in result.models)
    decision = next(item for item in result.report["lod_decisions"] if item["source"] == prop.name)
    assert decision["placement_count"] == 40
    assert decision["category"] == "small_prop"


def test_repeated_medium_high_complexity_prop_gets_lod():
    vertices = []
    texcoords = []
    packed_values = []
    for index in range(600):
        x = float(index % 20)
        y = float(index // 20)
        vertices.extend((Vec3(x, y, 0), Vec3(x + 10, y, 0), Vec3(x, y + 10, 0)))
        texcoords.extend(((0, 0), (1, 0), (0, 1)))
        packed_values.extend((0xFFFF, 0xFFFF, 0xFFFF))
    prop = MeshObject(
        "XS_REPEATED_COMPLEX", 2, IDENTITY4,
        (DecodedBlock(VifVertexRun(tuple(vertices), tuple(texcoords), tuple(packed_values), None, None), primitive_mode="triangles"),),
        (), 123,
    )
    placements = [
        SceneryInstance(0, prop.name, _matrix(scale=(7, 7, 7), position=(index * 100, 0, 0)), 3, index)
        for index in range(32)
    ]
    result = build_mta_scene(
        Scene(objects=[prop], scenery_instances=placements, scenery_template_offsets={2}),
        TextureLibrary({}), track_id=31, resource_name="TEST", collision_mode="bounds-only",
        lod_min_size=1000.0, lod_small_size=60.0,
    )

    # The 70-unit prop is promoted neither to a static object nor to a LOD by
    # size alone; the repeated-placement rule is what makes it a candidate.
    assert any(model.is_lod for model in result.models)
    decision = next(item for item in result.report["lod_decisions"] if item["source"] == prop.name)
    assert decision["decision"] == "candidate"
    assert decision["reason"] == "geometry_or_reuse_threshold"
    assert all(model.lod_distance == 299.0 for model in result.models if not model.is_lod)
    assert result.report["lod_generated"] >= 1


def test_mta_splits_mixed_blend_model_and_writes_standard_alpha_flags(tmp_path):
    source = Scene(objects=[_mixed_alpha_object()])
    textures = TextureLibrary(
        {
            100: _alpha_texture("SOLID", blend=False),
            200: _alpha_texture("SHADOW", blend=True),
        }
    )

    result = build_mta_scene(source, textures, track_id=31, resource_name="TEST", collision_mode="bounds-only")

    assert len(result.models) == 2
    assert len(result.placements) == 2
    base = next(model for model in result.models if model.render_layer == "base")
    blend = next(model for model in result.models if model.render_layer == "blend")
    assert {material.alpha_mode for material in base.materials} == {"OPAQUE"}
    assert {material.alpha_mode for material in blend.materials} == {"BLEND"}
    assert not base.draw_last and not base.no_zbuffer_write and not base.additive
    assert blend.draw_last and blend.no_zbuffer_write and not blend.additive
    assert result.report["mixed_render_models_split"] == 1
    assert result.report["blend_companion_models"] == 1
    assert result.report["draw_last_models"] == 1
    assert result.report["no_zbuffer_write_models"] == 1
    assert result.report["additive_models"] == 0
    assert result.report["triangle_loss"] is False
    assert result.report["bounds_error"] == pytest.approx(0.0)

    _write_resource_xml(result, tmp_path, "tester", [tmp_path / "imgs" / "dff.img"], (0.0, 0.0, 0.0))
    definitions = {
        node.attrib["id"]: node.attrib
        for path in (tmp_path / "zones").rglob("*.definition")
        for node in ET.parse(path).getroot().findall("definition")
    }
    assert definitions[base.model_id]["flags"] == "disable_backface_culling"
    assert definitions[blend.model_id]["flags"] == "disable_backface_culling,draw_last,no_zbuffer_write"
    assert definitions[blend.model_id]["draw_last"] == "true"
    assert definitions[blend.model_id]["no_zbuffer_write"] == "true"
    assert "additive" not in definitions[blend.model_id]


def test_mta_scene_deduplicates_exact_streaming_section_placements_only():
    prop = _triangle_object("PILLAR", 2)
    other = _triangle_object("OTHER", 3)
    transform = _matrix(rotation=(0, 0, 0), scale=(1, 1, 1), position=(20, 20, 0))
    moved = _matrix(rotation=(0, 0, 0), scale=(1, 1, 1), position=(21, 20, 0))
    duplicate_a = SceneryInstance(0, "PILLAR", transform, 100, 0, object_hash=123, section_index=3)
    duplicate_b = SceneryInstance(0, "PILLAR", transform, 200, 7, object_hash=999, section_index=33)
    distinct_transform = SceneryInstance(0, "PILLAR", moved, 300, 1, object_hash=123, section_index=4)
    distinct_model = SceneryInstance(1, "OTHER", transform, 400, 2, object_hash=456, section_index=3)
    source = Scene(
        objects=[prop, other],
        scenery_instances=[duplicate_a, duplicate_b, distinct_transform, distinct_model],
        scenery_template_offsets={2, 3},
    )

    result = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST")
    prop_placements = [placement for placement in result.placements if placement.element_type == "object"]

    assert len(source.scenery_instances) == 4  # MTA optimization must not mutate the parsed HP2 scene.
    assert len(prop_placements) == 3
    assert Counter(placement.source_name for placement in prop_placements) == {"PILLAR": 2, "OTHER": 1}
    assert result.report["source_placements"] == 4
    assert result.report["unique_source_placements"] == 3
    assert result.report["duplicate_placement_groups"] == 1
    assert result.report["duplicate_placements_removed"] == 1
    assert result.report["max_duplicate_placement_multiplicity"] == 2
    assert result.report["triangle_loss"] is False


def test_mta_scene_deduplicates_water_before_generating_quads():
    water = _triangle_object("WATER", 4)
    transform = _matrix(rotation=(0, 0, 0), scale=(1, 1, 1))
    source = Scene(
        objects=[water],
        scenery_instances=[
            SceneryInstance(0, "WATER", transform, 100, 0, object_hash=789, section_index=1),
            SceneryInstance(0, "WATER", transform, 200, 0, object_hash=789, section_index=31),
        ],
        scenery_template_offsets={4},
    )

    result = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST")

    assert len(source.scenery_instances) == 2
    assert result.report["unique_source_placements"] == 1
    assert result.report["duplicate_placements_removed"] == 1
    assert result.report["excluded_scenery_placements"] == {"WATER": 1}
    assert result.report["water_source_triangles"] == 1
    assert len(result.water_quads) == 1
    water_report = result.report["water_generation"][0]
    assert water_report["source"] == "WATER"
    assert water_report["generation_mode"] == "edge_aware_trapezoid_decomposition"
    assert water_report["scanline_intervals"] == 1
    assert water_report["quads"] == 1
    assert water_report["safe_quad_budget"] == 120
    assert water_report["height_layers"] == 1
    assert water_report["road_exclusion_bands"] == 0
    assert water_report["shared_edge_mismatches"] == 0
    assert water_report["edge_padding"] == 8.0
    assert water_report["water_area_after_edge_padding"] > water_report["water_area_before_road_clip"]
    assert water_report["corner_order"] == "SW_SE_NW_NE"
    south_west, south_east, north_west, north_east = result.water_quads[0].corners
    assert south_west[0:1] == (10.0,)
    assert south_east[0:1] == (20.0,)
    assert south_west[1] < -20.0
    assert north_west[0] < 10.0
    assert north_east[0] > north_west[0]


def test_mta_water_cells_are_removed_when_hp2_primary_road_overlaps_them():
    water = _triangle_object("WATER", 4)
    transform = _matrix(rotation=(0, 0, 0), scale=(1, 1, 1))
    road = TrackCollisionPolygon(
        0, 0, 1, 0x00, 4,
        (Vec3(0, -50, 0), Vec3(50, -50, 0), Vec3(50, 0, 0), Vec3(0, 0, 0)),
        0, 0,
    )
    source = Scene(
        objects=[water],
        scenery_instances=[SceneryInstance(0, "WATER", transform, 100, 0)],
        scenery_template_offsets={4},
        track_collision_polygons=[road],
    )

    result = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST", water_edge_padding=0.0)

    assert result.water_quads == []
    assert result.report["water_generation"][0]["road_exclusion_bands"] == 1
    assert result.report["water_generation"][0]["water_area_after_road_clip"] == 0.0


def test_mta_water_union_removes_internal_triangle_seam():
    first = VifVertexRun(
        vertices=(Vec3(0, 0, 0), Vec3(10, 0, 0), Vec3(0, 10, 0)),
        texcoords=((0, 0), (1, 0), (0, 1)),
        packed_values=(0xFFFF, 0x83E0, 0x801F), header=None, tri_cull=None,
    )
    second = VifVertexRun(
        vertices=(Vec3(10, 0, 0), Vec3(10, 10, 0), Vec3(0, 10, 0)),
        texcoords=((1, 0), (1, 1), (0, 1)),
        packed_values=(0xFFFF, 0x83E0, 0x801F), header=None, tri_cull=None,
    )
    water = MeshObject(
        "WATER", 4,
        IDENTITY4,
        (DecodedBlock(first, primitive_mode="triangles"), DecodedBlock(second, primitive_mode="triangles")),
        (), 123,
    )
    source = Scene(
        objects=[water],
        scenery_instances=[SceneryInstance(0, "WATER", _matrix(rotation=(0, 0, 0), scale=(1, 1, 1)), 1, 0)],
        scenery_template_offsets={4},
    )

    result = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST", water_edge_padding=0.0)

    report = result.report["water_generation"][0]
    assert len(result.water_quads) == 1
    assert report["water_union_components"] == 1
    assert report["water_area_before_road_clip"] == pytest.approx(100.0)
    assert report["water_area_after_road_clip"] == pytest.approx(100.0)
    assert report["shared_edge_mismatches"] == 0


def test_prop_recentering_preserves_world_vertices_with_negative_nonuniform_scale():
    prop = _triangle_object("PILLAR", 2)
    source_placement = SceneryInstance(
        0,
        "PILLAR",
        _matrix(rotation=(31.0, -17.0, 123.0), scale=(-0.75, 1.25, 2.0), position=(-305.0, 298.0, 17.0)),
        3,
        0,
    )
    source = Scene(objects=[prop], scenery_instances=[source_placement], scenery_template_offsets={2})
    result = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST", collision_mode="bounds-only")
    model = next(model for model in result.models if model.kind == "prop")
    placement = next(placement for placement in result.placements if placement.element_type == "object")
    rotation = compose_zxy_row(placement.rotation)
    output_world = [
        tuple(
            sum(vertex[source_axis] * rotation[source_axis][axis] for source_axis in range(3))
            + placement.position[axis]
            for axis in range(3)
        )
        for vertex in model.vertices
    ]
    source_world = []
    for point in (Vec3(0, 0, 0), Vec3(10, 0, 0), Vec3(0, 10, 0)):
        transformed = transform_point(point, source_placement.transform)
        source_world.append((transformed.x, transformed.y, transformed.z))
    for actual, expected in zip(output_world, source_world):
        assert actual == pytest.approx(expected, abs=1e-5)
    assert placement.zone == "t31_xm002_yp000"


def test_eagle_img_override_and_water_files(tmp_path):
    declarations = _img_archive_declarations(
        [tmp_path / "dff.img", tmp_path / "dff_1.img", tmp_path / "col.img", tmp_path / "txd.img"]
    )
    assert declarations == [
        {"name": "dff", "max": 1},
        {"name": "col", "max": 0},
        {"name": "txd", "max": 0},
    ]

    placeholder = _write_water_dat(tmp_path, None)
    assert placeholder == {"status": "placeholder", "source": None, "bytes": 1}
    assert (tmp_path / "water.dat").read_bytes() == b"\n"
    supplied = tmp_path / "source-water.dat"
    supplied.write_bytes(b"water payload\r\n")
    copied = _write_water_dat(tmp_path, supplied)
    assert copied["status"] == "copied"
    assert (tmp_path / "water.dat").read_bytes() == b"water payload\r\n"


def test_water_dat_is_generated_from_scene_mesh_with_offset(tmp_path):
    scene = build_mta_scene(Scene(), TextureLibrary({}), track_id=31, resource_name="TEST")
    scene.water_quads = [
        MtaWaterQuad(((1, 2, 3), (4, 2, 3), (1, 5, 3), (4, 5, 3)))
    ]
    report = _write_water_dat(tmp_path, None, scene, (10, -20, 2))
    values = [float(value) for value in (tmp_path / "water.dat").read_text().split()]
    assert report["status"] == "generated"
    assert report["quads"] == 1
    assert len(values) == 29
    assert values[0:3] == [11, -18, 5]
    assert values[7:10] == [14, -18, 5]
    assert values[-1] == 1


def test_water_dat_rejects_invalid_mta_corner_order_and_pool_overflow(tmp_path):
    scene = build_mta_scene(Scene(), TextureLibrary({}), track_id=31, resource_name="TEST")
    scene.water_quads = [
        MtaWaterQuad(((0, 10, 0), (10, 0, 0), (0, 0, 0), (10, 10, 0)))
    ]
    with pytest.raises(ValueError, match="SW,SE,NW,NE"):
        _write_water_dat(tmp_path, None, scene)

    valid = MtaWaterQuad(((0, 0, 0), (10, 0, 0), (0, 10, 0), (10, 10, 0)))
    scene.water_quads = [valid] * 121
    with pytest.raises(ValueError, match="safe MTA pool budget is 120"):
        _write_water_dat(tmp_path, None, scene)


def test_resource_xml_uses_global_names_for_default_img_archives(tmp_path):
    source = Scene(objects=[_triangle_object("ROAD", 1)])
    scene = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST", collision_mode="bounds-only")
    archives = [tmp_path / "imgs" / "dff.img", tmp_path / "imgs" / "dff_2.img", tmp_path / "imgs" / "txd.img"]
    declarations = _write_resource_xml(scene, tmp_path, "tester", archives, (0.0, 0.0, 0.0))
    assert declarations == [{"name": "dff", "max": 2}, {"name": "txd", "max": 0}]
    assert not (tmp_path / "eagleLoader-imgs.xml").exists()
    meta_sources = {node.attrib["src"] for node in ET.parse(tmp_path / "meta.xml").getroot().findall("file")}
    assert "eagleLoader-imgs.xml" not in meta_sources
    assert {"imgs/dff.img", "imgs/dff_2.img", "imgs/txd.img"} <= meta_sources
    assert "water.dat" in meta_sources


def test_resource_xml_adds_override_only_for_custom_img_names(tmp_path):
    source = Scene(objects=[_triangle_object("ROAD", 1)])
    scene = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST", collision_mode="bounds-only")
    archives = [tmp_path / "imgs" / "city_models.img", tmp_path / "imgs" / "city_models_2.img"]
    _write_resource_xml(scene, tmp_path, "tester", archives, (0.0, 0.0, 0.0))
    root = ET.parse(tmp_path / "eagleLoader-imgs.xml").getroot()
    assert root.tag == "eagleLoader"
    assert [(node.attrib["name"], node.attrib["max"]) for node in root.findall("img")] == [("city_models", "2")]
    meta_sources = {node.attrib["src"] for node in ET.parse(tmp_path / "meta.xml").getroot().findall("file")}
    assert "eagleLoader-imgs.xml" in meta_sources


def test_every_mta_definition_references_same_name_col(tmp_path):
    source = Scene(objects=[_triangle_object("ROAD", 1)])
    scene = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST", collision_mode="bounds-only")
    _write_resource_xml(scene, tmp_path, "tester", [tmp_path / "imgs" / "dff.img"], (0.0, 0.0, 0.0))
    nodes = [
        node
        for path in (tmp_path / "zones").rglob("*.definition")
        for node in ET.parse(path).getroot().findall("definition")
    ]
    assert nodes
    assert all(node.attrib["id"] == node.attrib["dff"] == node.attrib["col"] for node in nodes)
    assert all(node.attrib["disable_backface_culling"] == "true" for node in nodes)
    assert all(node.attrib["flags"] == "disable_backface_culling" for node in nodes)
    placements = [
        node
        for path in (tmp_path / "zones").rglob("*.map")
        for node in ET.parse(path).getroot()
        if node.tag in {"object", "building"}
    ]
    assert placements
    assert all(node.attrib["overrideFlags"] == "double_sided" for node in placements)


def test_water_and_skydome_are_excluded_from_visual_models():
    road = _triangle_object("RD_SECTION10_CHOP1", 1)
    sky = _triangle_object("SKYDOME", 2)
    sky_prop = _triangle_object("SKYDOME_ENVMAP", 3)
    water = _triangle_object("WATER", 4)
    source = Scene(
        objects=[road, sky, sky_prop, water],
        scenery_instances=[
            SceneryInstance(0, "SKYDOME_ENVMAP", _matrix(rotation=(0, 0, 0), scale=(1, 1, 1)), 3, 0),
            SceneryInstance(0, "WATER", _matrix(rotation=(0, 0, 0), scale=(1, 1, 1)), 4, 1),
        ],
        scenery_template_offsets={3, 4},
    )
    result = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST")
    assert [model.source_name for model in result.models] == ["RD_SECTION10_CHOP1"]
    assert result.report["excluded_static_models"] == ["SKYDOME"]
    assert result.report["excluded_scenery_placements"] == {"SKYDOME_ENVMAP": 1, "WATER": 1}
    assert result.report["water_source_triangles"] == 1
    assert len(result.water_quads) == 1


def test_cell_uses_floor_for_negative_coordinates():
    assert cell_for_xy(-0.1, -300.0, 300.0) == (-1, -1)


def test_oversized_road_splits_visible_dff_and_matching_mesh_col():
    source = Scene(objects=[_two_cluster_road()])
    result = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST")
    roads = [model for model in result.models if model.kind == "road"]
    assert len(roads) == 2
    assert sum(len(model.faces) for model in roads) == 2
    assert all(model.collision_faces == model.faces for model in roads)
    assert all(max(abs(value) for vertex in model.vertices for value in vertex) <= 255.0 for model in roads)
    assert result.report["road_split_sources"] == [
        {"source": "RD_SECTION40_CHOP1", "parts": 2, "reason": "col3_coordinate_or_vertex_limit"}
    ]
    assert result.report["triangle_loss"] is False


def test_bounds_only_mode_keeps_same_name_col_without_physical_faces():
    source = Scene(objects=[_triangle_object("RD_SECTION10_CHOP1", 1), _triangle_object("SKYDOME", 2)])
    result = build_mta_scene(
        source,
        TextureLibrary({}),
        track_id=31,
        resource_name="TEST",
        collision_mode="bounds-only",
    )
    assert all(model.collision_kind == "bounds" for model in result.models)
    assert all(not model.collision_faces for model in result.models)
    assert result.report["mesh_col_models"] == 0
    assert result.report["bounds_only_col_models"] == len(result.models)


def test_legacy_track_collision_modes_are_rejected():
    with pytest.raises(ValueError, match="TrackCollisionPolygon-based modes were removed"):
        build_mta_scene(
            Scene(objects=[_triangle_object("RD_SECTION10_CHOP1", 1)]),
            TextureLibrary({}),
            track_id=31,
            resource_name="TEST",
            collision_mode="track",
        )


def test_large_single_scenery_is_promoted_chunked_and_gets_linked_lod(tmp_path):
    prop = _triangle_object("MOUNTAIN", 2)
    placement = SceneryInstance(
        0,
        "MOUNTAIN",
        _matrix(rotation=(0, 0, 0), scale=(80, 80, 1), position=(-50, -50, 0)),
        3,
        0,
    )
    source = Scene(objects=[prop], scenery_instances=[placement], scenery_template_offsets={2})
    result = build_mta_scene(
        source, TextureLibrary({}), track_id=31, resource_name="TEST",
        collision_mode="bounds-only", chunk_size=300,
    )

    detail = [model for model in result.models if model.kind == "static_scenery"]
    lods = [model for model in result.models if model.is_lod]
    assert detail and lods
    assert all(model.model_id == "LOD" + model.lod_source_id[3:] for model in lods)
    assert all(placement.element_type == "building" for placement in result.placements)
    assert result.report["large_props_promoted_to_static"][0]["source"] == "MOUNTAIN"
    assert all(model.lod_distance == 299.0 for model in detail)
    assert result.report["max_chunk_xy_extent"] <= 300.000001
    assert result.report["max_logical_pivot_error"] <= 0.001

    _write_resource_xml(result, tmp_path, "tester", [tmp_path / "imgs" / "dff.img"], (0, 0, 0))
    nodes = [
        node for path in (tmp_path / "zones").rglob("*.map")
        for node in ET.parse(path).getroot() if node.tag == "building"
    ]
    linked = [node for node in nodes if "lodParent" in node.attrib]
    assert linked
    by_pair = {(node.attrib["id"], node.attrib.get("uniqueID")): node for node in nodes}
    for node in linked:
        assert (node.attrib["lodParent"], node.attrib["uniqueID"]) in by_pair
        assert node.attrib["lodParent"] == "LOD" + node.attrib["id"][3:]
    for path in (tmp_path / "zones").rglob("*.definition"):
        ids = [node.attrib["id"] for node in ET.parse(path).getroot().findall("definition")]
        first_lod = next((index for index, value in enumerate(ids) if value.startswith("LOD")), len(ids))
        assert all(not value.startswith("LOD") for value in ids[:first_lod])
        assert all(value.startswith("LOD") for value in ids[first_lod:])


def test_repeated_large_template_remains_reusable_prop():
    prop = _triangle_object("REPEATED_MOUNTAIN", 2)
    source = Scene(
        objects=[prop],
        scenery_instances=[
            SceneryInstance(0, prop.name, _matrix(scale=(20, 20, 1), position=(0, 0, 0)), 3, 0),
            SceneryInstance(0, prop.name, _matrix(scale=(20, 20, 1), position=(500, 0, 0)), 4, 1),
        ],
        scenery_template_offsets={2},
    )
    result = build_mta_scene(source, TextureLibrary({}), track_id=31, resource_name="TEST", collision_mode="bounds-only")
    assert len([model for model in result.models if model.kind == "prop"]) == 1
    assert len([placement for placement in result.placements if placement.element_type == "object"]) == 2
    assert result.report["large_props_promoted_to_static"] == []


def test_mixed_render_companions_share_streaming_pivot():
    source = Scene(objects=[_mixed_alpha_object()])
    textures = TextureLibrary({100: _alpha_texture("SOLID", blend=False), 200: _alpha_texture("SHADOW", blend=True)})
    result = build_mta_scene(source, textures, track_id=31, resource_name="TEST", collision_mode="bounds-only")
    base = next(model for model in result.models if model.render_layer == "base")
    blend = next(model for model in result.models if model.render_layer == "blend")
    assert base.origin == blend.origin
    positions = {placement.position for placement in result.placements}
    assert positions == {base.origin}


def test_eagle_meshoptimizer_lod_preserves_source_texture_material_and_uv():
    texture = _alpha_texture("MOUNTAIN_ROCK", blend=False)
    prop = _triangle_object("MOUNTAIN", 2, texture_hashes=(100,))
    placement = SceneryInstance(
        0, prop.name,
        _matrix(rotation=(0, 0, 0), scale=(80, 80, 1), position=(-50, -50, 0)),
        3, 0,
    )
    result = build_mta_scene(
        Scene(objects=[prop], scenery_instances=[placement], scenery_template_offsets={2}),
        TextureLibrary({100: texture}), track_id=31, resource_name="TEST", collision_mode="bounds-only",
    )
    _prepare_eagle_lods(result)

    lods = [model for model in result.models if model.is_lod]
    assert lods
    sources = {model.model_id: model for model in result.models if not model.is_lod}
    for lod in lods:
        source = sources[lod.lod_source_id]
        assert [material.texture_name for material in lod.materials] == [material.texture_name for material in source.materials]
        assert set(lod.uvs) <= set(source.uvs)
        assert all(0 <= material < len(lod.materials) for material in lod.face_materials)
    assert {entry["algorithm"] for entry in result.report["lod_generation"]} == {
        "MTA-Eagle-Editor meshoptimizer 0.6.2"
    }
    assert {entry["texture_strategy"] for entry in result.report["lod_generation"]} == {
        "reuse source track TXD with exact material names and UVs"
    }
