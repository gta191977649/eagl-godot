from pathlib import Path
from tempfile import TemporaryDirectory
import os
import unittest

from map_tools_ps2.binary import IDENTITY4, Vec3, Vec4, compose_matrix4, transform_point
from map_tools_ps2.bounds_benchmark import _bounds_error, benchmark_bounds_against_metadata
from map_tools_ps2.cli import _resolve_track_input
from map_tools_ps2.chunks import parse_chunks
from map_tools_ps2.comp import decompress_lzc, load_bundle_bytes
from map_tools_ps2.debug_writer import write_ps2mesh_debug
from map_tools_ps2.glb_writer import (
    GlbBuilder,
    _dedupe_object_faces,
    _fan_indices,
    _indices_for_block,
    _native_gltf_mode_for_block,
    _native_segment_triangle_indices_if_needed,
    _native_strip_segments,
    _indices_for_run,
    _objects_for_glb_export,
    _ps2_to_gltf_vec3,
    _should_double_side_alpha,
    _should_export_vif_colors,
    _should_prioritize_target_count,
    _should_replace_topology,
    _should_skip_object,
    _strip_indices,
    _strip_indices_for_vertices,
    _topology_score,
    _texture_hash_for_run,
    write_glb,
)
from map_tools_ps2.gs_dump import (
    GIF_FLG_PACKED,
    GIF_REG_RGBAQ,
    GIF_REG_ST,
    GIF_REG_XYZF2,
    extract_draw_packets_from_path3_transfers,
    extract_draw_packets,
    read_gs_dump,
)
from map_tools_ps2.gs_validate import validate_gsdump_against_track
from map_tools_ps2.model import (
    DecodedBlock,
    MeshObject,
    Scene,
    _extract_blocks_from_strip_entries,
    _find_ascii_name,
    instantiated_mesh_object,
    _read_run_texture_indices,
    _read_run_unknown_counts,
    _strip_vif_prefix,
    parse_scene,
    transformed_block_vertices,
)
from map_tools_ps2.obj_writer import write_obj
from map_tools_ps2.primitive_probe import probe_primitive_rule
from map_tools_ps2.primitive_stream import primitive_stream_for_block
from map_tools_ps2.textures import Texture, _alpha_mode_for_rgba, _alpha_properties_for_rgba, _decode_ps2_alpha, decode_indexed_texture, read_ps2_tpk
from map_tools_ps2.topology_benchmark import benchmark_topology
from map_tools_ps2.vif import VifVertexRun, extract_vif_vertex_runs
from map_tools_ps2.vu1 import VU1_TRANSFORM_MATRIX_ADDR, transform_vu1_position
import struct


TRACKS_ROOT = Path("/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS")
DEFAULT_GSDUMP = Path(
    "/Users/nurupo/Library/Application Support/PCSX2/snaps/Need for Speed - Hot Pursuit 2_SLUS-20362_20260412010044.gs.zst"
)


def _build_packed_draw_payload(prim: int, vertex_count: int) -> bytes:
    low = vertex_count | (1 << 15) | (1 << 46) | (prim << 47) | (GIF_FLG_PACKED << 58) | (3 << 60)
    high = GIF_REG_ST | (GIF_REG_RGBAQ << 4) | (GIF_REG_XYZF2 << 8)
    payload = bytearray(struct.pack("<QQ", low, high))
    for index in range(vertex_count):
        payload.extend(struct.pack("<fffI", index * 0.125, index * 0.25, 1.0, 0))
        rgba = (64 + index) | ((80 + index) << 8) | ((96 + index) << 16) | (128 << 24)
        payload.extend(struct.pack("<IIQ", rgba, struct.unpack("<I", struct.pack("<f", 1.0))[0], 0))
        low_xyz = (100 + index) | ((200 + index) << 32)
        high_xyz = (300 + index) | (64 << 24)
        payload.extend(struct.pack("<QQ", low_xyz, high_xyz))
    return bytes(payload)


class CompTests(unittest.TestCase):
    def test_ea_comp_matches_known_decompressed_bundle(self):
        compressed = TRACKS_ROOT / "TRACKB24.LZC"
        decompressed = TRACKS_ROOT / "TRACKB24.BUN"
        if not compressed.exists() or not decompressed.exists():
            self.skipTest("TRACKB24 fixture is not available")
        self.assertEqual(decompress_lzc(compressed.read_bytes()), decompressed.read_bytes())


class CliTests(unittest.TestCase):
    def test_resolve_track_input_prefers_bun_in_game_dir(self):
        args = type(
            "Args",
            (),
            {
                "input": None,
                "game_dir": "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile",
                "track": 44,
            },
        )()
        self.assertEqual(
            _resolve_track_input(args),
            Path("/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile/ZZDATA/TRACKS/TRACKB44.BUN"),
        )

    def test_export_parser_defaults_vertex_colors_to_auto(self):
        args = __import__("map_tools_ps2.cli", fromlist=["build_parser"]).build_parser().parse_args(
            ["export", "--game-dir", "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile", "--track", "44"]
        )
        self.assertEqual(args.vertex_colors, "auto")
        self.assertFalse(args.expand_instances)

    def test_export_parser_accepts_vertex_colors_override(self):
        args = __import__("map_tools_ps2.cli", fromlist=["build_parser"]).build_parser().parse_args(
            ["export", "--game-dir", "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile", "--track", "44", "--vertex-colors", "always"]
        )
        self.assertEqual(args.vertex_colors, "always")

    def test_export_parser_accepts_expand_instances_override(self):
        args = __import__("map_tools_ps2.cli", fromlist=["build_parser"]).build_parser().parse_args(
            ["export", "--game-dir", "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile", "--track", "44", "--expand-instances"]
        )
        self.assertTrue(args.expand_instances)

    def test_validate_gsdump_parser_defaults_to_track61(self):
        args = __import__("map_tools_ps2.cli", fromlist=["build_parser"]).build_parser().parse_args(
            ["validate-gsdump", "capture.gs.zst", "--game-dir", "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile"]
        )
        self.assertEqual(args.track, 61)
        self.assertEqual(args.object, "TRN_SECTION60_UNDERROAD")

    def test_benchmark_bounds_parser_defaults_to_track61(self):
        args = __import__("map_tools_ps2.cli", fromlist=["build_parser"]).build_parser().parse_args(
            ["benchmark-bounds", "--game-dir", "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile"]
        )
        self.assertEqual(args.track, 61)
        self.assertEqual(args.object, "")

    def test_benchmark_topology_parser_defaults_to_underroad_track61(self):
        args = __import__("map_tools_ps2.cli", fromlist=["build_parser"]).build_parser().parse_args(
            ["benchmark-topology", "--game-dir", "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile"]
        )
        self.assertEqual(args.track, 61)
        self.assertEqual(args.object, "TRN_SECTION60_UNDERROAD")

    def test_export_parser_accepts_native_primitive_assembly(self):
        args = __import__("map_tools_ps2.cli", fromlist=["build_parser"]).build_parser().parse_args(
            [
                "export",
                "--game-dir",
                "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile",
                "--track",
                "61",
                "--primitive-assembly",
                "native",
            ]
        )
        self.assertEqual(args.primitive_assembly, "native")

    def test_export_dual_parser_defaults_to_track61(self):
        args = __import__("map_tools_ps2.cli", fromlist=["build_parser"]).build_parser().parse_args(
            ["export-dual", "--game-dir", "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile"]
        )
        self.assertEqual(args.track, 61)
        self.assertIsNone(args.debug_output)

    def test_probe_primitive_parser_defaults_to_lightpost_batch(self):
        args = __import__("map_tools_ps2.cli", fromlist=["build_parser"]).build_parser().parse_args(
            [
                "probe-primitive",
                "capture.gs.zst",
                "--game-dir",
                "/Users/nurupo/Desktop/ps2/hp2_ps2/GameFile",
            ]
        )
        self.assertEqual(args.track, 61)
        self.assertEqual(args.object, "XS_LIGHTPOSTA_1_00")
        self.assertEqual(args.block, 6)
        self.assertEqual(args.draw, 1761)


