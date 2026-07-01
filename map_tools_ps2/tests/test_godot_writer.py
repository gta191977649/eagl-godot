import json
import struct

from map_tools_ps2.binary import IDENTITY4, Vec3
from map_tools_ps2.godot_writer import write_godot_track_package
from map_tools_ps2.model import (
    AllowedRoadArea,
    DecodedBlock,
    MeshObject,
    Scene,
    SceneryInstance,
    ScenerySection,
    SolidPack,
    TrackCollisionPolygon,
    TrackRouteEdge,
    TrackRoutePoint,
    TrackRouteSegment,
)
from map_tools_ps2.textures import Texture, TextureLibrary
from map_tools_ps2.vif import VifVertexRun


def _scene() -> Scene:
    run = VifVertexRun(
        vertices=(Vec3(0.0, 0.0, 0.0), Vec3(1.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0)),
        texcoords=((0.0, 0.0), (1.0, 0.0), (0.0, 1.0)),
        packed_values=(0xFFFF, 0x83E0, 0x801F),
        header=(),
        tri_cull=(),
    )
    block = DecodedBlock(
        run=run,
        primitive_mode="triangles",
        texture_index=0,
        render_flag=0x4041,
        expected_face_count=1,
        topology_code=0x05,
        source_offset=0x20,
        source_qword_size=2,
    )
    obj = MeshObject(
        name="XT_TREE",
        chunk_offset=0x1000,
        transform=IDENTITY4,
        blocks=(block,),
        texture_hashes=(0x12345678,),
        name_hash=0x87654321,
    )
    instance = SceneryInstance(
        object_index=0,
        object_name="XT_TREE",
        transform=IDENTITY4,
        source_chunk_offset=0x3000,
        record_index=7,
        scenery_info_index=1,
        object_hash=0x87654321,
        section_index=2,
        section_chunk_offset=0x2000,
    )
    scene = Scene(
        objects=[obj],
        scenery_instances=[instance],
        scenery_template_offsets={0x1000},
        solid_packs=[SolidPack(0, 0x900, True, (0x1000,))],
        scenery_sections=[ScenerySection(2, 0x2000, ((0x87654321, 0, 0),), (instance,))],
    )
    return scene


def _textures() -> TextureLibrary:
    return TextureLibrary(
        {
            0x12345678: Texture(
                name="TREE",
                tex_hash=0x12345678,
                width=1,
                height=1,
                data_offset=0,
                palette_offset=0,
                data_size=0,
                palette_size=0,
                source_path=__file__,
                png=b"\x89PNG\r\n\x1a\n",
                has_alpha=False,
                alpha_mode=None,
                alpha_cutoff=None,
            )
        }
    )


def _collision_polygon(*, index: int = 0, flags: int = 0x00) -> TrackCollisionPolygon:
    points = (
        Vec3(0.0, 0.0, 0.0),
        Vec3(2.0, 0.0, 0.0),
        Vec3(2.0, 2.0, 0.0),
        Vec3(0.0, 2.0, 0.0),
    )
    vertex_count = 4 if flags & 0x10 else 3
    return TrackCollisionPolygon(
        index=index,
        material_id=7,
        flags=flags,
        vertex_count=vertex_count,
        points_ps2=points[:vertex_count],
        source_chunk_offset=0x34132000,
        source_record_offset=index * 0x20,
    )


def _degenerate_collision_polygon(*, index: int = 0) -> TrackCollisionPolygon:
    return TrackCollisionPolygon(
        index=index,
        material_id=7,
        flags=0x00,
        vertex_count=3,
        points_ps2=(
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
        ),
        source_chunk_offset=0x34132000,
        source_record_offset=index * 0x20,
    )


def test_write_godot_track_package_manifest_and_binary(tmp_path) -> None:
    manifest_path = write_godot_track_package(_scene(), tmp_path, "TRACKB31", _textures())

    manifest = json.loads(manifest_path.read_text())
    binary_path = tmp_path / manifest["binary"]["path"]
    texture_path = tmp_path / manifest["textures"][0]["path"]

    assert manifest["version"] == 2
    assert manifest["track_id"] == "31"
    assert binary_path.exists()
    assert texture_path.exists()
    assert manifest["stats"]["exported_object_count"] == 1
    assert manifest["stats"]["scenery_instance_count"] == 1
    assert manifest["collision"]["version"] == 1
    assert manifest["collision"]["surfaces"] == []
    assert manifest["collision"]["stats"]["collision_source"] == "track_collision_polygons"
    assert manifest["objects"][0]["surfaces"][0]["positions"]["count"] == 3
    assert manifest["objects"][0]["surfaces"][0]["indices"]["count"] == 3
    assert manifest["objects"][0]["is_scenery_template"] is True


def test_write_godot_track_package_does_not_duplicate_scenery_geometry(tmp_path) -> None:
    scene = _scene()
    first = scene.scenery_instances[0]
    scene.scenery_instances.append(
        SceneryInstance(
            object_index=first.object_index,
            object_name=first.object_name,
            transform=first.transform,
            source_chunk_offset=first.source_chunk_offset,
            record_index=8,
            object_hash=first.object_hash,
            section_index=first.section_index,
        )
    )

    manifest_path = write_godot_track_package(scene, tmp_path, "TRACKB31", _textures())
    manifest = json.loads(manifest_path.read_text())

    assert manifest["stats"]["scenery_instance_count"] == 2
    assert manifest["stats"]["exported_object_count"] == 1
    assert len(manifest["objects"][0]["surfaces"]) == 1