class GsDumpTests(unittest.TestCase):
    def test_extract_packed_st_rgbaq_xyzf2_triangle_strip(self):
        payload = _build_packed_draw_payload(0x5C, 4)

        draws = extract_draw_packets_from_path3_transfers((payload,))

        self.assertEqual(len(draws), 1)
        draw = draws[0]
        self.assertEqual(draw.prim_raw, 0x5C)
        self.assertEqual(draw.prim_type, 4)
        self.assertEqual(len(draw.vertices), 4)
        self.assertEqual(draw.vertices[0].x, 100)
        self.assertEqual(draw.vertices[0].y, 200)
        self.assertEqual(draw.vertices[0].z, 300)
        self.assertEqual(draw.vertices[0].fog, 64)
        self.assertFalse(draw.vertices[0].disable_drawing)
        self.assertEqual(draw.st[2], (0.25, 0.5, 1.0))
        self.assertEqual(draw.rgbaq[3], (67, 83, 99, 128, 1.0))

    def test_extract_packed_xyzf2_disable_drawing_bit(self):
        payload = bytearray(_build_packed_draw_payload(0x5C, 3))
        # First XYZF2 qword begins after tag + ST + RGBAQ.
        xyz_high_offset = 16 + 16 + 16 + 8
        high = struct.unpack_from("<Q", payload, xyz_high_offset)[0]
        struct.pack_into("<Q", payload, xyz_high_offset, high | (1 << 47))

        draws = extract_draw_packets_from_path3_transfers((bytes(payload),))

        self.assertTrue(draws[0].vertices[0].disable_drawing)

    def test_extract_packed_triangle_fan_primitive(self):
        payload = _build_packed_draw_payload(0x5D, 5)

        draws = extract_draw_packets_from_path3_transfers((payload,))

        self.assertEqual(len(draws), 1)
        self.assertEqual(draws[0].prim_type, 5)
        self.assertEqual(len(draws[0].vertices), 5)


class GsDumpIntegrationTests(unittest.TestCase):
    def test_supplied_gsdump_contains_strip_and_fan_draws(self):
        dump_path = Path(os.environ.get("HP2_PS2_GSDUMP", DEFAULT_GSDUMP))
        if not dump_path.exists():
            self.skipTest("GS dump fixture is not available")

        dump = read_gs_dump(dump_path)
        draws = extract_draw_packets(dump)
        primitive_types = {draw.prim_type for draw in draws}

        self.assertIn(4, primitive_types)
        self.assertIn(5, primitive_types)

    def test_trackb61_underroad_validation_builds_source_and_gs_report(self):
        dump_path = Path(os.environ.get("HP2_PS2_GSDUMP", DEFAULT_GSDUMP))
        track_path = TRACKS_ROOT / "TRACKB61.LZC"
        if not dump_path.exists() or not track_path.exists():
            self.skipTest("TRACKB61 or GS dump fixture is not available")

        report = validate_gsdump_against_track(track_path, dump_path, object_filter="TRN_SECTION60_UNDERROAD")

        self.assertGreater(report.draw_count, 0)
        self.assertGreater(len(report.source_blocks), 0)
        self.assertIn(4, report.primitive_counts)
        self.assertIn(5, report.primitive_counts)

    def test_lightpost_primitive_probe_selects_strip_restart_when_fixtures_exist(self):
        dump_path = Path(os.environ.get("HP2_PS2_GSDUMP", DEFAULT_GSDUMP))
        track_path = TRACKS_ROOT / "TRACKB61.LZC"
        if not dump_path.exists() or not track_path.exists():
            self.skipTest("TRACKB61 and GS dump fixtures are not available")

        report = probe_primitive_rule(
            track_path,
            dump_path,
            object_name="XS_LIGHTPOSTA_1_00",
            block_index=6,
            draw_index=1761,
        )

        self.assertEqual(report.block_header, (20, 4, 60, 252))
        self.assertEqual(report.topology_code, 0x05)
        self.assertEqual(report.expected_face_count, 10)
        self.assertEqual(report.gs_restart_boundaries, (4, 8, 12, 16))
        self.assertIsNotNone(report.selected)
        self.assertEqual(report.selected.name, "D triangle strip with restart")


class BoundsBenchmarkTests(unittest.TestCase):
    def test_bounds_error_compares_min_and_max_axes(self):
        vertices = (Vec3(-1.0, 2.0, 3.0), Vec3(4.0, 5.0, 6.0))

        self.assertEqual(_bounds_error(vertices, Vec3(-1.0, 2.0, 3.0), Vec3(4.0, 5.0, 6.0)), 0.0)
        self.assertEqual(_bounds_error(vertices, Vec3(-2.0, 2.0, 3.0), Vec3(4.0, 8.0, 6.0)), 3.0)

    def test_trackb61_metadata_bounds_match_local_vertices_when_fixture_exists(self):
        track_path = TRACKS_ROOT / "TRACKB61.LZC"
        if not track_path.exists():
            self.skipTest("TRACKB61 fixture is not available")

        report = benchmark_bounds_against_metadata(track_path)

        self.assertGreater(len(report.records), 0)
        self.assertLess(report.local_stats[2], 0.02)
        self.assertGreater(report.transformed_stats[0], 1.0)


class TopologyBenchmarkTests(unittest.TestCase):
    def test_trackb61_underroad_reports_exporter_dropped_strip_faces_when_fixture_exists(self):
        track_path = TRACKS_ROOT / "TRACKB61.LZC"
        if not track_path.exists():
            self.skipTest("TRACKB61 fixture is not available")

        report = benchmark_topology(track_path, object_filter="TRN_SECTION60_UNDERROAD")

        self.assertEqual(len(report.records), 105)
        self.assertGreater(len(report.changed_records), 0)
        self.assertGreater(report.dropped_face_count, 0)


class TextureTests(unittest.TestCase):
    def test_ps2_full_alpha_maps_to_opaque(self):
        self.assertEqual(_decode_ps2_alpha(0), 0)
        self.assertEqual(_decode_ps2_alpha(0x40), 0x7F)
        self.assertEqual(_decode_ps2_alpha(0x7F), 0xFE)
        self.assertEqual(_decode_ps2_alpha(0x80), 0xFF)

    def test_alpha_mode_ignores_near_opaque_alpha(self):
        self.assertIsNone(_alpha_mode_for_rgba(bytes([1, 2, 3, 250, 4, 5, 6, 255])))

    def test_alpha_mode_distinguishes_mask_from_blend(self):
        self.assertEqual(_alpha_mode_for_rgba(bytes([1, 2, 3, 0, 4, 5, 6, 255])), "MASK")
        self.assertEqual(_alpha_mode_for_rgba(bytes([1, 2, 3, 128, 4, 5, 6, 255])), "BLEND")

    def test_alpha_properties_capture_mask_cutoff(self):
        self.assertEqual(_alpha_properties_for_rgba(bytes([1, 2, 3, 0, 4, 5, 6, 255])), ("MASK", 0.5))
        self.assertEqual(_alpha_properties_for_rgba(bytes([1, 2, 3, 128, 4, 5, 6, 255])), ("BLEND", None))

    def test_alpha_properties_treat_ps2_alpha_one_as_cutout(self):
        mode, cutoff = _alpha_properties_for_rgba(bytes([1, 2, 3, 2, 4, 5, 6, 254]))
        self.assertEqual(mode, "MASK")
        self.assertIsNotNone(cutoff)

    def test_subpage_4bit_texture_indices_are_linear(self):
        palette = b"".join(bytes((index, 0, 0, 0x7F)) for index in range(16))
        rgba = decode_indexed_texture(4, 4, bytes([0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE]), palette)
        self.assertEqual([rgba[offset] for offset in range(0, 16 * 4, 4)], list(range(16)))

    def test_subpage_8bit_texture_indices_are_linear(self):
        palette = b"".join(bytes((index, 0, 0, 0x7F)) for index in range(256))
        image = bytes(range(64)) + bytes(64 * 64 - 64)
        rgba = decode_indexed_texture(64, 64, image, palette)
        self.assertEqual(
            [rgba[offset] for offset in range(0, 16 * 4, 4)],
            [0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23],
        )

    def test_subpage_32color_8bit_texture_indices_are_linear(self):
        palette = b"".join(bytes((index, 0, 0, 0x7F)) for index in range(32))
        rgba = decode_indexed_texture(4, 4, bytes(range(16)), palette)
        self.assertEqual([rgba[offset] for offset in range(0, 16 * 4, 4)], list(range(16)))

    def test_entry_driven_decode_uses_modelulator_page_flip(self):
        palette = b"".join(bytes((index, 0, 0, 0x80)) for index in range(16))
        image = bytes([0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE])

        rgba = decode_indexed_texture(
            4,
            4,
            image,
            palette,
            bit_depth=4,
            shift_width=2,
            shift_height=2,
            pixel_storage_mode=0x14,
            is_swizzled=False,
        )

        self.assertEqual(
            [rgba[offset] for offset in range(0, 16 * 4, 4)],
            [12, 13, 14, 15, 8, 9, 10, 11, 4, 5, 6, 7, 0, 1, 2, 3],
        )

    def test_entry_driven_decode_applies_psmt8_palette_swizzle(self):
        palette = b"".join(bytes((index, 0, 0, 0x80)) for index in range(256))

        rgba = decode_indexed_texture(
            32,
            1,
            bytes(range(32)),
            palette,
            bit_depth=8,
            shift_width=5,
            shift_height=0,
            pixel_storage_mode=0x13,
            is_swizzled=False,
        )

        self.assertEqual(
            [rgba[offset] for offset in range(0, 32 * 4, 4)],
            list(range(8)) + list(range(16, 24)) + list(range(8, 16)) + list(range(24, 32)),
        )

    def test_fixture_billboard_textures_decode_from_0x80_palette_entries(self):
        location_bin = TRACKS_ROOT / "TEX24LOCATION.BIN"
        if not location_bin.exists():
            self.skipTest("TEX24LOCATION.BIN fixture is not available")

        names = {texture.name for texture in read_ps2_tpk(location_bin)}
        self.assertIn("BILLBOARD-REAR", names)
        self.assertIn("BILLBOARD_04", names)


class GlbMaterialTests(unittest.TestCase):
    def test_alpha_roads_are_not_exported_double_sided(self):
        texture = Texture(
            name="W_ROADTUNNELB",
            tex_hash=1,
            width=4,
            height=4,
            data_offset=0,
            palette_offset=0,
            data_size=0,
            palette_size=0,
            source_path=Path("dummy"),
            png=b"",
            has_alpha=True,
            alpha_mode="BLEND",
            alpha_cutoff=None,
        )
        self.assertFalse(_should_double_side_alpha(texture, "RD_SECTION50_TUNNELS_CH", 0x4041))

    def test_alpha_prop_cards_stay_double_sided(self):
        texture = Texture(
            name="BUSH3",
            tex_hash=1,
            width=4,
            height=4,
            data_offset=0,
            palette_offset=0,
            data_size=0,
            palette_size=0,
            source_path=Path("dummy"),
            png=b"",
            has_alpha=True,
            alpha_mode="MASK",
            alpha_cutoff=0.5,
        )
        self.assertTrue(_should_double_side_alpha(texture, "XT_LILLYPAD_LA_00", None))

    def test_material_cache_splits_same_texture_by_alpha_usage_state(self):
        texture = Texture(
            name="W_ROADTUNNELB",
            tex_hash=1,
            width=4,
            height=4,
            data_offset=0,
            palette_offset=0,
            data_size=0,
            palette_size=0,
            source_path=Path("dummy"),
            png=b"png",
            has_alpha=True,
            alpha_mode="BLEND",
            alpha_cutoff=None,
        )
        builder = GlbBuilder(type("Textures", (), {"get": lambda self, tex_hash: texture if tex_hash == 1 else None})())
        road_material = builder.material_for_hash(1, "RD_SECTION50_TUNNELS_CH", 0x4041)
        prop_material = builder.material_for_hash(1, "XT_LILLYPAD_LA_00", None)
        self.assertNotEqual(road_material, prop_material)
        self.assertFalse(builder.materials[road_material]["doubleSided"])
        self.assertTrue(builder.materials[prop_material]["doubleSided"])

    def test_dedupe_object_faces_drops_repeated_coplanar_triangle(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
        )
        emitted: set = set()
        self.assertEqual(_dedupe_object_faces(vertices, [0, 1, 2], emitted), [0, 1, 2])
        self.assertEqual(_dedupe_object_faces(vertices, [2, 1, 0], emitted), [])

    def test_texture_hash_uses_run_metadata_when_present(self):
        texture_hashes = (0x10, 0x20, 0x30)
        self.assertEqual(_texture_hash_for_run(texture_hashes, (2, 0), 0), 0x30)
        self.assertEqual(_texture_hash_for_run(texture_hashes, (2, 0), 1), 0x10)

    def test_texture_hash_falls_back_to_clamped_run_order_without_metadata(self):
        texture_hashes = (0x10, 0x20, 0x30)
        self.assertEqual(_texture_hash_for_run(texture_hashes, (), 0), 0x10)
        self.assertEqual(_texture_hash_for_run(texture_hashes, (), 5), 0x30)

    def test_strip_indices_exports_full_decoded_strip(self):
        self.assertEqual(_strip_indices(0, 5), [0, 1, 2, 1, 3, 2, 2, 3, 4])

    def test_fan_indices_exports_triangle_fan(self):
        self.assertEqual(_fan_indices(3), [0, 1, 2])
        self.assertEqual(_fan_indices(4), [0, 1, 2, 0, 2, 3])
        self.assertEqual(_fan_indices(5), [0, 1, 2, 0, 2, 3, 0, 3, 4])

    def test_indices_for_block_can_emit_triangle_fan(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
        )
        block = DecodedBlock(
            run=VifVertexRun(vertices, (), (), (4, 0, 12, 252)),
            primitive_mode="fan",
        )
        self.assertEqual(_indices_for_block(vertices, "TEST_FAN", block), [0, 1, 2, 0, 2, 3])
        self.assertNotEqual(_indices_for_block(vertices, "TEST_FAN", block), _strip_indices_for_vertices(vertices))

    def test_native_gltf_mode_preserves_strip_and_fan(self):
        strip = DecodedBlock(run=VifVertexRun((), (), (), (0, 0, 0, 0)), primitive_mode="strip")
        fan = DecodedBlock(run=VifVertexRun((), (), (), (0, 0, 0, 0)), primitive_mode="fan")
        self.assertEqual(_native_gltf_mode_for_block(strip), 5)
        self.assertEqual(_native_gltf_mode_for_block(fan), 6)

    def test_native_strip_segments_split_only_large_bridge_edges(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(100.0, 0.0, 0.0),
            Vec3(100.0, 1.0, 0.0),
            Vec3(101.0, 0.0, 0.0),
            Vec3(101.0, 1.0, 0.0),
        )

        self.assertEqual(_native_strip_segments(vertices), ((0, 10),))

    def test_native_strip_segments_split_xb_roof_strip_to_metadata_count(self):
        vertices = (
            Vec3(-1372.1174274030964, 58.004831314086914, 615.6471412993251),
            Vec3(-1379.5557858571583, 58.004831314086914, 598.9402092733926),
            Vec3(-1393.001094670938, 58.004831314086914, 624.9451522407762),
            Vec3(-1400.439453125, 58.004831314086914, 608.2382202148438),
            Vec3(-1413.8847619387798, 58.004831314086914, 634.2431631822274),
            Vec3(-1421.3231203928417, 58.004831314086914, 617.5362311562949),
            Vec3(-1428.76159824969, 58.004831314086914, 600.8293245102068),
            Vec3(-1421.3231203928417, 58.004831314086914, 617.5362311562949),
            Vec3(-1407.8779309818483, 58.004831314086914, 591.5313135687556),
            Vec3(-1400.439453125, 58.004831314086914, 608.2382202148438),
            Vec3(-1386.9942510240844, 58.004831314086914, 582.2333623286977),
            Vec3(-1379.5557858571583, 58.004831314086914, 598.9402092733926),
        )
        block = DecodedBlock(
            run=VifVertexRun(vertices, (), (), (12, 0, 0, 0)),
            primitive_mode="strip",
            expected_face_count=8,
            topology_code=0,
        )

        self.assertEqual(_native_strip_segments(vertices, block, "XB_ALBERNISKY_77"), ((0, 12),))
        self.assertEqual(_native_strip_segments(vertices, block, "TRN_SECTION60_UNDERROAD"), ((0, 12),))

    def test_topology_05_half_face_blocks_split_every_four_vertices(self):
        vertices = tuple(Vec3(float(index), float(index & 1), 0.0) for index in range(20))
        block = DecodedBlock(
            run=VifVertexRun(vertices, (), (), (20, 4, 60, 252), (0x00286666, 0, 0, 0x00433330)),
            primitive_mode="strip",
            expected_face_count=10,
            topology_code=0x05,
        )

        self.assertEqual(_native_strip_segments(vertices, block, "XS_LIGHTPOSTA_1_00"), ((0, 4), (4, 8), (8, 12), (12, 16), (16, 20)))
        self.assertEqual(
            _indices_for_block(vertices, "XS_LIGHTPOSTA_1_00", block),
            [0, 1, 2, 3, 2, 1, 4, 5, 6, 7, 6, 5, 8, 9, 10, 11, 10, 9, 12, 13, 14, 15, 14, 13, 16, 17, 18, 19, 18, 17],
        )

    def test_native_segment_triangle_indices_dedupe_internal_duplicate_faces(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(0.0, 0.0, 0.0),
        )

        self.assertEqual(_native_segment_triangle_indices_if_needed(vertices, set()), [0, 1, 2])

    def test_write_glb_native_strip_omits_reconstructed_indices(self):
        scene = Scene(
            objects=[
                MeshObject(
                    name="TEST_STRIP",
                    chunk_offset=0,
                    transform=IDENTITY4,
                    blocks=(
                        DecodedBlock(
                            run=VifVertexRun(
                                (
                                    Vec3(0.0, 0.0, 0.0),
                                    Vec3(1.0, 0.0, 0.0),
                                    Vec3(0.0, 1.0, 0.0),
                                    Vec3(1.0, 1.0, 0.0),
                                ),
                                (),
                                (),
                                (4, 0, 0, 0),
                            ),
                            primitive_mode="strip",
                        ),
                    ),
                )
            ]
        )
        with TemporaryDirectory() as tmp_dir:
            out_path = Path(tmp_dir) / "native.glb"
            write_glb(scene, out_path, primitive_assembly="native")
            data = out_path.read_bytes()
        json_length = struct.unpack_from("<I", data, 12)[0]
        gltf = __import__("json").loads(data[20 : 20 + json_length])
        primitive = gltf["meshes"][0]["primitives"][0]
        self.assertEqual(primitive["mode"], 5)
        self.assertNotIn("indices", primitive)
        self.assertEqual(primitive["extras"]["block_index"], 0)

    def test_write_glb_native_strip_splits_large_bridge_without_indices(self):
        scene = Scene(
            objects=[
                MeshObject(
                    name="TEST_STRIP_SPLIT",
                    chunk_offset=0,
                    transform=IDENTITY4,
                    blocks=(
                        DecodedBlock(
                            run=VifVertexRun(
                                (
                                    Vec3(0.0, 0.0, 0.0),
                                    Vec3(0.0, 1.0, 0.0),
                                    Vec3(1.0, 0.0, 0.0),
                                    Vec3(1.0, 1.0, 0.0),
                                    Vec3(2.0, 0.0, 0.0),
                                    Vec3(2.0, 1.0, 0.0),
                                    Vec3(100.0, 0.0, 0.0),
                                    Vec3(100.0, 1.0, 0.0),
                                    Vec3(101.0, 0.0, 0.0),
                                    Vec3(101.0, 1.0, 0.0),
                                ),
                                (),
                                (),
                                (10, 0, 0, 0),
                            ),
                            primitive_mode="strip",
                        ),
                    ),
                )
            ]
        )
        with TemporaryDirectory() as tmp_dir:
            out_path = Path(tmp_dir) / "native_split.glb"
            write_glb(scene, out_path, primitive_assembly="native")
            data = out_path.read_bytes()
        json_length = struct.unpack_from("<I", data, 12)[0]
        gltf = __import__("json").loads(data[20 : 20 + json_length])
        primitives = gltf["meshes"][0]["primitives"]
        self.assertEqual([primitive["mode"] for primitive in primitives], [5])
        self.assertTrue(all("indices" not in primitive for primitive in primitives))
        self.assertEqual([(primitive["extras"]["segment_start"], primitive["extras"]["segment_end"]) for primitive in primitives], [(0, 10)])

    def test_write_glb_native_skips_fully_duplicate_strip_segment(self):
        run = VifVertexRun(
            (
                Vec3(0.0, 0.0, 0.0),
                Vec3(1.0, 0.0, 0.0),
                Vec3(0.0, 1.0, 0.0),
                Vec3(1.0, 1.0, 0.0),
            ),
            (),
            (),
            (4, 0, 0, 0),
        )
        scene = Scene(
            objects=[
                MeshObject(
                    name="TEST_DUP_NATIVE",
                    chunk_offset=0,
                    transform=IDENTITY4,
                    blocks=(
                        DecodedBlock(run=run, primitive_mode="strip"),
                        DecodedBlock(run=run, primitive_mode="strip"),
                    ),
                )
            ]
        )
        with TemporaryDirectory() as tmp_dir:
            out_path = Path(tmp_dir) / "native_dedupe.glb"
            write_glb(scene, out_path, primitive_assembly="native")
            data = out_path.read_bytes()
        json_length = struct.unpack_from("<I", data, 12)[0]
        gltf = __import__("json").loads(data[20 : 20 + json_length])
        self.assertEqual(len(gltf["meshes"][0]["primitives"]), 1)

    def test_write_glb_native_converts_duplicate_faces_to_deduped_triangles(self):
        scene = Scene(
            objects=[
                MeshObject(
                    name="TEST_NATIVE_DUP_TRIANGLES",
                    chunk_offset=0,
                    transform=IDENTITY4,
                    blocks=(
                        DecodedBlock(
                            run=VifVertexRun(
                                (
                                    Vec3(0.0, 0.0, 0.0),
                                    Vec3(1.0, 0.0, 0.0),
                                    Vec3(0.0, 1.0, 0.0),
                                    Vec3(1.0, 0.0, 0.0),
                                    Vec3(0.0, 0.0, 0.0),
                                ),
                                (),
                                (),
                                (5, 0, 0, 0),
                            ),
                            primitive_mode="strip",
                        ),
                    ),
                )
            ]
        )
        with TemporaryDirectory() as tmp_dir:
            out_path = Path(tmp_dir) / "native_deduped_triangles.glb"
            write_glb(scene, out_path, primitive_assembly="native")
            data = out_path.read_bytes()
        json_length = struct.unpack_from("<I", data, 12)[0]
        gltf = __import__("json").loads(data[20 : 20 + json_length])
        primitive = gltf["meshes"][0]["primitives"][0]
        self.assertEqual(primitive["mode"], 4)
        self.assertIn("indices", primitive)

    def test_write_ps2mesh_debug_emits_json_and_bin(self):
        scene = Scene(
            objects=[
                MeshObject(
                    name="TEST_DEBUG",
                    chunk_offset=0x1234,
                    transform=IDENTITY4,
                    blocks=(
                        DecodedBlock(
                            run=VifVertexRun((Vec3(1.0, 2.0, 3.0),), ((0.25, 0.5),), (0x11223344,), (1, 1, 1, 1)),
                            primitive_mode="strip",
                            source_offset=16,
                            source_qword_size=32,
                        ),
                    ),
                )
            ]
        )
        with TemporaryDirectory() as tmp_dir:
            json_path = Path(tmp_dir) / "sample.ps2mesh.json"
            bin_path = write_ps2mesh_debug(scene, json_path)
            document = __import__("json").loads(json_path.read_text(encoding="utf-8"))
            self.assertTrue(bin_path.exists())
        block = document["scene"]["objects"][0]["blocks"][0]
        self.assertEqual(block["primitive_mode"], "strip")
        self.assertEqual(block["source_offset"], 16)
        self.assertEqual(block["vertices"]["count"], 1)

    def test_strip_indices_drop_zero_area_restart_triangles(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 2.0, 0.0),
        )
        self.assertEqual(
            _strip_indices_for_vertices(vertices),
            [0, 1, 2, 3, 5, 4],
        )

    def test_strip_indices_keep_regular_ladder_strip(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(3.0, 0.0, 0.0),
            Vec3(3.0, 1.0, 0.0),
        )
        self.assertEqual(
            _strip_indices_for_vertices(vertices),
            [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4, 4, 5, 6, 5, 7, 6],
        )

    def test_topology_score_does_not_flag_regular_ladder_strip_as_corrupt(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(3.0, 0.0, 0.0),
            Vec3(3.0, 1.0, 0.0),
        )
        self.assertEqual(
            _topology_score(vertices, _strip_indices_for_vertices(vertices)),
            (0, 1.0, 6),
        )

    def test_track_sections_drop_far_two_vertex_tail_when_strip_restart_is_cleaner(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(10.0, 0.0, 0.0),
            Vec3(10.0, 1.0, 0.0),
        )
        self.assertEqual(_strip_indices_for_vertices(vertices, "RD_SECTION80_CHOP5"), [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4])

    def test_prop_tail_restart_split_keeps_short_tail_props_separate(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(10.0, 0.0, 0.0),
            Vec3(10.0, 1.0, 0.0),
        )
        self.assertEqual(_strip_indices_for_vertices(vertices, "XB_WELLL_A1_00"), [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4])

    def test_strip_indices_split_repeated_anchor_pairs_when_segmented_strip_is_cleaner(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(100.0, 0.0, 0.0),
            Vec3(100.0, 1.0, 0.0),
            Vec3(101.0, 0.0, 0.0),
            Vec3(101.0, 1.0, 0.0),
        )
        self.assertEqual(
            _strip_indices_for_vertices(vertices, "TRN_SECTION80_CHOP2"),
            [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4, 8, 9, 10, 9, 11, 10],
        )

    def test_indices_for_run_keeps_segmented_strip_when_metadata_matches_triangle_count(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(10.0, 0.0, 0.0),
            Vec3(11.0, 0.0, 0.0),
            Vec3(10.0, 1.0, 0.0),
        )
        self.assertEqual(_indices_for_run(vertices, "TEST_OBJECT", 2), [0, 1, 2, 3, 4, 5])

    def test_indices_for_run_does_not_infer_triangle_list_from_metadata_count(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
        )
        self.assertEqual(
            _indices_for_run(vertices, "XB_SAMPLE", 2),
            [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4],
        )

    def test_indices_for_run_keeps_segmented_strip_when_metadata_matches_quad_count(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(10.0, 0.0, 0.0),
            Vec3(11.0, 0.0, 0.0),
            Vec3(10.0, 1.0, 0.0),
            Vec3(11.0, 1.0, 0.0),
        )
        self.assertEqual(_indices_for_run(vertices, "TEST_OBJECT", 4), [0, 1, 2, 1, 3, 2, 4, 5, 6, 5, 7, 6])

    def test_indices_for_run_does_not_infer_quad_batches_from_metadata_count(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(3.0, 0.0, 0.0),
            Vec3(3.0, 1.0, 0.0),
        )
        self.assertEqual(
            _indices_for_run(vertices, "XB_SAMPLE", 4),
            [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4, 4, 5, 6, 5, 7, 6],
        )

    def test_indices_for_run_keeps_regular_strip_when_alternate_layout_is_not_better(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(3.0, 0.0, 0.0),
            Vec3(3.0, 1.0, 0.0),
        )
        self.assertEqual(
            _indices_for_run(vertices, "TEST_OBJECT", 4),
            [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4, 4, 5, 6, 5, 7, 6],
        )

    def test_indices_for_run_ignores_count_only_segmentation_for_track_sections(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(2.0, 0.0, 0.0),
            Vec3(2.0, 1.0, 0.0),
            Vec3(3.0, 0.0, 0.0),
            Vec3(3.0, 1.0, 0.0),
        )
        self.assertEqual(
            _indices_for_run(vertices, "RD_SECTION80_CHOP5", 4),
            _strip_indices_for_vertices(vertices, "RD_SECTION80_CHOP5"),
        )

    def test_indices_for_run_uses_geometry_restart_boundaries_for_track_sections(self):
        vertices = (
            Vec3(921.3474731445312, 1755.8338623046875, 320.3931579589844),
            Vec3(922.7384033203125, 1754.625732421875, 318.7872619628906),
            Vec3(920.2958374023438, 1751.8114013671875, 318.7872314453125),
            Vec3(920.2958374023438, 1751.8114013671875, 318.7872314453125),
            Vec3(918.9049682617188, 1753.0191650390625, 320.3931579589844),
            Vec3(921.3474731445312, 1755.8338623046875, 320.3931579589844),
            Vec3(918.1378784179688, 1760.0091552734375, 321.600341796875),
            Vec3(918.16796875, 1759.9832763671875, 328.3869934082031),
            Vec3(919.951416015625, 1758.434326171875, 322.1894836425781),
            Vec3(919.9813842773438, 1758.4080810546875, 328.97613525390625),
            Vec3(921.764892578125, 1756.859375, 321.5624084472656),
            Vec3(921.7950439453125, 1756.8331298828125, 328.34906005859375),
            Vec3(910.7485961914062, 1756.277587890625, 291.2479553222656),
            Vec3(915.084228515625, 1761.2735595703125, 291.2479553222656),
            Vec3(912.6417236328125, 1758.458984375, 313.944091796875),
            Vec3(915.084228515625, 1761.2735595703125, 313.944091796875),
            Vec3(912.9859008789062, 1758.1597900390625, 316.5558776855469),
            Vec3(915.4284057617188, 1760.9744873046875, 316.5558776855469),
            Vec3(913.8870849609375, 1757.3773193359375, 318.83062744140625),
            Vec3(916.3296508789062, 1760.19189453125, 318.83062744140625),
            Vec3(915.2780151367188, 1756.1693115234375, 320.43109130859375),
            Vec3(917.7205200195312, 1758.9840087890625, 320.43109130859375),
            Vec3(908.3317260742188, 1744.2841796875, 293.76885986328125),
            Vec3(909.9971923828125, 1746.396240234375, 293.76885986328125),
            Vec3(908.3317260742188, 1744.2841796875, 321.5653076171875),
            Vec3(909.9971923828125, 1746.396240234375, 321.5653076171875),
            Vec3(908.3317260742188, 1744.2841796875, 293.76885986328125),
            Vec3(908.3317260742188, 1744.2841796875, 321.5653076171875),
            Vec3(905.1217651367188, 1746.685302734375, 326.34820556640625),
        )
        self.assertEqual(
            _indices_for_run(vertices, "TRN_SECTION40_WALLS_PRO", 17),
            _strip_indices_for_vertices(vertices, "TRN_SECTION40_WALLS_PRO"),
        )

    def test_ps2_to_gltf_vec3_rotates_z_up_world_to_y_up(self):
        self.assertEqual(_ps2_to_gltf_vec3(Vec3(1.0, 2.0, 3.0)), Vec3(1.0, 3.0, -2.0))

    def test_vu1_position_transform_preserves_homogeneous_w(self):
        matrix = (
            (1.0, 0.0, 0.0, 0.25),
            (0.0, 2.0, 0.0, 0.5),
            (0.0, 0.0, 3.0, 0.75),
            (10.0, 20.0, 30.0, 1.0),
        )

        transformed = transform_vu1_position(Vec3(2.0, 3.0, 4.0), matrix)

        self.assertEqual(VU1_TRANSFORM_MATRIX_ADDR, 0x348)
        self.assertEqual(transformed, Vec4(12.0, 26.0, 42.0, 6.0))
        self.assertEqual(transform_point(Vec3(2.0, 3.0, 4.0), matrix), Vec3(12.0, 26.0, 42.0))

    def test_compose_matrix4_matches_sequential_row_vector_transform(self):
        left = (
            (1.0, 0.0, 0.0, 0.0),
            (0.0, 1.0, 0.0, 0.0),
            (0.0, 0.0, 1.0, 0.0),
            (2.0, 3.0, 4.0, 1.0),
        )
        right = (
            (0.0, 1.0, 0.0, 0.0),
            (-1.0, 0.0, 0.0, 0.0),
            (0.0, 0.0, 1.0, 0.0),
            (10.0, 20.0, 30.0, 1.0),
        )

        point = Vec3(5.0, 7.0, 11.0)
        sequential = transform_point(transform_point(point, left), right)
        composed = transform_point(point, compose_matrix4(left, right))

        self.assertEqual(composed, sequential)

    def test_indices_for_block_ignores_metadata_subtype_hybrid_pass_for_track_sections(self):
        vertices = (
            Vec3(-41.856, 1859.195, 277.876),
            Vec3(-43.198, 1860.374, 279.533),
            Vec3(-44.315, 1858.974, 277.876),
            Vec3(-44.020, 1861.310, 279.533),
            Vec3(-45.475, 1860.247, 277.876),
            Vec3(-44.058, 1862.728, 279.533),
            Vec3(-45.285, 1862.879, 277.876),
            Vec3(-43.472, 1864.008, 279.533),
            Vec3(-44.434, 1864.903, 277.876),
            Vec3(-42.334, 1864.723, 279.533),
            Vec3(-42.654, 1866.011, 277.876),
            Vec3(-40.909, 1864.670, 279.533),
            Vec3(-40.318, 1865.910, 277.876),
            Vec3(-39.844, 1863.825, 279.533),
            Vec3(-38.560, 1864.565, 277.876),
            Vec3(-39.660, 1862.463, 279.533),
            Vec3(-38.297, 1862.337, 277.876),
            Vec3(-40.397, 1861.125, 279.533),
            Vec3(-39.410, 1860.227, 277.876),
            Vec3(-41.903, 1860.573, 279.533),
            Vec3(-41.856, 1859.195, 277.876),
            Vec3(-43.198, 1860.374, 279.533),
            Vec3(-0.258, 1838.290, 285.113),
            Vec3(-8.055, 1827.850, 284.700),
            Vec3(-1.128, 1819.325, 287.802),
            Vec3(-15.853, 1817.410, 284.287),
            Vec3(-28.698, 1806.706, 283.754),
            Vec3(-19.559, 1802.941, 286.954),
        )
        block = DecodedBlock(
            run=VifVertexRun(vertices, (), (), (28, 6, 84, 252)),
            primitive_mode="strip",
            expected_face_count=22,
            topology_code=0x05,
        )
        indices = _indices_for_block(vertices, "TRN_SECTION80_CHOP2", block)
        self.assertEqual(len(indices) // 3, len(vertices) - 2)
        self.assertNotEqual(len(indices) // 3, block.expected_face_count)

    def test_target_count_priority_is_reserved_for_props(self):
        self.assertFalse(_should_prioritize_target_count("XB_WELLL_A1_00"))
        self.assertFalse(_should_prioritize_target_count("TRACK_HELICOPTER"))
        self.assertFalse(_should_prioritize_target_count("TRN_SECTION40_WALLS_PRO"))
        self.assertFalse(_should_prioritize_target_count("RD_SECTION70_CHOP4"))
        self.assertFalse(_should_prioritize_target_count("TEST_OBJECT"))

    def test_trackb24_container_truck_uses_vif_control_mask(self):
        bundle_path = TRACKS_ROOT / "TRACKB24.BUN"
        if not bundle_path.exists():
            self.skipTest("TRACKB24 fixture is not available")

        bundle = load_bundle_bytes(bundle_path)
        scene = parse_scene(parse_chunks(bundle), bundle)
        target = next((obj for obj in scene.objects if obj.name == "XB_CONTAINERTRKCABA_L1A"), None)
        if target is None:
            self.fail("XB_CONTAINERTRKCABA_L1A fixture is missing from TRACKB24.BUN")

        block = target.blocks[31]
        vertices = transformed_block_vertices(target, block)
        self.assertEqual(block.expected_face_count, 22)
        self.assertEqual(primitive_stream_for_block(vertices, block).source_proof, "vif_control")
        self.assertEqual(len(_indices_for_block(vertices, target.name, block)) // 3, 22)

    def test_trackb24_container_truck_more_blocks_use_vif_control_mask(self):
        bundle_path = TRACKS_ROOT / "TRACKB24.BUN"
        if not bundle_path.exists():
            self.skipTest("TRACKB24 fixture is not available")

        bundle = load_bundle_bytes(bundle_path)
        scene = parse_scene(parse_chunks(bundle), bundle)
        target = next((obj for obj in scene.objects if obj.name == "XB_CONTAINERTRKCABA_L1A"), None)
        if target is None:
            self.fail("XB_CONTAINERTRKCABA_L1A fixture is missing from TRACKB24.BUN")

        for block_index, expected_faces in ((2, 14), (42, 4), (85, 5)):
            with self.subTest(block_index=block_index):
                block = target.blocks[block_index]
                vertices = transformed_block_vertices(target, block)
                self.assertEqual(block.primitive_mode, "strip")
                self.assertEqual(primitive_stream_for_block(vertices, block).source_proof, "vif_control")
                self.assertEqual(len(_indices_for_block(vertices, target.name, block)) // 3, expected_faces)

    def test_trackb24_container_truck_positions_match_runtime_accessor(self):
        bundle_path = TRACKS_ROOT / "TRACKB24.BUN"
        if not bundle_path.exists():
            self.skipTest("TRACKB24 fixture is not available")

        bundle = load_bundle_bytes(bundle_path)
        chunks = parse_chunks(bundle)
        scene = parse_scene(chunks, bundle)
        target = next((obj for obj in scene.objects if obj.name == "XB_CONTAINERTRKCABA_L1A"), None)
        if target is None:
            self.fail("XB_CONTAINERTRKCABA_L1A fixture is missing from TRACKB24.BUN")

        def walk(items):
            for item in items:
                yield item
                yield from walk(item.children)

        object_chunk = None
        for chunk in walk(chunks):
            if chunk.chunk_id != 0x80034002:
                continue
            header = next((child for child in chunk.children if child.chunk_id == 0x00034003), None)
            if header is None:
                continue
            name_info = _find_ascii_name(header.payload(bundle))
            if name_info is not None and name_info[0] == target.name:
                object_chunk = chunk
                break
        if object_chunk is None:
            self.fail("XB_CONTAINERTRKCABA_L1A object chunk is missing")

        vif_payload = _strip_vif_prefix(
            next(child for child in object_chunk.children if child.chunk_id == 0x00034005).payload(bundle)
        )
        metadata_payload = _strip_vif_prefix(
            next(child for child in object_chunk.children if child.chunk_id == 0x00034004).payload(bundle)
        )

        def runtime_position(packet: bytes, vertex_index: int) -> Vec3:
            vertex_count = packet[4]
            full_groups = vertex_count >> 2
            remainder = vertex_count - full_groups * 4
            lane = vertex_index & 3
            base = 0x1C
            if vertex_index < full_groups * 4:
                row_base = base + (vertex_index >> 2) * 0x30 + 4
                return Vec3(
                    struct.unpack_from("<f", packet, row_base + lane * 4)[0],
                    struct.unpack_from("<f", packet, row_base + lane * 4 + 0x10)[0],
                    struct.unpack_from("<f", packet, row_base + lane * 4 + 0x20)[0],
                )

            row_base = base
            if full_groups:
                row_base += (vertex_index >> 2) * 0x30 + 4
            row_base += 4
            return Vec3(
                struct.unpack_from("<f", packet, row_base + lane * 4)[0],
                struct.unpack_from("<f", packet, row_base + (remainder + lane) * 4)[0],
                struct.unpack_from("<f", packet, row_base + (remainder * 2 + lane) * 4)[0],
            )

        for block_index, block in enumerate(target.blocks):
            record = metadata_payload[block_index * 0x40 : (block_index + 1) * 0x40]
            offset = struct.unpack_from("<I", record, 0x08)[0]
            size = (struct.unpack_from("<I", record, 0x0C)[0] & 0xFFFF) * 16
            packet = vif_payload[offset : offset + size]
            for vertex_index, vertex in enumerate(block.run.vertices):
                with self.subTest(block_index=block_index, vertex_index=vertex_index):
                    self.assertEqual(vertex, runtime_position(packet, vertex_index))

    def test_trackb24_container_truck_scenery_instance_matches_runtime_matrix_record(self):
        bundle_path = TRACKS_ROOT / "TRACKB24.BUN"
        if not bundle_path.exists():
            self.skipTest("TRACKB24 fixture is not available")

        bundle = load_bundle_bytes(bundle_path)
        scene = parse_scene(parse_chunks(bundle), bundle)
        target = next((obj for obj in scene.objects if obj.name == "XB_CONTAINERTRKCABA_L1A"), None)
        if target is None:
            self.fail("XB_CONTAINERTRKCABA_L1A fixture is missing from TRACKB24.BUN")

        instance = next(
            (
                item
                for item in scene.scenery_instances
                if item.object_name == target.name and item.source_chunk_offset == 0x70CFC8 and item.record_index == 4
            ),
            None,
        )
        if instance is None:
            self.fail("XB_CONTAINERTRKCABA_L1A scenery instance fixture is missing")

        self.assertEqual(instance.object_index, 4)
        self.assertEqual(
            instance.transform,
            (
                (1.0, 0.0, 0.0, 0.0),
                (0.0, 1.0, 0.0, 0.0),
                (0.0, 0.0, 1.0, 0.0),
                (1351.68212890625, 786.0047607421875, 7.418026447296143, 1.0),
            ),
        )

        instantiated = instantiated_mesh_object(target, instance)
        for actual, expected in zip(
            instantiated.transform[3],
            (1351.5061914166436, 780.2207765579224, 7.418026447296143, 1.0),
        ):
            self.assertAlmostEqual(actual, expected, places=6)

    def test_glb_export_defaults_to_direct_bun_objects(self):
        bundle_path = TRACKS_ROOT / "TRACKB24.BUN"
        if not bundle_path.exists():
            self.skipTest("TRACKB24 fixture is not available")

        bundle = load_bundle_bytes(bundle_path)
        scene = parse_scene(parse_chunks(bundle), bundle)
        export_objects = _objects_for_glb_export(scene)

        self.assertIn("XB_CONTAINERTRKCABA_L1A", {obj.name for obj in export_objects})
        self.assertFalse(any("_inst_" in obj.name for obj in export_objects))

    def test_glb_export_can_expand_scenery_instances_without_base_definition_duplicate(self):
        bundle_path = TRACKS_ROOT / "TRACKB24.BUN"
        if not bundle_path.exists():
            self.skipTest("TRACKB24 fixture is not available")

        bundle = load_bundle_bytes(bundle_path)
        scene = parse_scene(parse_chunks(bundle), bundle)
        export_objects = _objects_for_glb_export(scene, expand_instances=True)

        self.assertFalse(any(obj.name == "XB_CONTAINERTRKCABA_L1A" for obj in export_objects))
        target = next(
            (
                obj
                for obj in export_objects
                if obj.name.startswith("XB_CONTAINERTRKCABA_L1A_inst_0070cfc8_004")
            ),
            None,
        )
        if target is None:
            self.fail("instanced container truck was not selected for GLB export")

        for actual, expected in zip(
            target.transform[3],
            (1351.5061914166436, 780.2207765579224, 7.418026447296143, 1.0),
        ):
            self.assertAlmostEqual(actual, expected, places=6)

    def test_trackb44_trn_section80_chop3_uses_vif_control_mask(self):
        bundle_path = TRACKS_ROOT / "TRACKB44.BUN"
        if not bundle_path.exists():
            self.skipTest("TRACKB44 fixture is not available")

        bundle = load_bundle_bytes(bundle_path)
        scene = parse_scene(parse_chunks(bundle), bundle)
        target = next((obj for obj in scene.objects if obj.name == "TRN_SECTION80_CHOP3"), None)
        if target is None:
            self.fail("TRN_SECTION80_CHOP3 fixture is missing from TRACKB44.BUN")

        chosen_faces = 0
        metadata_faces = 0
        for block in target.blocks:
            vertices = transformed_block_vertices(target, block)
            stream = primitive_stream_for_block(vertices, block)
            self.assertEqual(stream.source_proof, "vif_control")
            chosen_faces += len(_indices_for_block(vertices, target.name, block)) // 3
            metadata_faces += block.expected_face_count or 0

        self.assertEqual(chosen_faces, 704)
        self.assertEqual(chosen_faces, metadata_faces)

    def test_trackb44_rd_section50_chop4_uses_vif_control_mask(self):
        bundle_path = TRACKS_ROOT / "TRACKB44.BUN"
        if not bundle_path.exists():
            self.skipTest("TRACKB44 fixture is not available")

        bundle = load_bundle_bytes(bundle_path)
        scene = parse_scene(parse_chunks(bundle), bundle)
        target = next((obj for obj in scene.objects if obj.name == "RD_SECTION50_CHOP4"), None)
        if target is None:
            self.fail("RD_SECTION50_CHOP4 fixture is missing from TRACKB44.BUN")

        block = target.blocks[0]
        vertices = transformed_block_vertices(target, block)
        self.assertEqual(block.expected_face_count, 14)
        self.assertEqual(len(vertices), 28)
        self.assertEqual(primitive_stream_for_block(vertices, block).source_proof, "vif_control")
        self.assertEqual(len(_indices_for_block(vertices, target.name, block)) // 3, 14)

    def test_trackb44_section50_uses_vif_control_mask(self):
        bundle_path = TRACKS_ROOT / "TRACKB44.BUN"
        if not bundle_path.exists():
            self.skipTest("TRACKB44 fixture is not available")

        bundle = load_bundle_bytes(bundle_path)
        scene = parse_scene(parse_chunks(bundle), bundle)

        cases = (
            ("RDDRT_SECTION50_CHOP4", 18, 14),
            ("RDDRT_SECTION50_CHOP4", 20, 14),
            ("RD_SECTION50_CHOP4", 27, 14),
            ("TRN_SECTION50_CHOP4", 67, 14),
            ("TRN_SECTION50_CHOP4", 85, 10),
        )
        for object_name, block_index, expected_faces in cases:
            with self.subTest(object_name=object_name, block_index=block_index):
                target = next((obj for obj in scene.objects if obj.name == object_name), None)
                if target is None:
                    self.fail(f"{object_name} fixture is missing from TRACKB44.BUN")
                block = target.blocks[block_index]
                vertices = transformed_block_vertices(target, block)
                self.assertEqual(primitive_stream_for_block(vertices, block).source_proof, "vif_control")
                self.assertEqual(len(_indices_for_block(vertices, target.name, block)) // 3, expected_faces)

    def test_trackb61_section30_blocks_use_vif_control_mask(self):
        bundle_path = TRACKS_ROOT / "TRACKB61.LZC"
        if not bundle_path.exists():
            self.skipTest("TRACKB61 fixture is not available")

        bundle = load_bundle_bytes(bundle_path)
        scene = parse_scene(parse_chunks(bundle), bundle)
        target = next((obj for obj in scene.objects if obj.name == "TRN_SECTION30_CHOP3"), None)
        if target is None:
            self.fail("TRN_SECTION30_CHOP3 fixture is missing from TRACKB61.LZC")

        for block_index in range(50, 59):
            with self.subTest(block_index=block_index):
                block = target.blocks[block_index]
                vertices = transformed_block_vertices(target, block)
                self.assertEqual(len(vertices) % 4, 0)
                self.assertEqual(block.expected_face_count, len(vertices) // 2)
                self.assertEqual(primitive_stream_for_block(vertices, block).source_proof, "vif_control")
                self.assertEqual(
                    len(_indices_for_block(vertices, target.name, block)) // 3,
                    block.expected_face_count,
                )

    def test_should_export_vif_colors_honors_mode_override(self):
        self.assertTrue(_should_export_vif_colors("TEST_OBJECT", None, "always"))
        self.assertFalse(_should_export_vif_colors("RD_SECTION70_CHOP4", 0x4041, "off"))

    def test_should_replace_topology_prefers_exact_prop_count_when_candidate_has_no_bad_faces(self):
        self.assertTrue(
            _should_replace_topology(
                (0, 3.0, 20),
                (0, 1.2, 15),
                20,
                prefer_target_count=True,
            )
        )

    def test_should_replace_topology_rejects_exact_prop_count_when_distortion_is_too_high(self):
        self.assertFalse(
            _should_replace_topology(
                (0, 3.7, 20),
                (0, 1.2, 15),
                20,
                prefer_target_count=True,
            )
        )

    def test_should_replace_topology_allows_exact_prop_count_when_metadata_gap_is_large(self):
        self.assertTrue(
            _should_replace_topology(
                (4, 13.1, 22),
                (0, 1.0, 16),
                22,
                prefer_target_count=True,
            )
        )

    def test_should_replace_topology_prefers_lower_distortion_when_face_counts_tie(self):
        self.assertTrue(
            _should_replace_topology(
                (0, 1.2, 14),
                (0, 1.8, 14),
                14,
                prefer_target_count=True,
            )
        )

    def test_skip_object_filters_background_meshes(self):
        self.assertTrue(_should_skip_object("SKYDOME"))
        self.assertTrue(_should_skip_object("SKYDOME_ENVMAP"))
        self.assertTrue(_should_skip_object("BACKGROUND"))
        self.assertFalse(_should_skip_object("RD_SECTION80_CHOP5"))


class ObjWriterTests(unittest.TestCase):
    def test_obj_writer_uses_block_primitive_assembly(self):
        vertices = (
            Vec3(0.0, 0.0, 0.0),
            Vec3(1.0, 0.0, 0.0),
            Vec3(0.0, 1.0, 0.0),
            Vec3(1.0, 1.0, 0.0),
            Vec3(10.0, 0.0, 0.0),
            Vec3(11.0, 0.0, 0.0),
            Vec3(10.0, 1.0, 0.0),
            Vec3(11.0, 1.0, 0.0),
        )
        texcoords = (
            (0.0, 0.0),
            (1.0, 0.0),
            (0.0, 1.0),
            (1.0, 1.0),
            (0.0, 0.0),
            (1.0, 0.0),
            (0.0, 1.0),
            (1.0, 1.0),
        )
        block = DecodedBlock(
            run=VifVertexRun(vertices, texcoords, (), (8, 4, 60, 252), (0x00286666, 0, 0, 0x00433330)),
            primitive_mode="strip",
            expected_face_count=4,
        )
        scene = Scene(
            objects=[
                MeshObject(
                    name="RD_TEST",
                    chunk_offset=0,
                    transform=IDENTITY4,
                    blocks=(block,),
                )
            ]
        )

        with TemporaryDirectory() as tmp_dir:
            out_path = Path(tmp_dir) / "test.obj"
            write_obj(scene, out_path)
            face_lines = [line for line in out_path.read_text(encoding="utf-8").splitlines() if line.startswith("f ")]

        self.assertEqual(
            face_lines,
            ["f 1 2 3", "f 4 3 2", "f 5 6 7", "f 8 7 6"],
        )


class ModelRunMetadataTests(unittest.TestCase):
    def test_run_texture_indices_accept_no_prefix_table(self):
        payload = (0).to_bytes(4, "little") + bytes(60) + (2).to_bytes(4, "little") + bytes(60)
        self.assertEqual(_read_run_texture_indices(payload, 2), (0, 2))

    def test_run_texture_indices_accept_prefixed_table(self):
        payload = b"\x11" * 8 + (1).to_bytes(4, "little") + bytes(60)
        self.assertEqual(_read_run_texture_indices(payload, 1), (1,))

    def test_run_unknown_counts_read_packed_count_like_byte(self):
        record = bytearray(64)
        record[0x1C:0x20] = (0xFF121E03).to_bytes(4, "little")
        self.assertEqual(_read_run_unknown_counts(bytes(record), 1), (0x12,))

    def test_strip_entry_records_can_segment_vif_payload_into_runs(self):
        def build_run(base: float) -> bytes:
            payload = bytearray()
            payload.extend(struct.pack("<HBB", 0x8000, 1, 0x6E))
            payload.extend(bytes((4, 0, 0, 0)))
            payload.extend(struct.pack("<HBB", 0xC002, 3, 0x6C))
            payload.extend(
                struct.pack(
                    "<12f",
                    base + 0.0,
                    base + 1.0,
                    base + 2.0,
                    base + 3.0,
                    base + 10.0,
                    base + 11.0,
                    base + 12.0,
                    base + 13.0,
                    base + 20.0,
                    base + 21.0,
                    base + 22.0,
                    base + 23.0,
                )
            )
            payload.extend(struct.pack("<HBB", 0x0000, 0, 0x14))
            return bytes(payload)

        run0 = build_run(0.0)
        run1 = build_run(100.0)
        vif_payload = run0 + run1

        record0 = bytearray(64)
        record0[0x08:0x0C] = (0).to_bytes(4, "little")
        record0[0x0C:0x10] = (len(run0) // 16).to_bytes(4, "little")

        record1 = bytearray(64)
        record1[0x08:0x0C] = len(run0).to_bytes(4, "little")
        record1[0x0C:0x10] = (len(run1) // 16).to_bytes(4, "little")

        blocks = _extract_blocks_from_strip_entries(vif_payload, bytes(record0 + record1), "XB_SAMPLE")
        self.assertEqual(len(blocks), 2)
        self.assertEqual(blocks[0].run.vertices[0], Vec3(0.0, 10.0, 20.0))
        self.assertEqual(blocks[1].run.vertices[0], Vec3(100.0, 110.0, 120.0))
        self.assertEqual(blocks[0].primitive_mode, "strip")


class VifDecodeTests(unittest.TestCase):
    def test_v4_16_position_rows_decode_to_scaled_vertices(self):
        payload = bytearray()
        payload.extend(struct.pack("<HBB", 0x8000, 1, 0x6E))
        payload.extend(bytes((4, 0, 0, 0)))

        payload.extend(struct.pack("<HBB", 0xC002, 3, 0x6D))
        payload.extend(
            struct.pack(
                "<12h",
                4096,
                8192,
                12288,
                16384,
                2048,
                4096,
                6144,
                8192,
                -4096,
                -8192,
                -12288,
                -16384,
            )
        )
        payload.extend(struct.pack("<HBB", 0x0000, 0, 0x14))

        runs = extract_vif_vertex_runs(bytes(payload))
        self.assertEqual(len(runs), 1)
        self.assertEqual(
            runs[0].vertices,
            (
                Vec3(1.0, 0.5, -1.0),
                Vec3(2.0, 1.0, -2.0),
                Vec3(3.0, 1.5, -3.0),
                Vec3(4.0, 2.0, -4.0),
            ),
        )

    def test_v4_8_position_rows_decode_to_scaled_vertices(self):
        payload = bytearray()
        payload.extend(struct.pack("<HBB", 0x8000, 1, 0x6E))
        payload.extend(bytes((4, 0, 0, 0)))

        payload.extend(struct.pack("<HBB", 0xC002, 3, 0x6E))
        payload.extend(struct.pack("<12b", 64, 32, 0, -32, 0, 32, 64, 96, -64, -32, 0, 32))
        payload.extend(struct.pack("<HBB", 0x0000, 0, 0x14))

        runs = extract_vif_vertex_runs(bytes(payload))
        self.assertEqual(len(runs), 1)
        self.assertEqual(
            runs[0].vertices,
            (
                Vec3(0.5, 0.0, -0.5),
                Vec3(0.25, 0.25, -0.25),
                Vec3(0.0, 0.5, 0.0),
                Vec3(-0.25, 0.75, 0.25),
            ),
        )

    def test_v4_32_uv_rows_swap_the_second_pair(self):
        payload = bytearray()
        payload.extend(struct.pack("<HBB", 0x8000, 1, 0x6E))
        payload.extend(bytes((4, 0, 12, 252)))

        payload.extend(struct.pack("<HBB", 0xC002, 3, 0x6C))
        payload.extend(
            struct.pack(
                "<12f",
                0.0,
                1.0,
                2.0,
                3.0,
                10.0,
                11.0,
                12.0,
                13.0,
                20.0,
                21.0,
                22.0,
                23.0,
            )
        )

        payload.extend(struct.pack("<HBB", 0xC020, 2, 0x6C))
        payload.extend(struct.pack("<8f", 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0))
        payload.extend(struct.pack("<HBB", 0x0000, 0, 0x14))

        runs = extract_vif_vertex_runs(bytes(payload))
        self.assertEqual(len(runs), 1)
        self.assertEqual(
            runs[0].texcoords,
            ((0.0, 1.0), (0.0, 0.0), (1.0, 1.0), (1.0, 0.0)),
        )