def test_write_godot_track_package_keeps_static_mesh_local_and_preserves_transform(tmp_path) -> None:
    run = VifVertexRun(
        vertices=(Vec3(0.0, 0.0, 0.0), Vec3(1.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0)),
        texcoords=(),
        packed_values=(),
        header=(),
        tri_cull=(),
    )
    block = DecodedBlock(run=run, primitive_mode="triangles")
    translated = (
        (1.0, 0.0, 0.0, 0.0),
        (0.0, 1.0, 0.0, 0.0),
        (0.0, 0.0, 1.0, 0.0),
        (10.0, 20.0, 30.0, 1.0),
    )
    scene = Scene(
        objects=[
            MeshObject(
                name="RD_SECTION",
                chunk_offset=0x1100,
                transform=translated,
                blocks=(block,),
            )
        ],
        solid_packs=[SolidPack(1, 0xA00, False, (0x1100,))],
    )

    manifest_path = write_godot_track_package(scene, tmp_path, "TRACKB31", _textures())
    manifest = json.loads(manifest_path.read_text())
    binary = (tmp_path / manifest["binary"]["path"]).read_bytes()
    position_spec = manifest["objects"][0]["surfaces"][0]["positions"]
    first_vertex = struct.unpack_from("<3f", binary, position_spec["offset"])
    pivot = manifest["objects"][0]["pivot"]

    assert manifest["objects"][0]["is_scenery_template"] is False
    assert manifest["objects"][0]["transform"] == [
        [1.0, 0.0, 0.0, 0.0],
        [0.0, 1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0],
        [10.5, 20.5, 30.0, 1.0],
    ]
    assert pivot == [0.5, 0.0, -0.5]
    assert first_vertex == (-0.5, 0.0, 0.5)


def test_write_godot_track_package_recenters_instance_mesh_and_adjusts_placement(tmp_path) -> None:
    scene = _scene()

    manifest_path = write_godot_track_package(scene, tmp_path, "TRACKB31", _textures())
    manifest = json.loads(manifest_path.read_text())
    binary = (tmp_path / manifest["binary"]["path"]).read_bytes()
    position_spec = manifest["objects"][0]["surfaces"][0]["positions"]
    first_vertex = struct.unpack_from("<3f", binary, position_spec["offset"])
    instance_transform = manifest["scenery_instances"][0]["transform"]

    assert manifest["objects"][0]["pivot"] == [0.5, 0.0, -0.5]
    assert first_vertex == (-0.5, 0.0, 0.5)
    assert instance_transform == [
        [1.0, 0.0, 0.0, 0.0],
        [0.0, 1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0],
        [0.5, 0.5, 0.0, 1.0],
    ]


def test_write_godot_track_package_exports_collision_surfaces_from_track_polygons(tmp_path) -> None:
    route_point = TrackRoutePoint(
        index=0,
        position_ps2=Vec3(10.0, 20.0, 30.0),
        forward_ps2_2d=(1.0, 0.0),
        segment_length=12.0,
        left_width=4.0,
        right_width=5.0,
        route_edge_index=3,
        route_edge_flags=3,
        boundary_offsets_raw=(1, 2, 3, 4),
        boundary_offsets=(0.1, 0.2, 0.3, 0.4),
        source_record_offset=0x80,
    )
    scene = Scene(
        track_collision_polygons=[_collision_polygon(index=0, flags=0x00), _collision_polygon(index=1, flags=0x10)],
        track_route_segments=[
            TrackRouteSegment(
                index=0,
                route_index=50,
                route_type=1,
                flags=1,
                points=(route_point,),
                source_chunk_offset=0x34121000,
                source_record_offset=0,
            )
        ],
        track_route_edges=[
            TrackRouteEdge(
                index=0,
                target_route_index=60,
                mode=2,
                target_point_index=7,
                metadata0=123,
                metadata1=456,
                source_chunk_offset=0x34122000,
                source_record_offset=0,
            )
        ],
        allowed_road_areas=[
            AllowedRoadArea(
                index=0,
                declared_vertex_count=4,
                points_ps2_2d=((0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)),
                metadata=b"\x01\x02\x03\x04\x05\x06\x07\x08",
                source_chunk_offset=0x34530000,
                source_record_offset=4,
                source_metadata_offset=0x34,
            )
        ],
    )

    manifest_path = write_godot_track_package(scene, tmp_path, "TRACKB31", _textures())
    manifest = json.loads(manifest_path.read_text())

    assert manifest["collision"]["version"] == 1
    assert manifest["collision"]["stats"]["surface_count"] == 2
    assert manifest["collision"]["stats"]["triangle_count"] == 3
    assert manifest["collision"]["stats"]["valid_triangle_count"] == 3
    assert manifest["collision"]["stats"]["candidate_triangle_count"] == 3
    assert manifest["collision"]["stats"]["filtered_triangle_count"] == 0
    assert manifest["collision"]["stats"]["bounds"] == {
        "min": [0.0, 0.0, -2.0],
        "max": [2.0, 0.0, -0.0],
    }
    assert manifest["collision"]["stats"]["track_collision_polygon_count"] == 2
    assert manifest["collision"]["stats"]["track_collision_drive_area_polygon_count"] == 2
    assert manifest["collision"]["stats"]["track_route_segment_count"] == 1
    assert manifest["collision"]["stats"]["track_route_edge_count"] == 1
    assert manifest["collision"]["stats"]["allowed_road_area_count"] == 1
    assert manifest["collision"]["stats"]["collision_source"] == "track_collision_polygons"
    assert manifest["collision"]["surfaces"][0]["category"] == "Road"
    assert manifest["collision"]["surfaces"][0]["source_kind"] == "track_polygon_collision_area"
    assert manifest["collision"]["surfaces"][0]["source_name"] == "TRACK_POLYGON_COLLISION_AREA_000000"
    assert manifest["collision"]["surfaces"][0]["triangle_count"] == 1
    assert manifest["collision"]["surfaces"][0]["valid_triangle_count"] == 1
    assert manifest["collision"]["surfaces"][0]["candidate_triangle_count"] == 1
    assert manifest["collision"]["surfaces"][0]["filtered_triangle_count"] == 0
    assert manifest["collision"]["surfaces"][0]["aabb"] == {
        "min": [0.0, 0.0, -2.0],
        "max": [2.0, 0.0, -0.0],
    }
    assert manifest["collision"]["surfaces"][1]["triangle_count"] == 2
    assert manifest["stats"]["collision_surface_count"] == 2
    assert manifest["stats"]["collision_triangle_count"] == 3
    assert manifest["stats"]["track_collision_polygon_count"] == 2
    assert manifest["stats"]["track_collision_drive_area_polygon_count"] == 2
    assert manifest["stats"]["track_route_segment_count"] == 1
    assert manifest["stats"]["track_route_edge_count"] == 1
    assert manifest["stats"]["allowed_road_area_count"] == 1
    assert manifest["stats"]["collision_source"] == "track_collision_polygons"


def test_write_godot_track_package_keeps_drive_area_polygons_as_individual_surfaces(tmp_path) -> None:
    scene = Scene(
        track_collision_polygons=[
            _collision_polygon(index=0, flags=0x00),
            _collision_polygon(index=1, flags=0x10),
            _collision_polygon(index=2, flags=0x00),
        ]
    )

    manifest_path = write_godot_track_package(scene, tmp_path, "TRACKB31", _textures())
    manifest = json.loads(manifest_path.read_text())

    surfaces = manifest["collision"]["surfaces"]
    assert len(surfaces) == 3
    assert [surface["source_name"] for surface in surfaces] == [
        "TRACK_POLYGON_COLLISION_AREA_000000",
        "TRACK_POLYGON_COLLISION_AREA_000001",
        "TRACK_POLYGON_COLLISION_AREA_000002",
    ]
    assert [surface["source_record_offset"] for surface in surfaces] == [0x00, 0x20, 0x40]
    assert [surface["triangle_count"] for surface in surfaces] == [1, 2, 1]
    assert [surface["candidate_triangle_count"] for surface in surfaces] == [1, 2, 1]
    assert manifest["collision"]["stats"]["surface_count"] == 3
    assert manifest["collision"]["stats"]["triangle_count"] == 4


def test_write_godot_track_package_skips_non_drive_area_polygons(tmp_path) -> None:
    scene = Scene(track_collision_polygons=[_collision_polygon(index=0, flags=0x08), _collision_polygon(index=1, flags=0x12)])

    manifest_path = write_godot_track_package(scene, tmp_path, "TRACKB31", _textures())
    manifest = json.loads(manifest_path.read_text())

    assert manifest["collision"]["surfaces"] == []
    assert manifest["collision"]["stats"]["track_collision_polygon_count"] == 2
    assert manifest["collision"]["stats"]["track_collision_drive_area_polygon_count"] == 0
    assert manifest["collision"]["stats"]["candidate_triangle_count"] == 0
    assert manifest["collision"]["stats"]["filtered_triangle_count"] == 0
    assert manifest["collision"]["stats"]["bounds"] is None


def test_write_godot_track_package_filters_degenerate_collision_polygons(tmp_path) -> None:
    scene = Scene(track_collision_polygons=[_degenerate_collision_polygon(index=0)])

    manifest_path = write_godot_track_package(scene, tmp_path, "TRACKB31", _textures())
    manifest = json.loads(manifest_path.read_text())

    assert manifest["collision"]["surfaces"] == []
    assert manifest["collision"]["stats"]["enabled"] is False
    assert manifest["collision"]["stats"]["candidate_triangle_count"] == 1
    assert manifest["collision"]["stats"]["valid_triangle_count"] == 0
    assert manifest["collision"]["stats"]["filtered_triangle_count"] == 1
    assert manifest["collision"]["stats"]["bounds"] is None
